defmodule Worker.ThreadOverride do
  @moduledoc """
  Issue #836 (Epic #829 Slice D2): geteilte Key-/Dimension-Logik für das
  Handlungsbogen-Kurations-Overlay (`worker_thread_overrides`). EINE Quelle für
  Apply (`Materializer.Apply2`) UND Reader (`Repo.Artifacts.campaign_threads/1`),
  damit die Composite-Key-Konstruktion nicht an zwei Stellen driftet.

  Zwei unabhängige Override-Dimensionen pro Strang (je eine eigene Zeile, damit
  jede ein reiner Whole-Snapshot-LWW-Upsert bleibt):

    * **identity** — `rename` (neues Anzeige-Label) | `merge` (in einen anderen
      Strang falten) | `clear_identity` (Undo → neutral).
    * **lifecycle** — `resolve` (aufgelöst) | `dismiss` (ausgeblendet) |
      `reactivate` (Undo → aktiv).
    * **kind** (#885) — `mark_arc` (Handlungsbogen) | `mark_context` (zeitloses
      Weltwissen) | `clear_kind` (Undo → LLM-Klassifikation gilt).
  """

  @identity_actions ~w(rename merge clear_identity)
  @lifecycle_actions ~w(resolve dismiss reactivate)
  @kind_actions ~w(mark_arc mark_context clear_kind)

  @doc "Alle gültigen Kurations-Aktionen."
  @spec actions() :: [String.t()]
  def actions, do: @identity_actions ++ @lifecycle_actions ++ @kind_actions

  @doc "Dimension einer Aktion: `\"identity\"` | `\"lifecycle\"` | `\"kind\"` | nil."
  @spec dimension(term()) :: String.t() | nil
  def dimension(action) when action in @identity_actions, do: "identity"
  def dimension(action) when action in @lifecycle_actions, do: "lifecycle"
  def dimension(action) when action in @kind_actions, do: "kind"
  def dimension(_), do: nil

  @doc """
  Composite-Overlay-Key: `"<campaign_id>:<normalisiertes_canonical>:<dimension>"`.
  Der normalisierte canonical macht das Matching robust (Groß/Klein, Whitespace).
  """
  @spec key(String.t(), String.t(), String.t()) :: String.t()
  def key(campaign_id, canonical, dimension) do
    "#{campaign_id}:#{normalize(canonical)}:#{dimension}"
  end

  @doc """
  Normalisierung eines canonical-Labels — konsistent mit `ThreadRegistry`/dem
  Reader (lowercase + Whitespace zusammenfassen + trim).
  """
  @spec normalize(term()) :: String.t()
  def normalize(s) when is_binary(s) do
    s |> String.downcase() |> String.replace(~r/\s+/u, " ") |> String.trim()
  end

  def normalize(_), do: ""
end
