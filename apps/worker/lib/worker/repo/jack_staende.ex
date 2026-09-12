defmodule Worker.Repo.JackStaende do
  @moduledoc """
  J4 (#1207): Jacks Stand je Sitzung lesen (`worker_jack_staende`, Fold
  `Worker.Materializer.JackStandFolds`) — die Grundlage für „noch N
  Iterationen“.

  J5 (#1209, B4): dazu der Stand des Resümee-Jack
  (`worker_jack_resuemee_staende`) — seine Notizen sind die „vorigen
  Gedanken“, die der Resümee-Jack späterer Sitzungen liest.
  """

  import Worker.Repo, only: [transaction: 1]

  alias Worker.Schema.Mnesia, as: S

  @doc """
  Der zuletzt abgelegte Stand einer Sitzung als
  `%{stand: %{"aussagen" => [...], "fortsetzung" => %{...}}, ts:, event_id:}`
  oder `nil`, wenn Jack die Sitzung noch nicht bearbeitet hat.
  """
  @spec jack_stand_for_session(String.t()) :: map() | nil
  def jack_stand_for_session(session_id), do: lesen(S.jack_staende(), session_id)

  @doc """
  Der zuletzt abgelegte Stand des Resümee-Jack einer Sitzung als
  `%{stand: %{"notizen" => [...], "entwurf" => [...], "satzquellen" => [...],
  "zaehlwerte" => %{...}, "modell" => ..., "zeitpunkt" => ...}, ts:, event_id:}`
  oder `nil`, wenn der Resümee-Jack die Sitzung noch nicht geschrieben hat.
  """
  @spec jack_resuemee_stand_for_session(String.t()) :: map() | nil
  def jack_resuemee_stand_for_session(session_id),
    do: lesen(S.jack_resuemee_staende(), session_id)

  defp lesen(tabelle, session_id) do
    case transaction(fn -> :mnesia.read(tabelle, session_id) end) do
      [{_, _sid, _cid, json, ts, event_id}] ->
        %{stand: Jason.decode!(json), ts: ts, event_id: event_id}

      _ ->
        nil
    end
  end
end
