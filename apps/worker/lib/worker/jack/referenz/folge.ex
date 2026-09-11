defmodule Worker.Jack.Referenz.Folge do
  @moduledoc """
  Wie ein Referenzlauf (`Worker.Jack.Referenz`) nach dem ersten Teil
  weitergeht (Tom, 11.09.2026): fortsetzen, wenn ein Teil an der
  Nutzungsgrenze des Abos abbrach, und Folgedurchgänge bis zur Sättigung —
  wie der Messlauf des Ports (`Worker.Jack.Messlauf`), damit der Referenzlauf
  genauso iteriert wie die anderen. Jeder Folgedurchgang liest den ganzen
  Mitschnitt mit dem Auftrag `folgelauf` und dem Gedächtnis des vorigen in
  ein eigenes Verzeichnis `d<n>`; gesättigt ist der Lauf, wenn ein
  Folgedurchgang nichts Neues einträgt, spätestens nach Durchgang 8.

  Den Zustand trägt `messlauf.json`: jede Phase und jeder Teil steht unter
  `phasen` mit `durchgang` (fehlt er, war es Durchgang 1) und `teil`;
  `durchgaenge` fasst die abgeschlossenen zusammen (`vorher`, `bestand`,
  `neu` — die höchste Aussagenummer, wie `lfd` im Port). `naechster_schritt/3`
  liest daraus, was als Nächstes zu tun ist, `fortsetzen/1` tut genau diesen
  einen Schritt, `bis_fertig/1` wiederholt das und wartet an der
  Nutzungsgrenze.

  **Fortsetzen im selben Durchgang** (nach einem Abbruch): eine frische
  Claude-Code-Sitzung bekommt den Auftrag des Durchgangs und dahinter den
  Arbeitsstand, den die Laufzeit nach einer Kompaktierung einsetzt
  (`Worker.Jack.Zusammenfassung.text/1`); der Stand kommt aus der Ablage
  (`im_durchgang_laden/2`). **Für die Auswertung zu benennen:** ein
  Durchgang entsteht dann in Teilen; was die erste Sitzung nicht in Notizen
  oder Aussagen festhielt, weiß die zweite nicht.

  Überschrieben wird nichts: vor jedem Schritt bleibt die alte `messlauf.json`
  als `messlauf_vor_fortsetzung*.json` liegen, Rohstrom und MCP-Konfiguration
  eines weiteren Teils tragen die Teilnummer (`claude_strom_2.jsonl`),
  Protokoll und Journal werden fortgeschrieben. Die Beilagen verlassen ein
  Verzeichnis, bevor darin weitergearbeitet wird (nur eigene, unveränderte
  Kopien), und kommen am Ende des Teils wieder hinein — während des Laufs
  liegt `fakten_voll.tsv` nie in der Ablage, aus der gearbeitet wird.
  """

  alias Worker.Jack.{Fortsetzung, Gedaechtnis, Referenz, Zusammenfassung}

  @max_durchgaenge 8

  @type schritt ::
          {:fortsetzen, pos_integer()}
          | {:durchgang, pos_integer()}
          | {:fertig, :gesaettigt | :deckel}

  # ─── Was als Nächstes kommt ───────────────────────────────────────────

  @doc """
  Der nächste Schritt eines Laufs unter `nach`, aus seiner `messlauf.json`
  (`lauf`): den letzten Durchgang fortsetzen, wenn sein letzter Teil nicht
  mit `fertig` endete; sonst gesättigt, wenn ein Folgedurchgang nichts Neues
  brachte; sonst am Deckel; sonst der nächste Durchgang. Ein Lauf, dessen
  Phase 1 nicht abschloss, ist nicht fortsetzbar.
  """
  @spec naechster_schritt(map(), Path.t(), pos_integer()) :: schritt() | {:error, term()}
  def naechster_schritt(lauf, nach, max \\ @max_durchgaenge)

  def naechster_schritt(
        %{"phasen" => [%{"nr" => 1, "ende" => "halt"}, _ | _] = phasen},
        nach,
        max
      ) do
    letzte = List.last(phasen)
    n = durchgang_von(letzte)

    cond do
      letzte["ende"] != "halt" -> {:fortsetzen, n}
      n >= 2 and lfd(dir(nach, n)) <= lfd(dir(nach, n - 1)) -> {:fertig, :gesaettigt}
      n >= max -> {:fertig, :deckel}
      true -> {:durchgang, n + 1}
    end
  end

  def naechster_schritt(_lauf, _nach, _max), do: {:error, {:nicht_fortsetzbar, :phase1_offen}}

  # ─── Ein Schritt ──────────────────────────────────────────────────────

  @doc """
  Führt den nächsten Schritt aus (`naechster_schritt/3`) und liefert die neue
  `messlauf.json` als Map — oder `{:fertig, lauf}`, wenn nichts mehr zu tun
  ist. Optionen wie `Worker.Jack.Referenz.laufen/1`; Modell, Effort und
  Beispiele müssen dieselben sein wie im bisherigen Lauf, dazu
  `:max_durchgaenge` (Default 8).
  """
  @spec fortsetzen(keyword()) :: map() | {:fertig, map()} | {:error, term()}
  def fortsetzen(opts) do
    nach = Keyword.fetch!(opts, :nach)

    with {:ok, lauf} <- lauf_lesen(Path.join(nach, "messlauf.json")),
         :ok <- gleiche_einstellungen(lauf, opts) do
      case naechster_schritt(lauf, nach, max_durchgaenge(opts)) do
        {:fertig, _} -> {:fertig, lauf}
        {:error, _} = fehler -> fehler
        schritt -> ausfuehren(opts, lauf, schritt)
      end
    end
  end

  defp ausfuehren(opts, lauf, {:fortsetzen, n}) do
    a = Keyword.fetch!(opts, :auftraege)
    d = dir(opts[:nach], n)
    beilagen = Keyword.get(opts, :beilagen, [])

    with :ok <- beilagen_entfernen(d, beilagen),
         {:ok, s} <- im_durchgang_laden(d, basis(opts)) do
      teil = Enum.count(lauf["phasen"], &(&1["nr"] == 2 and durchgang_von(&1) == n)) + 1
      grund = if n == 1, do: a.phase2, else: a.folgelauf
      auftrag = String.trim_trailing(grund) <> "\n\n" <> Zusammenfassung.text(s)
      p = Referenz.phase(opts, 2, auftrag, d, d, teil, n)
      Referenz.beilegen(d, beilagen)

      fortsetzung = %{
        "durchgang" => n,
        "teil" => teil,
        "vorheriges_ende" => List.last(lauf["phasen"])["ende"],
        "bestand_vorher" => s.lfd
      }

      nachtragen(opts, lauf, p, [fortsetzung])
    end
  end

  defp ausfuehren(opts, lauf, {:durchgang, n}) do
    a = Keyword.fetch!(opts, :auftraege)
    vorher = dir(opts[:nach], n - 1)
    d = dir(opts[:nach], n)

    # Ein Verzeichnis, das die messlauf.json nicht kennt, ist ein halber
    # früherer Versuch: sein Journal könnte ein altes `fertig` tragen.
    with :ok <- if(File.exists?(d), do: {:error, {:verzeichnis_gibt_es_schon, d}}, else: :ok),
         {:ok, s} <- Fortsetzung.laden(vorher, basis(opts)) do
      gedaechtnis = s |> Gedaechtnis.notizen_text() |> String.trim_trailing()
      auftrag = String.trim_trailing(a.folgelauf) <> "\n\n## Dein Gedächtnis\n\n" <> gedaechtnis
      p = Referenz.phase(opts, 2, auftrag, vorher, d, 1, n)
      Referenz.beilegen(d, Keyword.get(opts, :beilagen, []))
      nachtragen(opts, lauf, p, [])
    end
  end

  defp nachtragen(opts, lauf, p, fortsetzungen) do
    nach = Keyword.fetch!(opts, :nach)
    pfad = Path.join(nach, "messlauf.json")
    File.cp!(pfad, freier_name(nach, "messlauf_vor_fortsetzung"))
    phasen = lauf["phasen"] ++ [Map.delete(p, :halt)]

    # Über JSON, damit die neue Phase dieselbe Form (Zeichenketten als
    # Schlüssel) hat wie die alten — erst danach wird über alle gezählt.
    neu =
      Map.merge(lauf, %{
        "phasen" => phasen,
        "bestand" => Referenz.bestand(p.verzeichnis),
        "fortsetzungen" => (lauf["fortsetzungen"] || []) ++ fortsetzungen
      })
      |> Jason.encode!()
      |> Jason.decode!()

    neu =
      Map.merge(neu, %{
        "durchgaenge" => durchgaenge(neu["phasen"], nach),
        "ende" => ende(naechster_schritt(neu, nach, max_durchgaenge(opts)))
      })

    File.write!(pfad, Jason.encode_to_iodata!(neu, pretty: true))
    neu
  end

  defp ende({:fertig, grund}), do: Atom.to_string(grund)
  defp ende({:fortsetzen, _}), do: "abgebrochen"
  defp ende(_weiter), do: "weiter"

  defp durchgaenge(phasen, nach) do
    for %{"nr" => 2, "ende" => "halt"} = p <- phasen do
      n = durchgang_von(p)
      vorher = if n == 1, do: 0, else: lfd(dir(nach, n - 1))
      bestand = lfd(dir(nach, n))

      %{
        "nr" => n,
        "verzeichnis" => dir(nach, n),
        "vorher" => vorher,
        "bestand" => bestand,
        "neu" => bestand - vorher
      }
    end
  end

  # ─── Bis fertig ───────────────────────────────────────────────────────

  @doc """
  Wiederholt `fortsetzen/1`, bis der Lauf gesättigt oder am Deckel ist (Tom,
  11.09.: nach jedem Abbruch am Fünf-Stunden-Fenster automatisch zum nächsten
  Reset fortsetzen). Vor jedem Schritt wird gewartet, bis das Fenster, an dem
  der letzte Teil scheiterte, zurückgesetzt ist (`grenze/1`, plus eine
  Minute).

  Aufgehört wird, wenn nichts mehr zu tun ist (`{:fertig, lauf}`), wenn ein
  Teil aus einem anderen Grund endet oder eine andere Grenze greift, etwa
  die der Woche (`{:aufgehoert, grund}`) — dort wäre Warten falsch —, oder
  nach `:max_teile` Schritten (Default 30). Optionen wie `fortsetzen/1`,
  dazu `:warten` (`fn ms -> … end`) und `:jetzt` (`fn -> Unixzeit end`) für
  Tests.
  """
  @spec bis_fertig(keyword()) :: {:fertig, map()} | {:aufgehoert, term()} | {:error, term()}
  def bis_fertig(opts), do: bis_fertig(opts, Keyword.get(opts, :max_teile, 30))

  defp bis_fertig(_opts, 0), do: {:aufgehoert, :max_teile}

  defp bis_fertig(opts, rest) do
    nach = Keyword.fetch!(opts, :nach)

    with {:ok, lauf} <- lauf_lesen(Path.join(nach, "messlauf.json")),
         :ok <- gleiche_einstellungen(lauf, opts) do
      case naechster_schritt(lauf, nach, max_durchgaenge(opts)) do
        {:fertig, _} -> {:fertig, lauf}
        {:error, _} = fehler -> fehler
        schritt -> bis_fertig_schritt(opts, rest, lauf, schritt)
      end
    end
  end

  defp bis_fertig_schritt(opts, rest, lauf, {_art, n} = schritt) do
    d = dir(Keyword.fetch!(opts, :nach), n)

    with :ok <- abwarten(opts, grenze(d)),
         %{} = neu <- ausfuehren(opts, lauf, schritt) do
      cond do
        List.last(neu["phasen"])["ende"] == "halt" -> bis_fertig(opts, rest - 1)
        match?({:fuenf_stunden, _}, grenze(d)) -> bis_fertig(opts, rest - 1)
        true -> {:aufgehoert, {:teil_endete, grenze(d)}}
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
  Ob der jüngste Teil in `dir` an einer Nutzungsgrenze endete:
  `{:fuenf_stunden, reset}`, `{:andere, typ, reset}` (Unixzeit des Resets)
  oder `:keine`. Maßgeblich ist das letzte `rate_limit_event` des jüngsten
  Rohstroms (`claude_strom.jsonl`, `claude_strom_2.jsonl` …), und nur, wenn
  es `rejected` meldet und der Teil mit einem Fehler endete.
  """
  @spec grenze(Path.t()) ::
          {:fuenf_stunden, integer()} | {:andere, String.t(), integer()} | :keine
  def grenze(dir) do
    case dir |> Path.join("claude_strom*.jsonl") |> Path.wildcard() do
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

  # ─── Stand im selben Durchgang ────────────────────────────────────────

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

  # ─── Hilfen ───────────────────────────────────────────────────────────

  defp lauf_lesen(pfad) do
    with {:ok, text} <- File.read(pfad),
         {:ok, %{"art" => "referenz", "phasen" => [_ | _]} = lauf} <- Jason.decode(text) do
      {:ok, lauf}
    else
      {:ok, _} -> {:error, {:messlauf_json, :form}}
      {:error, grund} -> {:error, {:messlauf_json, grund}}
    end
  end

  # Ein Lauf misst nur, was er misst, wenn alle Teile gleich eingestellt sind.
  defp gleiche_einstellungen(lauf, opts) do
    jetzt = %{
      "modell" => opts[:modell],
      "effort" => opts[:effort],
      "beispiele" => opts[:beispiele]
    }

    vorher = Map.take(lauf, Map.keys(jetzt))
    if vorher == jetzt, do: :ok, else: {:error, {:einstellungen_anders, vorher, jetzt}}
  end

  # Nur eigene Kopien: weicht eine Datei von ihrer Quelle ab, bleibt sie liegen.
  defp beilagen_entfernen(d, beilagen) do
    Enum.reduce_while(beilagen, :ok, fn {quelle, ziel}, :ok ->
      p = Path.join(d, ziel)

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

  # Die höchste Aussagenummer in einer Ablage — `lfd` im Port; verworfene
  # zählen mit, eine Nummer wird nie zweimal vergeben.
  defp lfd(d) do
    pfad = Path.join(d, "aussagen.jsonl")

    if File.exists?(pfad) do
      pfad
      |> File.stream!()
      |> Enum.reduce(0, fn z, m ->
        case Jason.decode(z) do
          {:ok, %{"nummer" => n}} when is_integer(n) -> max(m, n)
          _ -> m
        end
      end)
    else
      0
    end
  end

  defp basis(opts) do
    e = Keyword.fetch!(opts, :eingabe)
    [bloecke: e.bloecke, cast: e.cast, straenge: e.straenge, phase: 2]
  end

  defp dir(nach, n), do: Path.join(nach, "d#{n}")
  defp durchgang_von(p), do: p["durchgang"] || 1
  defp max_durchgaenge(opts), do: Keyword.get(opts, :max_durchgaenge, @max_durchgaenge)
  defp melden(opts, ereignis), do: if(f = opts[:melden], do: f.(ereignis))
end
