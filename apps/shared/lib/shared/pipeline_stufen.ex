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

  ## Jacks drei Stufen (J4, #1207)

  Stufe 2 ist seit J4 Jack (`Worker.Jack.Pipeline`), und ein Jack-Lauf hat
  drei Teile, die je den ganzen Mitschnitt lesen: **Gedächtnis** (Phase 1),
  **Extraktion** (Phase 2) und **Verifikation** (Folgedurchgänge bis zur
  Sättigung). Jede zählt die Blöcke ihres eigenen Lesegangs; die Verifikation
  beginnt die Zählung je Durchgang neu. Die frühere Stufe „verify“ (Prüfung
  durch ein zweites Modell) gibt es nicht mehr. Die Extraktion behält den
  Namen `"extract"`, weil `/admin/errors` und die Fehlerklassen daran hängen.

  ## Die drei Läufe des Resümee-Jack (J5, #1209)

  Das Resümee schreibt seit B4 der Resümee-Jack (`Worker.Jack.Resuemee`) in
  drei frischen Läufen: **Überblick** (liest die Fakten, notiert Form und
  Gliederung), **Schreiben** (Absatz für Absatz, jeder Satz mit seinen
  Fakten) und **Durchsicht** (Absatz für Absatz gegen die Fakten). Drei
  Stufen statt einer mit Durchgängen, weil die Läufe verschieden zählen
  (Fakten, nichts, Absätze) und weil nur die Durchsicht best-effort ist: als
  Durchgang einer Pflichtstufe hielte `Fortschritt` den Lauf bei ihrem
  Fehlschlag für beendet, obwohl das Resümee aus dem Schreiben noch
  veröffentlicht wird und Chronik und Epos folgen. Das Schreiben behält den
  Namen `"render"` — wie `"extract"` beim Fakten-Jack hängen `/admin/errors`
  und die Spalten-Busy-Anzeige daran.

  ## Die drei Läufe des Epos-Jack (J6, #1210)

  Das Epos-Kapitel schreibt seit E4 der Epos-Jack (`Worker.Jack.Epos`), nach
  der Chronik, in denselben drei Läufen: **Überblick** (zählt gelesene
  Fakten), **Schreiben** (zählt nichts) und **Durchsicht** (zählt entschiedene
  Absätze je Durchgang). Anders als beim Resümee sind alle drei best-effort:
  das Epos war schon als einzelne Stufe best-effort — scheitert es, bleibt das
  bisherige Kapitel stehen, und die Bogen-Progressionen folgen trotzdem. Das
  Schreiben behält den Namen `"render_epos"`.
  """

  @stufen [
    %{
      name: "smooth",
      titel: "Glättung",
      spalte: "glatt",
      art: :pflicht,
      einheit: :luecken_bloecke
    },
    # Ohne Gedächtnis und Extraktion gibt es keinen Bestand, der für die
    # Sitzung steht — der Lauf endet dort (`Worker.Jack.Pipeline.laufen/2`).
    %{
      name: "jack_gedaechtnis",
      titel: "Gedächtnis",
      spalte: "fakten",
      art: :pflicht,
      einheit: :bloecke
    },
    %{name: "extract", titel: "Extraktion", spalte: "fakten", art: :pflicht, einheit: :bloecke},
    # best-effort, weil eine abgebrochene Verifikation den Lauf NICHT beendet:
    # sie behält, was sie eingetragen hat (jede Aussage ist einzeln belegt
    # geprüft), und danach kommen Resümee, Chronik und Epos. Als Pflichtstufe
    # hielte `Fortschritt` den Lauf bei ihrem Fehlschlag für beendet, und das
    # Laufband verschwände, während die Pipeline weiterrechnet.
    %{
      name: "jack_verifikation",
      titel: "Verifikation",
      spalte: "fakten",
      art: :best_effort,
      einheit: :bloecke
    },
    # J5 (#1209): die drei Läufe des Resümee-Jack. Überblick und Schreiben
    # sind Pflicht — ohne sie gibt es kein Resümee, und der Lauf endet dort
    # wie bisher beim Render. Die Durchsicht ist best-effort: scheitert sie,
    # gilt der Entwurf aus dem Schreiben, und es geht weiter. Die Titel nennen
    # das Resümee neutral; im Laufband ersetzt die Überschrift aus „Stil
    # setzen“ das Wort (`HubWeb.CampaignLive.Laufband.titel/2`).
    %{
      name: "resuemee_ueberblick",
      titel: "Resümee: Überblick",
      spalte: "summaries",
      art: :pflicht,
      einheit: :fakten
    },
    %{
      name: "render",
      titel: "Resümee: Schreiben",
      spalte: "summaries",
      art: :pflicht,
      einheit: nil
    },
    %{
      name: "resuemee_durchsicht",
      titel: "Resümee: Durchsicht",
      spalte: "summaries",
      art: :best_effort,
      einheit: :absaetze
    },
    %{name: "timeline", titel: "Chronik", spalte: "chronik", art: :best_effort, einheit: nil},
    # J6 (#1210, E4): die drei Läufe des Epos-Jack, alle best-effort — ein
    # Fehlschlag darf den Lauf nicht beenden, danach kommen die
    # Bogen-Progressionen, und das bisherige Kapitel bleibt stehen. Das
    # Schreiben behält den Namen `render_epos` (`/admin/errors`, Spalten-
    # Anzeige); im Laufband ersetzt die Überschrift der Epos-Spalte das Wort
    # (`HubWeb.CampaignLive.Laufband.titel/2`).
    %{
      name: "epos_ueberblick",
      titel: "Epos: Überblick",
      spalte: "epos",
      art: :best_effort,
      einheit: :fakten
    },
    %{
      name: "render_epos",
      titel: "Epos: Schreiben",
      spalte: "epos",
      art: :best_effort,
      einheit: nil
    },
    %{
      name: "epos_durchsicht",
      titel: "Epos: Durchsicht",
      spalte: "epos",
      art: :best_effort,
      einheit: :absaetze
    },
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

  @doc "Anzahl der Stufen eines vollständigen Laufs (das „von 8\" der Anzeige)."
  @spec anzahl() :: pos_integer()
  def anzahl, do: length(@stufen)

  @doc """
  Die Namen der Stufen, deren Ergebnis in `spalte` erscheint, in
  Laufreihenfolge — für den Arbeitet-Hinweis einer Spalte. Aus den Daten statt
  als Literal im Template: dort fehlten sonst neue Stufen, ohne dass etwas rot
  wird.
  """
  @spec namen_fuer_spalte(String.t()) :: [String.t()]
  def namen_fuer_spalte(spalte),
    do: for(%{spalte: ^spalte, name: name} <- @stufen, do: name)

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
