defmodule Worker.Jack.Referenz do
  @moduledoc """
  Der Referenzlauf mit Claude Code headless (Tom, 11.09.2026): S3 darf zu
  Anthropic, Max-Abo, Modell Fable mit `--effort max`; drei unabhängige Läufe,
  jeder nur Durchgang 1 (Phase 1 und 2). Claude Code ist die Agenten-Schleife,
  Jacks Werkzeuge kommen über den MCP-Server `mix lore.jack.mcp`
  (`Worker.Jack.Mcp`) — dieselben Werkzeuge, derselbe Halter, dieselbe Ablage
  wie im Port.

  Je Phase: eine MCP-Konfiguration, ein leeres Arbeitsverzeichnis (keine
  CLAUDE.md, keine Memories) und `claude -p` als Kindprozess mit

      --model <modell> --effort <stufe> --tools "" --strict-mcp-config
      --mcp-config <mcp.json> --allowedTools mcp__jack --permission-mode dontAsk
      --system-prompt <pi> --output-format stream-json --verbose
      --no-session-persistence

  Der Strom geht roh nach `claude_strom.jsonl` und übersetzt
  (`uebersetzen/2`) nach `protokoll.jsonl` im Format der Laufzeit — so lesen
  ihn die Laufsicht (Folge-Modus) und eves Auswertung wie bei J3. Den Stand
  (`stand.json`, `aussagen.jsonl` …) schreibt der Halter im MCP-Server in
  dieselbe Ablage.

  **Anders als der Port, für die Auswertung zu benennen:** Schleife,
  Kompaktierung (von Claude Code, vom Modell zusammengefasst) und
  Werkzeugaufruf-Takt kommen von Claude Code; das Denken liefert Claude Code
  headless nicht als Text (leere `thinking`-Blöcke, nur geschätzte Token);
  der Systemprompt ist pis (`Worker.Jack.Systemprompt`), wie in J3.
  """

  alias Worker.Agent.Protokoll
  alias Worker.Jack.{Fortsetzung, Gedaechtnis, Systemprompt, Zusammenfassung}

  @praefix "mcp__jack__"

  # ─── Strom → Protokoll (pur) ──────────────────────────────────────────

  defstruct runde: 0, offen: nil, zuletzt: nil, namen: %{}

  @type t :: %__MODULE__{}

  @doc "Neuer Übersetzer."
  @spec uebersetzer() :: t()
  def uebersetzer, do: %__MODULE__{}

  @doc """
  Ein Ereignis des `stream-json` in Protokoll-Ereignisse `{art, daten}`
  übersetzen. Die Blöcke einer Modellantwort kommen einzeln (Denken, Text,
  Werkzeugaufrufe mit derselben Nachrichten-ID); sie werden gesammelt und als
  eine `antwort` ausgegeben, sobald etwas anderes kommt.

  **Eine Antwort mit mehreren Werkzeugaufrufen kommt verschränkt:** Claude
  Code führt jeden Aufruf aus, sobald er da ist, und das Ergebnis steht im
  Strom vor dem nächsten Aufruf derselben Nachricht. Was nach einem Ergebnis
  mit derselben Nachrichten-ID kommt, ist deshalb keine neue Runde, sondern
  eine `antwort` mit `"fortsetzung" => true` in derselben Runde und ohne
  `nutzung` — sonst zählte jede Runde so oft, wie sie Aufrufe hat (so im
  ersten Probelauf, 11.09.: 7 Runden und 64k Eingabe statt 3 und 28k).
  Die `nutzung` einer Runde ist die des ersten Teils: die Eingabe stimmt, die
  Ausgabe ist dort noch unvollständig; die Summe steht im `ende`.
  """
  @spec uebersetzen(map(), t()) :: {[{String.t(), map()}], t()}
  def uebersetzen(%{"type" => "system", "subtype" => "init"} = e, z) do
    {[
       {"start",
        %{
          "modell" => "Claude Code #{e["claude_code_version"]}",
          "modell_name" => e["model"],
          "werkzeuge" => Enum.map(e["tools"] || [], &ohne_praefix/1),
          "kontext_fenster" => nil,
          "sitzung" => e["session_id"]
        }}
     ], z}
  end

  def uebersetzen(%{"type" => "assistant", "message" => %{"id" => id} = m}, z) do
    {vorher, z} = if z.offen && z.offen.id != id, do: abschliessen(z), else: {[], z}

    {neu, z} =
      cond do
        z.offen ->
          {[], z}

        id == z.zuletzt ->
          {[], %{z | offen: %{id: id, bloecke: [], nutzung: nil, fortsetzung: true}}}

        true ->
          {[{"anfrage", %{"runde" => z.runde + 1}}],
           %{
             z
             | runde: z.runde + 1,
               offen: %{id: id, bloecke: [], nutzung: nil, fortsetzung: false}
           }}
      end

    offen = %{
      z.offen
      | bloecke: z.offen.bloecke ++ (m["content"] || []),
        nutzung: if(z.offen.fortsetzung, do: nil, else: m["usage"] || z.offen.nutzung)
    }

    namen =
      for %{"type" => "tool_use", "id" => tid, "name" => n} <- m["content"] || [],
          into: z.namen,
          do: {tid, ohne_praefix(n)}

    {vorher ++ neu, %{z | offen: offen, namen: namen}}
  end

  def uebersetzen(%{"type" => "user", "message" => %{"content" => bloecke}}, z)
      when is_list(bloecke) do
    {vorher, z} = abschliessen(z)

    ergebnisse =
      for %{"type" => "tool_result"} = b <- bloecke do
        {"ergebnis",
         %{
           "runde" => z.runde,
           "id" => b["tool_use_id"],
           "name" => Map.get(z.namen, b["tool_use_id"], "?"),
           "art" => if(b["is_error"], do: "error", else: "ok"),
           "text" => ergebnis_text(b["content"])
         }}
      end

    {vorher ++ ergebnisse, z}
  end

  def uebersetzen(%{"type" => "system", "subtype" => "compact_boundary"} = e, z) do
    {vorher, z} = abschliessen(z)
    meta = e["compact_metadata"] || %{}

    {vorher ++
       [
         {"kompaktierung",
          %{
            "runde" => z.runde,
            "weggefallen" => 1,
            "tokens" => meta["pre_tokens"],
            "ausloeser" => meta["trigger"]
          }}
       ], z}
  end

  def uebersetzen(%{"type" => "rate_limit_event"} = e, z),
    do: {[{"nutzungsgrenze", Map.drop(e, ["type", "session_id", "uuid"])}], z}

  def uebersetzen(%{"type" => "result"} = e, z) do
    {vorher, z} = abschliessen(z)

    {vorher ++
       [
         {"ende",
          %{
            "ende" => e["subtype"],
            "fehler" => e["is_error"],
            "runden" => z.runde,
            "ms" => e["duration_ms"],
            "nutzung" => nutzung(e["usage"]),
            "kosten_usd_listenpreis" => e["total_cost_usd"]
          }}
       ], z}
  end

  def uebersetzen(_anderes, z), do: {[], z}

  @doc "Eine noch offene Modellantwort ausgeben."
  @spec abschliessen(t()) :: {[{String.t(), map()}], t()}
  def abschliessen(%{offen: nil} = z), do: {[], z}

  def abschliessen(%{offen: o} = z) do
    texte = for %{"type" => "text", "text" => t} <- o.bloecke, do: t
    denken = for %{"type" => "thinking"} = b <- o.bloecke, do: b["thinking"] || ""

    aufrufe =
      for %{"type" => "tool_use"} = b <- o.bloecke,
          do: %{"id" => b["id"], "name" => ohne_praefix(b["name"]), "argumente" => b["input"]}

    antwort = %{
      "runde" => z.runde,
      "ms" => 0,
      "stopp" => if(aufrufe == [], do: "stop", else: "werkzeuge"),
      "text" => leer_nil(Enum.join(texte, "\n")),
      "denken" => leer_nil(Enum.join(denken, "\n")),
      "aufrufe" => aufrufe,
      "nutzung" => nutzung(o.nutzung),
      "fortsetzung" => o.fortsetzung
    }

    {[{"antwort", antwort}], %{z | offen: nil, zuletzt: o.id}}
  end

  defp ohne_praefix(@praefix <> name), do: name
  defp ohne_praefix(name), do: name

  defp ergebnis_text(text) when is_binary(text), do: text

  defp ergebnis_text(bloecke) when is_list(bloecke),
    do: Enum.map_join(bloecke, "\n", &(&1["text"] || ""))

  defp ergebnis_text(anderes), do: inspect(anderes)

  # Eingabe = frisch + aus dem Cache gelesen + in den Cache geschrieben.
  defp nutzung(%{} = u) do
    %{
      "eingabe" =>
        (u["input_tokens"] || 0) + (u["cache_read_input_tokens"] || 0) +
          (u["cache_creation_input_tokens"] || 0),
      "ausgabe" => u["output_tokens"] || 0
    }
  end

  defp nutzung(_), do: nil

  defp leer_nil(""), do: nil
  defp leer_nil(text), do: text

  # ─── Lauf ─────────────────────────────────────────────────────────────

  @doc """
  Ein Referenzlauf: Durchgang 1, Phase 1 und Phase 2. Optionen: `:eingabe`
  (`%{bloecke:, cast:, straenge:}`), `:mcp_eingabe` (die Quelle für den
  MCP-Server: `%{"daten" => …, "namen" => …}` oder `%{"eingabe" => "demo"}`),
  `:auftraege` (aus `Worker.Jack.Messlauf.auftraege/1`), `:nach`, `:modell`,
  `:effort`, `:beispiele` (Pfad oder `nil`), `:claude` (Pfad der CLI),
  `:worker_dir`, `:max_ms` je Phase, `:beilagen`, `:melden`.
  """
  @spec laufen(keyword()) :: map()
  def laufen(opts) do
    e = Keyword.fetch!(opts, :eingabe)
    a = Keyword.fetch!(opts, :auftraege)
    nach = Keyword.fetch!(opts, :nach)
    basis = [bloecke: e.bloecke, cast: e.cast, straenge: e.straenge]
    max_block = length(e.bloecke) - 1
    p1_dir = Path.join([nach, "d1", "phase1"])
    d1 = Path.join(nach, "d1")

    auftrag1 =
      String.trim_trailing(a.phase1) <> "\n\nDer Mitschnitt hat die Blöcke 0 bis #{max_block}."

    p1 = phase(opts, 1, auftrag1, nil, p1_dir)

    phasen =
      if p1.halt do
        {:ok, s} = Fortsetzung.laden(p1_dir, basis ++ [phase: 2])
        gedaechtnis = s |> Gedaechtnis.notizen_text() |> String.trim_trailing()
        auftrag2 = String.trim_trailing(a.phase2) <> "\n\n## Dein Gedächtnis\n\n" <> gedaechtnis
        [p1, phase(opts, 2, auftrag2, p1_dir, d1)]
      else
        [p1]
      end

    beilegen(d1, Keyword.get(opts, :beilagen, []))

    ergebnis = %{
      "art" => "referenz",
      "modell" => Keyword.get(opts, :modell),
      "effort" => Keyword.get(opts, :effort),
      "beispiele" => Keyword.get(opts, :beispiele),
      "ende" =>
        if(Enum.all?(phasen, & &1.halt) and length(phasen) == 2,
          do: "fertig",
          else: "abgebrochen"
        ),
      "bestand" => bestand(d1),
      "phasen" => Enum.map(phasen, &Map.delete(&1, :halt))
    }

    File.write!(Path.join(nach, "messlauf.json"), Jason.encode_to_iodata!(ergebnis, pretty: true))
    ergebnis
  end

  @doc """
  Setzt einen abgebrochenen Referenzlauf unter `:nach` in Phase 2 fort — im
  selben Durchgang, mit einer frischen Claude-Code-Sitzung (Tom, 11.09.: nach
  dem Reset des Fünf-Stunden-Fensters weitermachen). Optionen wie `laufen/1`;
  Modell, Effort und Beispiele müssen dieselben sein wie im abgebrochenen
  Lauf.

  Fortgesetzt wird nur ein Lauf, dessen Phase 1 mit `fertig` abschloss und
  der danach abbrach — sonst `{:error, {:nicht_fortsetzbar, …}}`.

  Die neue Sitzung bekommt den Auftrag von Phase 2 und dahinter den
  Arbeitsstand, den die Laufzeit nach einer Kompaktierung einsetzt
  (`Worker.Jack.Zusammenfassung.text/1`: wo sie steht, das Gedächtnis, der
  nächste Schritt). Der Stand kommt aus der Ablage (`im_durchgang_laden/2`).
  **Für die Auswertung zu benennen:** der Lauf entsteht dann in Teilen; was
  die erste Sitzung nicht in Notizen oder Aussagen festgehalten hat, weiß die
  zweite nicht.

  Überschrieben wird nichts: die alte `messlauf.json` bleibt als
  `messlauf_vor_fortsetzung.json`, Rohstrom und MCP-Konfiguration des neuen
  Teils tragen die Teilnummer (`claude_strom_2.jsonl`), Protokoll und Journal
  werden fortgeschrieben. Die Beilagen, die der abgebrochene Lauf nach `d1/`
  gelegt hat, werden vorher entfernt (nur, wenn sie der Quelle gleichen) und
  am Ende wieder beigelegt — während des Laufs liegt `fakten_voll.tsv` nie in
  der Ablage.
  """
  @spec fortsetzen(keyword()) :: map() | {:error, term()}
  def fortsetzen(opts) do
    e = Keyword.fetch!(opts, :eingabe)
    a = Keyword.fetch!(opts, :auftraege)
    nach = Keyword.fetch!(opts, :nach)
    d1 = Path.join(nach, "d1")
    pfad = Path.join(nach, "messlauf.json")
    beilagen = Keyword.get(opts, :beilagen, [])
    basis = [bloecke: e.bloecke, cast: e.cast, straenge: e.straenge, phase: 2]

    with {:ok, alt} <- abgebrochener_lauf(pfad),
         :ok <- gleiche_einstellungen(alt, opts),
         :ok <- beilagen_entfernen(d1, beilagen),
         {:ok, s} <- im_durchgang_laden(d1, basis) do
      File.cp!(pfad, freier_name(nach, "messlauf_vor_fortsetzung"))
      teil = Enum.count(alt["phasen"], &(&1["nr"] == 2)) + 1
      auftrag = String.trim_trailing(a.phase2) <> "\n\n" <> Zusammenfassung.text(s)
      p = phase(opts, 2, auftrag, d1, d1, teil)
      beilegen(d1, beilagen)

      fortsetzung = %{
        "teil" => teil,
        "vorheriges_ende" => List.last(alt["phasen"])["ende"],
        "bestand_vorher" => s.lfd
      }

      ergebnis =
        Map.merge(alt, %{
          "ende" => if(p.halt, do: "fertig", else: "abgebrochen"),
          "bestand" => bestand(d1),
          "phasen" => alt["phasen"] ++ [Map.delete(p, :halt)],
          "fortsetzungen" => (alt["fortsetzungen"] || []) ++ [fortsetzung]
        })

      File.write!(pfad, Jason.encode_to_iodata!(ergebnis, pretty: true))
      ergebnis
    end
  end

  @doc """
  Setzt fort, bis der Lauf fertig ist (Tom, 11.09.: nach jedem Abbruch am
  Fünf-Stunden-Fenster automatisch zum nächsten Reset). Vor jedem Teil wird
  gewartet, bis das Fenster, an dem der letzte Teil scheiterte, zurückgesetzt
  ist (`grenze/1`, plus eine Minute).

  Aufgehört wird, wenn der Lauf fertig ist (`{:fertig, ergebnis}`), wenn ein
  Teil aus einem anderen Grund endet oder eine andere Grenze greift, etwa die
  der Woche (`{:aufgehoert, grund}`) — dort wäre Warten falsch —, oder nach
  `:max_teile` Teilen (Default 12). Optionen wie `fortsetzen/1`, dazu
  `:warten` (`fn ms -> … end`) und `:jetzt` (`fn -> Unixzeit end`) für Tests.
  """
  @spec bis_fertig(keyword()) :: {:fertig, map()} | {:aufgehoert, term()} | {:error, term()}
  def bis_fertig(opts), do: bis_fertig(opts, Keyword.get(opts, :max_teile, 12))

  defp bis_fertig(_opts, 0), do: {:aufgehoert, :max_teile}

  defp bis_fertig(opts, rest) do
    d1 = Path.join(Keyword.fetch!(opts, :nach), "d1")

    with :ok <- abwarten(opts, grenze(d1)),
         %{} = ergebnis <- fortsetzen(opts) do
      case {ergebnis["ende"], grenze(d1)} do
        {"fertig", _} -> {:fertig, ergebnis}
        {_, {:fuenf_stunden, _}} -> bis_fertig(opts, rest - 1)
        {_, anders} -> {:aufgehoert, {:teil_endete, anders}}
      end
    end
  end

  defp abwarten(opts, {:fuenf_stunden, reset}) do
    jetzt = Keyword.get(opts, :jetzt, fn -> System.os_time(:second) end).()
    melden(opts, {:warten, reset + 60})
    Keyword.get(opts, :warten, &Process.sleep/1).(max(reset + 60 - jetzt, 0) * 1000)
    :ok
  end

  defp abwarten(_opts, {:andere, typ, reset}), do: {:aufgehoert, {:grenze, typ, reset}}
  defp abwarten(_opts, :keine), do: :ok

  @doc """
  Ob der jüngste Teil in `d1` an einer Nutzungsgrenze endete:
  `{:fuenf_stunden, reset}`, `{:andere, typ, reset}` (Unixzeit des Resets)
  oder `:keine`. Maßgeblich ist das letzte `rate_limit_event` des jüngsten
  Rohstroms (`claude_strom.jsonl`, `claude_strom_2.jsonl` …), und nur, wenn
  es `rejected` meldet und der Teil mit einem Fehler endete.
  """
  @spec grenze(Path.t()) ::
          {:fuenf_stunden, integer()} | {:andere, String.t(), integer()} | :keine
  def grenze(d1) do
    case d1 |> Path.join("claude_strom*.jsonl") |> Path.wildcard() do
      [] ->
        :keine

      stroeme ->
        stroeme
        |> Enum.max_by(&teil_nummer/1)
        |> File.stream!()
        |> Enum.reduce({nil, false}, &grenze_zeile/2)
        |> grenze_aus()
    end
  end

  defp grenze_zeile(zeile, {limit, fehler}) do
    case Jason.decode(zeile) do
      {:ok, %{"type" => "rate_limit_event", "rate_limit_info" => i}} -> {i, fehler}
      {:ok, %{"type" => "result"} = r} -> {limit, r["is_error"] == true}
      _ -> {limit, fehler}
    end
  end

  defp grenze_aus({%{"status" => "rejected", "resetsAt" => t} = i, true}) do
    case i["rateLimitType"] do
      "five_hour" -> {:fuenf_stunden, t}
      typ -> {:andere, typ, t}
    end
  end

  defp grenze_aus(_), do: :keine

  defp teil_nummer(pfad) do
    case Regex.run(~r/claude_strom_(\d+)\.jsonl$/, pfad) do
      [_, n] -> String.to_integer(n)
      nil -> 1
    end
  end

  @doc """
  Der Stand, mit dem Phase 2 im selben Durchgang weiterläuft. Anders als
  `Worker.Jack.Fortsetzung.laden/2`, das für den NÄCHSTEN Durchgang lädt,
  bleibt der Durchgang der aus `stand.json` (dort leitet `laden/2` ihn aus
  dem höchsten `_iter` plus eins ab), und die gelesenen Bereiche kommen von
  dort zurück — ohne sie lehnte `fertig` ab, bis der ganze Mitschnitt ein
  zweites Mal gelesen ist. `sammelnd` bekommt dieselben Bereiche: es trägt
  nur `bis_wohin_gesammelt`, also das Maximum, und das ist dasselbe, sobald
  nach der ersten Aussage weitergelesen wurde.

  **Als gelesen zählt nur bis zum höchsten belegten Block.** Was nach der
  letzten eingetragenen Aussage gelesen wurde, war beim Abbruch vielleicht
  noch nicht verarbeitet — im ersten S3-Lauf (11.09.) war 531–612 gelesen,
  eingetragen aber nur bis 530 (eve). Mit dem vollen Lesestand begänne die
  neue Sitzung bei 613, und `fertig` sähe die Lücke nicht. So wird der Rest
  neu geholt: lieber einen Abschnitt zweimal lesen als ihn überspringen.
  """
  @spec im_durchgang_laden(Path.t(), keyword()) :: {:ok, Worker.Jack.Stand.t()} | {:error, term()}
  def im_durchgang_laden(dir, basis) do
    with {:ok, s} <- Fortsetzung.laden(dir, basis),
         {:ok, text} <- File.read(Path.join(dir, "stand.json")),
         {:ok, %{"durchgang" => d, "gelesen" => g}} when is_integer(d) and is_list(g) <-
           Jason.decode(text) do
      bis = Enum.max(s.belegte_bloecke, fn -> -1 end)
      gelesen = for [von, b] <- g, von <= bis, do: {von, min(b, bis)}
      {:ok, %{s | durchgang: d, gelesen: gelesen, sammelnd: gelesen}}
    else
      {:ok, _} -> {:error, {:stand_json, :form}}
      {:error, _} = fehler -> fehler
    end
  end

  defp abgebrochener_lauf(pfad) do
    with {:ok, text} <- File.read(pfad),
         {:ok,
          %{
            "art" => "referenz",
            "ende" => "abgebrochen",
            "phasen" => [%{"nr" => 1, "ende" => "halt"}, _ | _]
          } = alt} <- Jason.decode(text) do
      {:ok, alt}
    else
      {:ok, _} -> {:error, {:nicht_fortsetzbar, :phase1_offen_oder_nicht_abgebrochen}}
      {:error, grund} -> {:error, {:messlauf_json, grund}}
    end
  end

  # Ein Lauf misst nur, was er misst, wenn alle Teile gleich eingestellt sind.
  defp gleiche_einstellungen(alt, opts) do
    jetzt = %{
      "modell" => opts[:modell],
      "effort" => opts[:effort],
      "beispiele" => opts[:beispiele]
    }

    vorher = Map.take(alt, Map.keys(jetzt))
    if vorher == jetzt, do: :ok, else: {:error, {:einstellungen_anders, vorher, jetzt}}
  end

  defp beilegen(d1, beilagen) do
    for {quelle, ziel} <- beilagen, File.exists?(quelle) do
      File.mkdir_p!(d1)
      File.cp!(quelle, Path.join(d1, ziel))
    end

    :ok
  end

  # Nur eigene Kopien: weicht eine Datei von ihrer Quelle ab, bleibt sie liegen.
  defp beilagen_entfernen(d1, beilagen) do
    Enum.reduce_while(beilagen, :ok, fn {quelle, ziel}, :ok ->
      p = Path.join(d1, ziel)

      cond do
        not File.exists?(p) -> {:cont, :ok}
        File.read!(p) == File.read!(quelle) -> {:cont, File.rm(p)}
        true -> {:halt, {:error, {:beilage_weicht_ab, p}}}
      end
    end)
  end

  defp freier_name(dir, stamm) do
    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> Path.join(dir, "#{stamm}.json")
      n -> Path.join(dir, "#{stamm}_#{n}.json")
    end)
    |> Enum.find(&(not File.exists?(&1)))
  end

  # Teil 1 heißt wie immer, weitere Teile tragen ihre Nummer.
  defp teil_name(stamm, 1, endung), do: stamm <> endung
  defp teil_name(stamm, teil, endung), do: "#{stamm}_#{teil}#{endung}"

  defp phase(opts, nr, auftrag, von, nach, teil \\ 1) do
    File.mkdir_p!(Path.join(nach, "cc"))
    melden(opts, {:phase, nr, nach})

    konfig =
      Keyword.fetch!(opts, :mcp_eingabe)
      |> Map.merge(%{
        "phase" => nr,
        "von" => von,
        "nach" => nach,
        "beispiele" => if(nr == 2, do: Keyword.get(opts, :beispiele)),
        "im_durchgang" => teil > 1
      })

    konfig_pfad = Path.join(nach, teil_name("mcp_konfig", teil, ".json"))
    File.write!(konfig_pfad, Jason.encode_to_iodata!(konfig, pretty: true))

    befehl =
      "cd #{sh(Keyword.fetch!(opts, :worker_dir))} && exec mix lore.jack.mcp --konfig #{sh(konfig_pfad)} " <>
        "2>>#{sh(Path.join(nach, "mcp.stderr"))}"

    mcp_pfad = Path.join(nach, teil_name("mcp", teil, ".json"))

    File.write!(
      mcp_pfad,
      Jason.encode_to_iodata!(
        %{
          "mcpServers" => %{
            "jack" => %{"type" => "stdio", "command" => "/bin/sh", "args" => ["-c", befehl]}
          }
        },
        pretty: true
      )
    )

    args = [
      "-p",
      auftrag,
      "--model",
      Keyword.fetch!(opts, :modell),
      "--effort",
      Keyword.fetch!(opts, :effort),
      "--tools",
      "",
      "--strict-mcp-config",
      "--mcp-config",
      mcp_pfad,
      "--allowedTools",
      "mcp__jack",
      "--permission-mode",
      "dontAsk",
      "--system-prompt",
      Systemprompt.pi(),
      "--output-format",
      "stream-json",
      "--verbose",
      "--no-session-persistence"
    ]

    t0 = System.monotonic_time(:millisecond)

    {ende, protokoll_ende} =
      claude_laufen(opts, args, nach, teil_name("claude_strom", teil, ".jsonl"))

    halt = halt?(nach)

    %{
      nr: nr,
      teil: teil,
      verzeichnis: nach,
      halt: halt,
      ende: if(halt, do: "halt", else: inspect(ende)),
      ms: System.monotonic_time(:millisecond) - t0,
      claude: protokoll_ende
    }
  end

  # claude als Kindprozess: stdin leer, stderr in eine Datei, stdout Zeile für
  # Zeile übersetzt. Endet mit dem Prozess oder an der Zeitgrenze.
  defp claude_laufen(opts, args, nach, strom) do
    claude = Keyword.get_lazy(opts, :claude, fn -> System.find_executable("claude") end)
    stderr = Path.join(nach, "claude.stderr")

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        {:line, 1_048_576},
        cd: Path.join(nach, "cc"),
        args: ["-c", ~s(exec "$0" "$@" < /dev/null 2>>#{sh(stderr)}), claude | args]
      ])

    roh = File.open!(Path.join(nach, strom), [:write, :binary])
    protokoll = Protokoll.oeffnen(Path.join(nach, "protokoll.jsonl"))
    frist = System.monotonic_time(:millisecond) + Keyword.get(opts, :max_ms, 6 * 3_600_000)

    try do
      lesen(port, roh, protokoll, uebersetzer(), "", frist, nil)
    after
      File.close(roh)
      Protokoll.schliessen(protokoll)
    end
  end

  defp lesen(port, roh, protokoll, z, rest, frist, letztes_ende) do
    warte = max(frist - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, {:noeol, teil}}} ->
        lesen(port, roh, protokoll, z, rest <> teil, frist, letztes_ende)

      {^port, {:data, {:eol, teil}}} ->
        zeile = rest <> teil
        IO.binwrite(roh, [zeile, ?\n])

        {ereignisse, z} =
          case Jason.decode(zeile) do
            {:ok, %{} = e} -> uebersetzen(e, z)
            _ -> {[], z}
          end

        Enum.each(ereignisse, fn {art, d} -> Protokoll.schreiben(protokoll, art, d) end)

        ende =
          Enum.find_value(ereignisse, letztes_ende, fn
            {"ende", d} -> d
            _ -> nil
          end)

        lesen(port, roh, protokoll, z, "", frist, ende)

      {^port, {:exit_status, status}} ->
        {rest_ereignisse, _} = abschliessen(z)
        Enum.each(rest_ereignisse, fn {art, d} -> Protokoll.schreiben(protokoll, art, d) end)
        {{:exit, status}, letztes_ende}
    after
      warte ->
        abbrechen(port)
        Protokoll.schreiben(protokoll, "ende", %{"ende" => "zeitgrenze", "runden" => z.runde})
        {:zeitgrenze, letztes_ende}
    end
  end

  defp abbrechen(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> System.cmd("kill", ["-TERM", Integer.to_string(pid)])
      _ -> :ok
    end

    Port.close(port)
  rescue
    _ -> :ok
  end

  # Die Phase ist abgeschlossen, wenn fertig() mit halt geantwortet hat.
  defp halt?(nach) do
    pfad = Path.join(nach, "werkzeuge.jsonl")

    File.exists?(pfad) and
      pfad
      |> File.stream!()
      |> Enum.any?(fn z ->
        match?({:ok, %{"art" => "halt"}}, Jason.decode(z))
      end)
  end

  defp bestand(d1) do
    pfad = Path.join(d1, "aussagen.jsonl")

    if File.exists?(pfad),
      do:
        pfad
        |> File.stream!()
        |> Enum.count(fn z ->
          match?(
            {:ok, %{"nummer" => _} = a} when not is_map_key(a, "_verworfen"),
            Jason.decode(z)
          )
        end),
      else: 0
  end

  defp sh(text), do: "'" <> String.replace(text, "'", "'\\''") <> "'"

  defp melden(opts, ereignis), do: if(f = opts[:melden], do: f.(ereignis))
end
