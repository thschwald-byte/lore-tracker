defmodule Worker.Jack.Frage do
  @moduledoc """
  Der Frage-Jack (#850, Epic #1195): beantwortet eine Frage an die Kampagne
  aus den geprüften Fakten — **ein** Lauf, eine Antwort, Belege dazu.

  **Er ist der erste Jack, der nicht zur Pipeline gehört.** Die vier anderen
  laufen, wenn eine Sitzung fertig ist; dieser läuft, weil jemand am Tisch
  etwas wissen will. Daraus folgen die Unterschiede:

    * **Ein Lauf statt drei.** Kein Überblick, kein Schreiben, keine
      Durchsicht — wer fragt, wartet.
    * **Deckel statt Ausdauer**: `@max_runden` (#{12}) und `@max_ms`
      (5 Minuten). Die Pipeline darf Stunden rechnen, eine Antwort am Tisch
      nicht. **Beides ist ein Deckel, keine Erwartung** — die erste Messung
      gegen eine echte Kampagne sagt, wie lange es wirklich dauert.
    * **Die Kampagne statt einer Sitzung** (`Worker.Jack.Frage.Eingabe`).
    * **Die Antwort wird geprüft** (`Worker.Jack.Frage.Stuetzung`), nachdem
      der Lauf endete: Existenz der Fakten prüft das Werkzeug, Stützung der
      Antwort das Modell.

  **Was geteilt ist**, wie beim Epos-Jack (#1210): der Stand (mit
  `art: :frage`, `lauf: :antworten`), die Lesebasis (Lesen, Suche, Bisher,
  Mitschnitte), der Halter, die Laufmechanik (`Worker.Jack.Resuemee.Lauf`)
  und die Werkzeug-Hülle (`Worker.Jack.Resuemee.Werkzeuge.aus/3`). Wo ein
  gemeinsames Modul dem Modell etwas über „das Resümee" sagt, richtet es sich
  nach `art`; für die anderen Jacks bleibt es byte-gleich.

  **Das Modell** wählt `modell_name/0` (`frage_jack_model`, leer = Jacks
  Modell); Endpunkt, Regler und Kontextfenster wie Jack. **Kein eigenes
  Kontextfenster**: `ctx_jack` ist kein Ollama-Parameter, sondern allein die
  Schwelle, ab der Jack seinen Verlauf zusammenfasst — ein kleinerer Wert
  spart nichts und ließe ihn nur früher zusammenfassen, in genau dem Lauf,
  dessen Belege erhalten bleiben sollen.

  Der Auftrag kommt aus `priv/jack/auftraege/frage.md`; **die Frage steht
  darin als abgesetzter Datenblock**, nie als Anweisungssatz.
  """

  alias Worker.Jack.Frage.{Abbild, Eingabe, Stuetzung, Werkzeuge, Zusammenfassung}
  alias Worker.Jack.Resuemee.Lauf
  alias Worker.Jack.Resuemee.Stand

  @max_runden 12
  @max_ms 5 * 60_000

  @doc "Der Rundendeckel eines Frage-Laufs."
  @spec max_runden() :: pos_integer()
  def max_runden, do: @max_runden

  @doc "Der Zeitdeckel eines Frage-Laufs in Millisekunden."
  @spec max_ms() :: pos_integer()
  def max_ms, do: @max_ms

  @doc """
  Beantwortet eine Frage auf einer Eingabe (`Worker.Jack.Frage.Eingabe`).

  Liefert `{:ok, %{antwort:, stand:, runden:, ms:}}`, wenn Jack mit `antworte`
  abschloss; sonst `{:error, {:frage_ohne_abschluss, ende}}`. Ohne Fakten
  `{:error, :keine_fakten}`.

  Optionen wie bei den anderen Jacks (`:modell`, `:kontext_fenster`,
  `:auftrag`, `:beobachter`, `:stand_beobachter`, `:protokoll`), dazu
  `:stuetzung` — `false` überspringt die Prüfung (für Tests ohne Modell), was
  die Antwort auf `geprueft: :ids` stehen lässt.
  """
  @spec laufen(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def laufen(eingabe, opts \\ []) do
    eingabe = Map.put(eingabe, :art, :frage)
    {stuetzen?, opts} = Keyword.pop(opts, :stuetzung, true)

    opts =
      opts
      |> Keyword.put_new(:max_runden, @max_runden)
      |> Keyword.put_new(:max_ms, @max_ms)

    with {:ok, r} <-
           Lauf.starten(
             eingabe,
             opts,
             fn -> Stand.fuer_frage(eingabe) end,
             fn -> auftrag(eingabe) end,
             :frage_ohne_abschluss,
             jack()
           ) do
      {:ok, Map.put(r, :antwort, antwort(r.stand, stuetzen?, opts))}
    end
  end

  @doc """
  Der Name des Modells: `frage_jack_model`, leer oder ungesetzt = Jacks
  Modell (`model_stage2_local`).
  """
  @spec modell_name() :: String.t() | nil
  def modell_name do
    case Worker.Settings.get(:frage_jack_model) do
      name when is_binary(name) ->
        if String.trim(name) == "", do: jacks_modell(), else: String.trim(name)

      _ ->
        jacks_modell()
    end
  end

  defp jacks_modell, do: Worker.Settings.model_for(2, :local)

  @doc "Das Modell des Frage-Jack: wie Jack, nur der Name ist eigen."
  @spec modell() :: {:ok, map()} | {:error, term()}
  def modell, do: Worker.Jack.Pipeline.modell(modell_name())

  @doc """
  Der Auftrag: die Vorlage `frage.md` aus `dir` (Default
  `priv/jack/auftraege/`). Fehlt sie, ist das `{:error, {:auftrag_fehlt,
  pfad}}` — **vor** dem Lauf, nicht mittendrin.
  """
  @spec auftrag(map(), Path.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def auftrag(eingabe, dir \\ nil) do
    with {:ok, vorlage} <- Lauf.vorlage("frage.md", dir) do
      {:ok, Lauf.einsetzen(vorlage, fuellen(eingabe))}
    end
  end

  @doc """
  Die Werte der Auftragsvorlage. `frage` ist der einzige Wert, der von aussen
  kommt; die Vorlage setzt ihn in einen abgesetzten Block, und `einsetzen/2`
  ersetzt in **einem** Durchgang — eingesetzter Text wird nicht noch einmal
  nach Platzhaltern durchsucht.
  """
  @spec fuellen(map()) :: %{String.t() => String.t()}
  def fuellen(eingabe) do
    fakten = Map.get(eingabe, :fakten, [])

    %{
      "frage" => Eingabe.frage(eingabe),
      "anzahl_fakten" => Integer.to_string(length(fakten)),
      "sitzungen" => sitzungen_satz(eingabe)
    }
  end

  # Eigener Satz statt `Lauf.fruehere_text/1`: Der spricht von „vor dieser
  # Sitzung" und ist damit sitzungsbezogen — eine Kampagnenfrage hat keine
  # „diese Sitzung", und der Jack liest ohnehin alle.
  defp sitzungen_satz(eingabe) do
    nummern =
      eingabe
      |> Map.get(:fruehere, [])
      |> Enum.map(& &1.nummer)
      |> Kernel.++([get_in(eingabe, [:sitzung, :nummer])])
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()

    case nummern do
      [] ->
        "Die Kampagne hat noch keine aufgezeichnete Sitzung."

      [n] ->
        "Die Kampagne hat eine Sitzung (#{n})."

      alle ->
        "Die Kampagne hat #{length(alle)} Sitzungen (#{List.first(alle)} bis #{List.last(alle)})."
    end
  end

  @doc "Die Kennung des Jack für Halter, Abbild und Laufsicht."
  @spec jack() :: map()
  def jack do
    %{
      werkzeuge: &Werkzeuge.fuer/1,
      zusammenfassung: &Zusammenfassung.fuer/1,
      abbild: &Abbild.abbild/1
    }
  end

  # Die Antwort aus dem Stand, geprüft. Ohne Antwort kann der Lauf nicht
  # abgeschlossen haben — `antworte` ist der einzige `:halt`.
  defp antwort(%Stand{antwort: nil}, _stuetzen?, _opts), do: nil
  defp antwort(%Stand{antwort: a}, false, _opts), do: a

  defp antwort(%Stand{antwort: a, fakten: fakten}, true, opts),
    do: Stuetzung.pruefen(a, fakten, Keyword.take(opts, [:modell, :model]))
end
