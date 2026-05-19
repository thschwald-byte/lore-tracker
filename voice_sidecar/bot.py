#!/usr/bin/env python3
"""
lore-voice — Discord voice-receive sidecar for LoreTracker.

Runs as a child process of the Elixir worker. Listens for JSON commands
on stdin, joins/leaves Discord voice channels accordingly, records
per-speaker audio with py-cord, transcribes with whisper-cli, and POSTs
UtteranceAppended events to the hub's /dev/event endpoint.

stdin protocol (one JSON object per line):
    {"op": "join",  "guild_id": "...", "channel_id": "...", "session_id": "..."}
    {"op": "leave", "guild_id": "..."}
    {"op": "shutdown"}

stdout protocol (one JSON object per line, status updates):
    {"event": "ready", "username": "...", "application_id": ...}
    {"event": "joined", "guild_id": "...", "channel_id": "...", "session_id": "..."}
    {"event": "left",   "guild_id": "...", "session_id": "..."}
    {"event": "transcription_started", "session_id": "...", "speakers": N}
    {"event": "transcription_done",    "session_id": "...", "utterance_count": N}
    {"event": "error", "op": "...", "reason": "..."}

Env vars:
    DISCORD_VOICE_BOT_TOKEN   — required, second bot's token
    HUB_BASE_URL              — default http://localhost:4000
    WHISPER_BIN               — default whisper-cli
    WHISPER_MODEL             — default ~/.cache/whisper/ggml-base.bin
    WHISPER_LANG              — default auto
"""

import asyncio
import datetime
import json
import os
import subprocess
import sys
import tempfile
import urllib.request
import uuid
from pathlib import Path

import discord


TOKEN = os.environ["DISCORD_VOICE_BOT_TOKEN"]
HUB_URL = os.environ.get("HUB_BASE_URL", "http://localhost:4000")
WHISPER_BIN = os.environ.get("WHISPER_BIN", "whisper-cli")
WHISPER_MODEL = os.environ.get(
    "WHISPER_MODEL", os.path.expanduser("~/.cache/whisper/ggml-base.bin")
)
WHISPER_LANG = os.environ.get("WHISPER_LANG", "auto")


def out(event, **kwargs):
    """Write a JSON status line to stdout for the Elixir worker."""
    print(json.dumps({"event": event, **kwargs}), flush=True)


# guild_id (str) -> {"session_id", "vc", "channel_id", "started_at"}
RECORDINGS = {}


# Bot is constructed lazily in main() so its internal loop binding matches
# asyncio.run()'s loop. Creating it at module load picked up a stale event
# loop reference, which py-cord later used in client.loop.create_task() for
# voice-connector tasks → "Future attached to a different loop" on connect.
bot: discord.Bot | None = None

_stdin_started = False


# ─── Voice ops ──────────────────────────────────────────────────────


async def join_voice(guild_id: str, channel_id: str, session_id: str):
    guild = bot.get_guild(int(guild_id))
    if guild is None:
        out("error", op="join", reason="guild_not_cached", guild_id=guild_id)
        return

    channel = guild.get_channel(int(channel_id))
    if channel is None or not isinstance(channel, discord.VoiceChannel):
        out("error", op="join", reason="channel_not_voice", channel_id=channel_id)
        return

    if guild_id in RECORDINGS:
        out("error", op="join", reason="already_recording", guild_id=guild_id)
        return

    try:
        vc = await channel.connect()
    except Exception as e:
        out("error", op="join", reason=f"connect_failed: {e!r}", guild_id=guild_id)
        return

    sink = discord.sinks.WaveSink()

    started_at = datetime.datetime.now(datetime.timezone.utc)
    RECORDINGS[guild_id] = {
        "session_id": session_id,
        "vc": vc,
        "channel_id": channel_id,
        "started_at": started_at,
    }

    def finished_callback(sink_, *args):
        # Scheduled on the event loop; can't await directly from this callback.
        asyncio.create_task(transcribe_and_post(sink_, session_id, started_at))

    vc.start_recording(sink, finished_callback)
    out("joined", guild_id=guild_id, channel_id=channel_id, session_id=session_id)


async def leave_voice(guild_id: str):
    rec = RECORDINGS.pop(guild_id, None)
    if not rec:
        out("error", op="leave", reason="not_recording", guild_id=guild_id)
        return

    vc = rec["vc"]
    try:
        if vc.is_recording():
            vc.stop_recording()  # triggers finished_callback synchronously
    except Exception as e:
        out("error", op="leave", reason=f"stop_recording_failed: {e!r}")

    try:
        await vc.disconnect()
    except Exception as e:
        out("error", op="leave", reason=f"disconnect_failed: {e!r}")

    out("left", guild_id=guild_id, session_id=rec["session_id"])


# ─── Transcription ──────────────────────────────────────────────────


