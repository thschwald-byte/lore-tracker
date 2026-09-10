defmodule HubWeb.CampaignLive.GapMarker do
  @moduledoc """
  Issue #917 (Epic #911, Cut 3): der reader-sichtbare **Gap-Trust-Marker**.
  „Vertrauen-aber-markieren" statt klemmen — abgeleitete Inhalte (Chronik/Resümee/
  Epos-Kapitel), die über ihre `source_refs` eine unbestätigte ASR-Lücke berühren,
  bekommen ein 🕳-Zeichen.

  **Seit #1198 rechnet der Worker den Marker.** Vorher war das ein Join im Hub
  gegen das Skelett aller geglätteten Blöcke — genau die Liste, die am
  10.09.2026 einen einzelnen Tab zum Hub-Killer gemacht hat. Der Worker liefert
  jetzt `luecken_marker`: die Schlüssel `summary:<session_id>`, `chronik:<id>`,
  `epos_chapter:<id>` aller Derivationen mit offener Lücke, **kampagnenweit
  vollständig in jeder Antwort** (`Worker.Repo.GlattQuellen.marker/2`). Der Hub
  ersetzt die Menge nur noch; zusammenflicken muss er nichts.

  Ausgelagert aus `HubWeb.CampaignLive.Components` (God-Module-Grenze).
  """

  import Phoenix.Component, only: [assign: 3]

  @doc """
  Die Marker aus einer Worker-Antwort übernehmen. **Fehlt der Schlüssel**
  (alter Worker, oder ein Scope ohne `refs`-Flag), bleibt der bisherige Stand —
  eine Antwort ohne Marker ist keine Aussage „keine Lücken".
  """
  @spec uebernehmen(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def uebernehmen(socket, %{"luecken_marker" => keys}) when is_list(keys),
    do: assign(socket, :luecken_marker, MapSet.new(keys))

  def uebernehmen(socket, _snap), do: socket

  @doc """
  Trägt diese Derivation den 🕳? `kind` ist `"summary"`, `"chronik"` oder
  `"epos_chapter"` — dieselben Namen wie im Worker.
  """
  @spec markiert?(MapSet.t() | nil, String.t(), String.t() | nil) :: boolean()
  def markiert?(%MapSet{} = marker, kind, id) when is_binary(id),
    do: MapSet.member?(marker, "#{kind}:#{id}")

  def markiert?(_marker, _kind, _id), do: false
end
