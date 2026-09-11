defmodule Worker.Repo.JackStaende do
  @moduledoc """
  J4 (#1207): Jacks Stand je Sitzung lesen (`worker_jack_staende`, Fold
  `Worker.Materializer.JackStandFolds`) — die Grundlage für „noch N
  Iterationen“.
  """

  import Worker.Repo, only: [transaction: 1]

  alias Worker.Schema.Mnesia, as: S

  @doc """
  Der zuletzt abgelegte Stand einer Sitzung als
  `%{stand: %{"aussagen" => [...], "fortsetzung" => %{...}}, ts:, event_id:}`
  oder `nil`, wenn Jack die Sitzung noch nicht bearbeitet hat.
  """
  @spec jack_stand_for_session(String.t()) :: map() | nil
  def jack_stand_for_session(session_id) do
    case transaction(fn -> :mnesia.read(S.jack_staende(), session_id) end) do
      [{_, _sid, _cid, json, ts, event_id}] ->
        %{stand: Jason.decode!(json), ts: ts, event_id: event_id}

      _ ->
        nil
    end
  end
end