async def transcribe_and_post(sink, session_id: str, started_at: datetime.datetime):
    audio_data = sink.audio_data or {}
    out("transcription_started", session_id=session_id, speakers=len(audio_data))

    utterance_count = 0

    with tempfile.TemporaryDirectory(prefix="lore_voice_") as tmp_dir:
        for user_id, audio in audio_data.items():
            wav_path = Path(tmp_dir) / f"user_{user_id}.wav"
            with open(wav_path, "wb") as f:
                f.write(audio.file.getvalue())

            json_path = await asyncio.to_thread(run_whisper, wav_path)
            if not json_path:
                continue

            with open(json_path) as f:
                whisper_data = json.load(f)

            for seg in whisper_data.get("transcription", []):
                text = seg.get("text", "").strip()
                if not text:
                    continue

                offset_ms = parse_ts_to_ms(seg.get("timestamps", {}).get("from", "00:00:00,000"))
                ts = started_at + datetime.timedelta(milliseconds=offset_ms)

                payload = {
                    "kind": "UtteranceAppended",
                    "id": str(uuid.uuid4()),
                    "session_id": session_id,
                    "discord_id": str(user_id),
                    "timestamp": ts.isoformat().replace("+00:00", "Z"),
                    "text": text,
                    "confidence": None,
                    "status": "confirmed",
                }

                if post_event(payload):
                    utterance_count += 1

    out("transcription_done", session_id=session_id, utterance_count=utterance_count)

    # Now that all utterances are in the event log, fire SessionEnded so
    # Worker.Recording.Pipeline can run stages 2/3/4 with a complete
    # transcript. The Elixir Recorder no longer emits SessionEnded itself —
    # the Python sidecar owns that ordering.
    post_event({"kind": "SessionEnded", "id": session_id})


def run_whisper(wav_path: Path):
    out_prefix = wav_path.with_suffix("")
    try:
        subprocess.run(
            [
                WHISPER_BIN,
                "-m", WHISPER_MODEL,
                "-l", WHISPER_LANG,
                "-oj",
                "-of", str(out_prefix),
                str(wav_path),
            ],
            check=True,
            capture_output=True,
        )
    except subprocess.CalledProcessError as e:
        out(
            "error",
            op="whisper",
            wav=wav_path.name,
            stderr=(e.stderr or b"").decode("utf-8", errors="replace")[-400:],
        )
        return None

    json_path = Path(str(out_prefix) + ".json")
    if json_path.exists():
        return json_path

    # whisper-cli sometimes uses ".wav.json"
    alt = wav_path.with_suffix(".wav.json")
    if alt.exists():
        return alt

    out("error", op="whisper_output", wav=wav_path.name, reason="no_json")
    return None


def parse_ts_to_ms(s: str) -> int:
    """Parse "HH:MM:SS,mmm" from whisper into total milliseconds."""
    try:
        time_part, ms_part = s.split(",")
        h, m, sec = map(int, time_part.split(":"))
        return ((h * 60 + m) * 60 + sec) * 1000 + int(ms_part)
    except Exception:
        return 0


def post_event(payload):
    body = json.dumps({"payload": payload}).encode("utf-8")
    req = urllib.request.Request(
        f"{HUB_URL}/dev/event",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            resp.read()
        return True
    except Exception as e:
        out("error", op="post_event", reason=str(e))
        return False


# ─── stdin command loop ─────────────────────────────────────────────


async def stdin_loop():
    loop = asyncio.get_event_loop()
    reader = asyncio.StreamReader()
    protocol = asyncio.StreamReaderProtocol(reader)
    await loop.connect_read_pipe(lambda: protocol, sys.stdin)

    while True:
        line = await reader.readline()
        if not line:
            break

        line = line.decode().strip()
        if not line:
            continue

        try:
            cmd = json.loads(line)
        except json.JSONDecodeError as e:
            out("error", op="parse", reason=str(e), line=line[:200])
            continue

        op = cmd.get("op")

        try:
            if op == "join":
                await join_voice(
                    str(cmd["guild_id"]),
                    str(cmd["channel_id"]),
                    str(cmd["session_id"]),
                )
            elif op == "leave":
                await leave_voice(str(cmd["guild_id"]))
            elif op == "shutdown":
                await bot.close()
                break
            else:
                out("error", op="unknown", value=op)
        except Exception as e:
            out("error", op=op or "?", reason=f"unhandled: {e!r}")


# ─── Entrypoint ─────────────────────────────────────────────────────


async def main():
    global bot

    intents = discord.Intents.default()
    intents.voice_states = True
    bot = discord.Bot(intents=intents)

    @bot.event
    async def on_ready():
        global _stdin_started
        out("ready", username=str(bot.user), application_id=str(bot.user.id))
        if not _stdin_started:
            _stdin_started = True
            asyncio.create_task(stdin_loop())

    await bot.start(TOKEN)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
