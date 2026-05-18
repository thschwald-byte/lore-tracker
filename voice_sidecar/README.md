# lore-voice (Python voice sidecar)

Second Discord bot for **voice receive**, because Nostrum (Elixir) doesn't
yet implement Discord's DAVE (E2EE) protocol that's now mandatory on the
voice gateway. This sidecar is spawned + supervised by the Elixir worker;
it logs into Discord as `lore-voice` (separate bot identity from
`lore-spy`), joins voice channels on command, records per-speaker audio
with `py-cord`, transcribes with `whisper-cli`, and POSTs
`UtteranceAppended` events back to the hub.

## Install

```
cd voice_sidecar
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Also needs `whisper-cli` (Arch: `whisper.cpp` or `whisper.cpp-hip`) and
a GGML model in `~/.cache/whisper/ggml-base.bin`:

```
mkdir -p ~/.cache/whisper
curl -L -o ~/.cache/whisper/ggml-base.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin
```

## Env vars

| Var | Default | Notes |
|---|---|---|
| `DISCORD_VOICE_BOT_TOKEN` | required | Second bot's token (≠ `DISCORD_BOT_TOKEN`) |
| `HUB_BASE_URL` | `http://localhost:4000` | Where UtteranceAppended POSTs go |
| `WHISPER_BIN` | `whisper-cli` | Override if installed elsewhere |
| `WHISPER_MODEL` | `~/.cache/whisper/ggml-base.bin` | GGML model file |
| `WHISPER_LANG` | `auto` | `de`, `en`, `auto`, ... |

## Manual smoke test (without the worker)

```
DISCORD_VOICE_BOT_TOKEN=… python bot.py
```

then in another shell:

```
echo '{"op":"join","guild_id":"693…","channel_id":"<voice_chan>","session_id":"test-1"}' \
  | nc -U /tmp/lore-voice.sock     # (no, this version reads stdin — see normal usage)
```

In normal operation the Elixir worker spawns this script with the right
env + writes JSON commands to stdin; you don't run it directly.

## Protocol

stdin: one JSON object per line.

```
{"op":"join", "guild_id":"...", "channel_id":"...", "session_id":"..."}
{"op":"leave", "guild_id":"..."}
{"op":"shutdown"}
```

stdout: one JSON object per line (status events for the worker to log).

```
{"event":"ready", "username":"...", "application_id":"..."}
{"event":"joined", "guild_id":"...", "channel_id":"...", "session_id":"..."}
{"event":"left", "guild_id":"...", "session_id":"..."}
{"event":"transcription_started", "session_id":"...", "speakers":N}
{"event":"transcription_done",    "session_id":"...", "utterance_count":N}
{"event":"error", "op":"...", "reason":"..."}
```
