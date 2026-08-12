defmodule Worker.Discord.Announcement do
  @moduledoc """
  Issue #989: die **gesprochene Consent-Ansage** beim Discord-Voice-Join. Der
  Browser-Mic-Pfad hat mit `AudioConsentRecorded` ein Einwilligungs-Signal; der
  Discord-Pfad (Epic #985) betrat den Kanal bis hierher **lautlos** — außer dem
  GM, der den Button geklickt hat, bekam niemand mit, dass ab jetzt aufgezeichnet
  wird. Diese Ansage schließt die Lücke hörbar, für alle im Kanal.

  **Warum Laufzeit-TTS statt einer vorgenerierten Datei im Repo:** die Ansage
  nennt den **Kampagnennamen** („… nimmt die Sitzung für die Kampagne X auf") —
  der ist pro Kampagne verschieden und jederzeit umbenennbar. Eine statische
  Datei kann das nicht leisten. Damit ist `piper` (neuronales, lokales TTS) die
  dritte externe Binary-Abhängigkeit des Workers neben `whisper-cli` und
  `ffmpeg`; das Setting-Muster ist identisch (`piper_bin`/`piper_model` ohne
  Default, #784 — fehlt es, failt es SICHTBAR statt still auf einen geratenen
  Pfad).

  **Erzeugt wird einmal pro Text, nicht pro Join:** Cache-Key ist ein Hash über
  den fertigen Ansagetext (Datei unter `<mnesia_dir>/tts/`, derselbe
  per-Worker-Ableitungspfad wie `audio_dir` seit #948 — zwei Worker auf einer
  Maschine teilen den Cache nicht). Ein Join einer schon bekannten Kampagne
  kostet also kein TTS. Kampagne umbenannt → neuer Hash → neue Datei; die alte
  bleibt liegen (wenige zehn KB, kein Aufräum-Pfad nötig).

  **Der Kampagnenname ist GM-getippter Freitext** und geht in einen
  Subprocess-Aufruf. Zwei Konsequenzen, beide bewusst:

    * Er wird **normalisiert + gedeckelt** (`normalize_name/1`: Whitespace
      kollabiert, Zeilenumbrüche raus, @announce_name_cap Zeichen) — ohne Deckel
      wäre eine Ansage beliebig lang, und Zeilenumbrüche wären für piper
      mehrere Sätze.
    * Der Text erreicht piper über eine **Datei auf stdin**, nie über die
      Kommandozeile (`sh -c '… < textfile'`). piper nimmt Text ausschließlich
      auf stdin (kein `--text`-Flag), und `System.cmd/3` kann kein stdin
      füttern — der Shell-Umweg ist deshalb nötig, aber der einzige
      user-kontrollierte Wert liegt dabei in der Datei und wird nie von der
      Shell interpretiert. Nur unsere eigenen Pfade werden gequotet.

  **Fehlerverhalten (best-effort, mit benannter Kehrseite):** scheitert die
  Erzeugung (piper nicht konfiguriert, Binary fehlt, Modell kaputt), läuft die
  **Aufnahme weiter** und der Fehler wird laut sichtbar (Logger + eigene
  `/admin/errors`-Klasse über `Worker.Discord.VoiceSession`). Die ehrliche
  Kehrseite: dann zeichnet der Bot **ohne hörbares Signal** auf — das
  Consent-Ziel ist in diesem Fall verfehlt, nur eben sichtbar statt lautlos.
  Die Alternative (Aufnahme abbrechen, weil TTS fehlt) wäre für den GM am
  Spielabend schlimmer; diese Abwägung ist eine Produkt-Entscheidung, keine
  technische Notwendigkeit.
  """

  require Logger

  alias Worker.Settings

  # ⚠ „Lorspai" ist KEIN Tippfehler, sondern eine **phonetische Schreibweise für
  # die TTS** (#989-Live-Abnahme: „LoreSpy" wurde deutsch ausgesprochen).
  # Hintergrund: im Deutschen wird `sp-` am Wortanfang zu „schp" (Sport →
  # Schport), weshalb „Spy" als „Schpei" herauskam. Innerhalb eines Wortes bleibt
  # `sp` dagegen `sp` (Wespe, Kaspar) — deshalb der Name als EIN Wort mit `sp` in
  # der Mitte. An echten piper-Hörproben abgenommen (Variante a4 von 9 getesteten).
  #
  # Lautschrift wäre der sauberere Weg, geht aber nicht: piper interpretiert
  # espeak-`[[…]]`-Phoneme nicht, sondern liest sie vor (verifiziert — Whisper
  # hörte aus `[[l'o:6spaI]]` ein „L6 spa e").
  @announce_prefix "Der Lorspai hat den Kanal betreten und nimmt die Sitzung"

  # GM-getippter Kampagnenname → Deckel, damit die Ansage nicht beliebig lang
  # wird (ein 5000-Zeichen-Name wäre sonst eine Minuten-Ansage im Voice-Kanal).
  @announce_name_cap 80

  @doc """
  Der fertige Ansagetext für einen Kampagnennamen. PURE (Tests hängen daran).
  Leerer/fehlender Name → neutrale Fassung ohne Namen (nie ein Crash und nie
  ein „für die Kampagne  auf" mit Loch).
  """
  @spec text_for(String.t() | nil) :: String.t()
  def text_for(campaign_name) do
    kern =
      case normalize_name(campaign_name) do
        "" -> @announce_prefix <> " für diese Kampagne auf."
        name -> @announce_prefix <> " für die Kampagne " <> name <> " auf."
      end

    kern <> " " <> consent_request()
  end

  @doc """
  Die Bitte um Einwilligung, die der Ansage folgt.

  **Issue #1005: sie verweist auf den KNOPF, nicht mehr auf den Satz.** Die
  gesprochene Zustimmung ist mit diesem Issue ausgesetzt (nicht gelöscht — s.
  `Worker.Recording.ConsentPhrase`), aus zwei Gründen: Akustik ist nicht
  identitätsgebunden (Cross-Talk/Lautsprecher-Echo würde einem Dritten eine
  Zustimmung unterstellen — der schwerste denkbare Fehler hier), und der
  Live-Lauf von #1002 zeigte, dass der Satz gesagt und nicht erkannt wurde.

  Eine Ansage, die um etwas bittet, das derzeit nichts auslöst, wäre schlimmer
  als keine: die Leute sprechen den Satz, nichts passiert, und ihre Spur fehlt
  hinterher. Deshalb nennt der Text ausschließlich den Weg, der auch wirkt.

  Sie sagt außerdem die Konsequenz des Nichtstuns — ohne die wäre die
  Einwilligung nicht informiert.
  """
  @spec consent_request() :: String.t()
  def consent_request do
    "Im Kanal steht eine Nachricht mit einem Knopf: Wer einverstanden ist, " <>
      "klickt dort auf Ich stimme zu. Ohne Zustimmung wird deine Stimme nicht gespeichert."
  end

  # ─── Issue #1005: Ansagen im laufenden Betrieb ──────────────────
  #
  # Alle drei sind PURE (nur Textbau). Wortlaut nach Vorgabe des Auftraggebers.
  # Der Kampagnenname fehlt hier bewusst: diese Ansagen laufen MITTEN im Spiel
  # und müssen kurz sein — die Kampagne wurde beim Join schon genannt.

  @doc """
  „X ist beigetreten." Ohne verwertbaren Namen eine namenlose Fassung — die
  Ansage darf nie ausfallen, nur weil ein Name fehlt oder unsprechbar ist
  (Emoji-Nick, reine Ziffern).
  """
  @spec text_for_join(String.t() | nil) :: String.t()
  def text_for_join(name) do
    case speakable_name(name) do
      nil -> "Eine weitere Person ist beigetreten."
      n -> "#{n} ist beigetreten."
    end
  end

  @doc """
  „A hat / A, B und C haben der Aufnahme noch nicht zugestimmt — …" als
  SAMMEL-Ansage. Einzeln anzusagen würde den Bot bei mehreren Ungeklärten
  minutenlang reden lassen.

  Leere Liste → `nil`: dann gibt es nichts anzusagen, und der Aufrufer darf
  nicht raten müssen.
  """
  @spec text_for_pending([String.t() | nil]) :: String.t() | nil
  def text_for_pending(names) when is_list(names) do
    speakable = names |> Enum.map(&speakable_name/1) |> Enum.reject(&is_nil/1)

    case {length(names), speakable} do
      {0, _} ->
        nil

      # Namen vorhanden, aber keiner sprechbar → namenlose Fassung mit der
      # richtigen Anzahl (die Information „wie viele" bleibt erhalten).
      {count, []} ->
        anonymous_pending(count)

      {_count, list} ->
        "#{enumerate(list)} #{verb(length(list))} der Aufnahme noch nicht zugestimmt. " <>
          consent_request()
    end
  end

  def text_for_pending(_), do: nil

  @doc """
  „X hat der Aufnahme zugestimmt." — die Bestätigung, dass der Klick ankam. Ohne
  sie weiß niemand, ob es funktioniert hat, und man wundert sich hinterher über
  eine fehlende Spur.
  """
  @spec text_for_granted(String.t() | nil) :: String.t()
  def text_for_granted(name) do
    case speakable_name(name) do
      nil -> "Die Zustimmung wurde gespeichert."
      n -> "#{n} hat der Aufnahme zugestimmt."
    end
  end

  defp anonymous_pending(1), do: "Eine Person hat der Aufnahme noch nicht zugestimmt. " <> consent_request()

  defp anonymous_pending(count),
    do: "#{count} Personen haben der Aufnahme noch nicht zugestimmt. " <> consent_request()

  defp verb(1), do: "hat"
  defp verb(_), do: "haben"

  # „A", „A und B", „A, B und C" — deutsche Aufzählung.
  defp enumerate([one]), do: one
  defp enumerate([a, b]), do: "#{a} und #{b}"

  defp enumerate(list) do
    {head, [last]} = Enum.split(list, length(list) - 1)
    "#{Enum.join(head, ", ")} und #{last}"
  end

  # Ein Name ist sprechbar, wenn nach der Normalisierung Buchstaben übrig sind.
  # Discord-Nicks enthalten Emoji, Zero-Width-Zeichen oder reine Symbolfolgen —
  # piper würde daraus eine unhörbare WAV-Datei erzeugen (und pro Variante eine
  # neue, weil der Cache auf dem Text-Hash keyt).
  defp speakable_name(name) do
    case normalize_name(name) do
      "" -> nil
      n -> if Regex.match?(~r/\p{L}/u, n), do: n, else: nil
    end
  end

  @doc """
  WAV-Pfad der Ansage einer Kampagne — aus dem Cache oder frisch erzeugt.

  `{:error, :piper_not_configured}` wenn `piper_bin`/`piper_model` fehlen (das
  ist der erwartete Zustand auf einem Worker, der TTS nie eingerichtet hat),
  `{:error, {:tts_failed, msg}}` bei einem echten Erzeugungs-Fehler.
  """
  @spec wav_for_campaign(String.t()) :: {:ok, Path.t()} | {:error, term()}
  def wav_for_campaign(campaign_id) when is_binary(campaign_id) do
    campaign_id
    |> campaign_name()
    |> text_for()
    |> wav_for_text()
  end

  @doc "Wie `wav_for_campaign/1`, aber für einen fertigen Text (Tests + Vorschau)."
  @spec wav_for_text(String.t()) :: {:ok, Path.t()} | {:error, term()}
  def wav_for_text(text) when is_binary(text) do
    path = cache_path(text)

    if usable_cache?(path) do
      {:ok, path}
    else
      generate(text, path)
    end
  end

  # ─── intern ──────────────────────────────────────────────────────

  defp campaign_name(campaign_id) do
    case Worker.Repo.get_campaign(campaign_id) do
      %{name: name} -> name
      _ -> nil
    end
  end

  # Whitespace (inkl. Zeilenumbrüchen) kollabieren + Deckel. Ein Name, der nur
  # aus Whitespace besteht, wird "" → text_for/1 nimmt die neutrale Fassung.
  defp normalize_name(name) when is_binary(name) do
    name
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, @announce_name_cap)
  end

  defp normalize_name(_), do: ""

  # Cache-Key = Hash über den TEXT (nicht über die campaign_id): eine Umbenennung
  # invalidiert automatisch, zwei Kampagnen mit identischem Namen teilen die Datei.
  defp cache_path(text) do
    hash =
      :crypto.hash(:sha256, text) |> Base.encode16(case: :lower) |> binary_part(0, 16)

    Path.join(cache_dir(), "ansage_#{hash}.wav")
  end

  # Issue #948-Muster: pro-Worker-Ableitung aus dem Mnesia-Dir statt eines
  # geteilten Fixpfads. Bei nicht-gestartetem Mnesia (Tests ohne Repo) greift
  # der tmp-Fallback.
  defp cache_dir do
    :mnesia.system_info(:directory) |> to_string() |> Path.join("tts")
  rescue
    _ -> Path.join(System.tmp_dir!(), "lore-tts")
  end

  # Eine 0-Byte-Datei ist ein abgebrochener Vorlauf, kein Cache-Treffer.
  defp usable_cache?(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > 0 -> true
      _ -> false
    end
  end

  defp generate(text, out_path) do
    with {:ok, bin, model} <- piper_config() do
      File.mkdir_p!(Path.dirname(out_path))
      run_piper(text, out_path, bin, model)
    end
  end

  # Kein Default (#784): ein ungesetztes piper_bin/piper_model heißt „TTS auf
  # diesem Worker nicht eingerichtet" — das ist ein sauberer, benannter Zustand,
  # kein Fehler-Rauschen. `Settings.get/1` liefert für :no_default-Keys nil.
  defp piper_config do
    bin = Settings.get(:piper_bin) |> presence()
    model = Settings.get(:piper_model) |> presence()

    if bin && model, do: {:ok, bin, model}, else: {:error, :piper_not_configured}
  end

  defp presence(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      s -> s
    end
  end

  defp presence(_), do: nil

  defp run_piper(text, out_path, bin, model) do
    txt_path = out_path <> ".txt"
    File.write!(txt_path, text)

    # piper nimmt Text NUR auf stdin (kein --text/--input_file), und System.cmd/3
    # kann kein stdin füttern → Shell mit Datei-Redirect. Der user-kontrollierte
    # Text liegt in der DATEI (nie in der Kommandozeile); die drei Pfade sind
    # unsere/Admin-Werte und werden gequotet.
    cmd =
      "#{sh_quote(bin)} --model #{sh_quote(model)} --output_file #{sh_quote(out_path)} " <>
        "< #{sh_quote(txt_path)}"

    result = System.cmd("sh", ["-c", cmd], stderr_to_stdout: true)
    _ = File.rm(txt_path)

    case result do
      {_out, 0} ->
        if usable_cache?(out_path) do
          # Seltenes Ereignis (nur beim ersten Join einer Kampagne bzw. nach
          # einer Umbenennung) — im Log sichtbar, damit ein unerwartet häufiges
          # Neu-Erzeugen auffällt (wäre ein Cache-Bug).
          Logger.info(
            "Worker.Discord.Announcement: Ansage erzeugt (#{byte_size(text)} Zeichen Text) → #{out_path}"
          )

          {:ok, out_path}
        else
          # Exit 0 OHNE Datei: genau die Silent-Failure-Klasse, die wir nie
          # durchlassen (ein „erfolgreicher" Lauf ohne Ergebnis).
          {:error, {:tts_failed, "piper exit 0, aber keine Ausgabedatei #{out_path}"}}
        end

      {out, code} ->
        _ = File.rm(out_path)
        {:error, {:tts_failed, "piper exit #{code}: #{String.slice(out, 0, 500)}"}}
    end
  rescue
    e -> {:error, {:tts_failed, Exception.message(e)}}
  end

  # POSIX-Single-Quote-Quoting: alles zwischen ' ist literal, ein enthaltenes '
  # wird als '\'' ausgebrochen.
  defp sh_quote(s) do
    "'" <> String.replace(to_string(s), "'", "'\\''") <> "'"
  end
end
