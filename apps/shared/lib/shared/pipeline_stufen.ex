defmodule Shared.PipelineStufen do
  @moduledoc """
  Issue #1122: die Stufenfolge eines Pipeline-Laufs als **Daten** statt als
  implizite `with`-Kette.

  Vorher stand die Reihenfolge nur im Kontrollfluss von
  `Worker.Recording.Pipeline.run_wahrheitsbild/4`. Daraus lässt sich weder
  „Schritt 3 von 7" noch „es fehlen noch Chronik und Epos" ableiten — niemand
  kennt die Liste. Das Laufband braucht beides.

  **Warum in `shared` und nicht im Worker:** der Hub rendert die Anzeige, der
  Worker meldet die Stufen. Zwei Listen an zwei Orten laufen auseinander, ohne
  dass etwas rot wird — dieselbe Begründung wie bei `Shared.Events`, und
  dieselbe Fehlerklasse wie die drei von Hand gepflegten Permission-Listen aus
  #1090 (ein fehlender Eintrag erzeugt keinen Fehler, sondern eine tote
  Anzeige).

  ## Spaltenzuordnung

  Jede Stufe zeigt auf die Spalte der CampaignLive, in der ihr Ergebnis
  erscheint. Das Laufband trägt deshalb dieselbe Reihenfolge wie das Layout und
  läuft von rechts nach links — die Richtung, in der die Daten durch die
  Spalten wandern. `nil` heißt: das Ergebnis hat keine eigene Spalte (die
  Bogen-Progressionen erscheinen in der Nachlese).

  ## Zählbare Einheiten

  `einheit` benennt, was innerhalb einer Stufe gezählt werden kann. `nil` heißt
  **nicht** „ein Teil von einem", sondern „hier gibt es nichts zu zählen": ein
  einzelner LLM-Aufruf. Die Anzeige lässt die Zahl dann weg, statt ein
  wertloses `1/1` zu zeigen.
  """

  @stufen [
    %{
      name: "smooth",
      titel: "Glättung",
      spalte: "glatt",
      art: :pflicht,
      einheit: :luecken_bloecke
    },
    %{name: "extract", titel: "Extraktion", spalte: "fakten", art: :pflicht, einheit: :chunks},
    %{name: "verify", titel: "Prüfung", spalte: "fakten", art: :pflicht, einheit: :fakten},
    %{name: "render", titel: "Resümee", spalte: "summaries", art: :pflicht, einheit: nil},
    %{name: "timeline", titel: "Chronik", spalte: "chronik", art: :best_effort, einheit: nil},
    %{name: "render_epos", titel: "Epos", spalte: "epos", art: :best_effort, einheit: nil},
    %{
      name: "render_arc_progressions",
      titel: "Bögen",
      spalte: nil,
      art: :best_effort,
      einheit: :boegen
    }
  ]

  @namen Enum.map(@stufen, & &1.name)

  @typedoc "Eine Stufe des Wahrheitsbild-Laufs."
  @type stufe :: %{
          name: String.t(),
          titel: String.t(),
          spalte: String.t() | nil,
          art: :pflicht | :best_effort,
          einheit: atom() | nil
        }

  @doc "Alle Stufen in Laufreihenfolge."
  @spec alle() :: [stufe()]
  def alle, do: @stufen

  @doc "Nur die Stufennamen, in Laufreihenfolge."
  @spec namen() :: [String.t()]
  def namen, do: @namen

  @doc "Anzahl der Stufen eines vollständigen Laufs (das „von 7\" der Anzeige)."
  @spec anzahl() :: pos_integer()
  def anzahl, do: length(@stufen)

  @doc """
  Position einer Stufe im Lauf, 1-basiert — `nil` für unbekannte Namen.

  Unbekannt ist kein Fehler: `stage1` (Transkription) läuft vor dem Lauf und
  gehört zur Aufnahme, `campaign_replay` ist der Lauf über viele Sessions.
  Beide melden über denselben Kanal und dürfen die Anzeige nicht stören.
  """
  @spec position(String.t()) :: pos_integer() | nil
  def position(name) when is_binary(name) do
    case Enum.find_index(@stufen, &(&1.name == name)) do
      nil -> nil
      i -> i + 1
    end
  end

  def position(_), do: nil

  @doc "Die Stufe zu einem Namen, oder `nil`."
  @spec finde(String.t()) :: stufe() | nil
  def finde(name) when is_binary(name), do: Enum.find(@stufen, &(&1.name == name))
  def finde(_), do: nil

  @doc "Gehört dieser Stufenname zum Wahrheitsbild-Lauf?"
  @spec stufe?(String.t()) :: boolean()
  def stufe?(name) when is_binary(name), do: name in @namen
  def stufe?(_), do: false

  @doc """
  Zählt diese Stufe Einheiten? Steuert, ob die Anzeige eine Zahl erwartet.
  """
  @spec zaehlbar?(String.t()) :: boolean()
  def zaehlbar?(name) do
    case finde(name) do
      %{einheit: e} when not is_nil(e) -> true
      _ -> false
    end
  end
end
