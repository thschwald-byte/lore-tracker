defmodule Worker.Timeline.Graph do
  @moduledoc """
  Issue #724 (Zeitstrahl, Slice A): löst eine Fakten-Liste temporal auf und
  behandelt dabei Event-Referenzen (`time_anchor: "event:<ausdruck>"`, z.B. „kurz
  nach dem Turmbrand") als Abhängigkeitskanten zwischen Fakten.

  Ablauf:
  1. **Fuzzy-Match** jeder Event-Referenz gegen die `claim`s der anderen Fakten
     (case-insensitiv, Teilstring). Genau EIN Treffer → Kante auf dessen Fakt.
     Kein/mehrdeutiger Treffer → Anker degradiert zu `unknown` (konservativ —
     lieber Review-Queue als falsche Kante; das ist die fragilste Stelle, #724).
  2. **Fixpunkt-Auflösung** (Kahn-artig): erst alle Fakten ohne Event-Kante (bzw.
     deren Ziel schon aufgelöst ist), dann iterativ die abhängigen. Jede Runde
     löst mindestens einen Fakt — passiert das nicht, sind die restlichen
     zyklisch oder hängen an Unauflösbarem → alle `unknown`. Harte
     Iterations-Schranke = Fakt-Anzahl (kein Endlos-Loop, auch bei Denkfehler).

  Session-übergreifende Event-Referenzen sind v1-out-of-scope: `resolve/3` läuft
  pro Session-Fakten-Menge, Referenzen über Session-Grenzen matchen nicht und
  landen konservativ in `unknown`.

  Rückgabe: die Fakten in Eingabe-Reihenfolge, jeder ergänzt um die String-Keys
  `"in_game_day"` (int|nil), `"precision"` (String), `"display"`,
  `"anchor_status"` (`"resolved"`|`"unknown"`).
  """

  alias Worker.Timeline.{Calendar, Resolver}

  @spec resolve([map()], Calendar.t(), integer() | nil) :: [map()]
  def resolve(facts, %Calendar{} = cal, session_anchor_day) when is_list(facts) do
    # Stabile Arbeits-IDs (falls ein Fakt kein "id"-Feld hat).
    indexed = Enum.with_index(facts, fn f, i -> {f, fact_id(f, i)} end)
    normalized = Enum.map(indexed, fn {f, id} -> {normalize_event_anchor(f, id, indexed), id} end)

    done = resolve_loop(normalized, cal, session_anchor_day, %{}, length(normalized) + 1)

    # In Eingabe-Reihenfolge zusammenführen.
    Enum.map(normalized, fn {f, id} -> merge_resolved(f, Map.fetch!(done, id)) end)
  end

  # ─── Event-Referenz-Matching ─────────────────────────────────────────

  defp normalize_event_anchor(%{"time_anchor" => "event:" <> ref} = fact, self_id, indexed) do
    down = ref |> to_string() |> String.trim() |> String.downcase()

    candidates =
      for {f, id} <- indexed,
          id != self_id,
          match_ref?(f, id, down),
          do: id

    case Enum.uniq(candidates) do
      [target] -> Map.put(fact, "time_anchor", "event:" <> target)
      _ -> Map.put(fact, "time_anchor", "unknown")
    end
  end

  defp normalize_event_anchor(fact, _self_id, _indexed), do: fact

  defp match_ref?(f, id, ref), do: String.downcase(id) == ref or claim_contains?(f, ref)

  defp claim_contains?(%{"claim" => c}, ref) when is_binary(c) and ref != "",
    do: String.contains?(String.downcase(c), ref)

  defp claim_contains?(_, _), do: false

  # ─── Fixpunkt-Auflösung ──────────────────────────────────────────────

  # done = %{id => resolved_map}. resolved_days (nur non-nil Tage) wird daraus
  # für die Resolver-Arithmetik abgeleitet.
  defp resolve_loop([], _cal, _anchor, done, _fuel), do: done

  defp resolve_loop(pending, cal, anchor_day, done, fuel) do
    resolved_days = for {id, %{in_game_day: d}} <- done, is_integer(d), into: %{}, do: {id, d}

    {ready, waiting} =
      Enum.split_with(pending, fn {f, _id} -> ready?(f, done) end)

    cond do
      # Kein Fortschritt möglich (Zyklus / unauflösbare Referenz) oder Sprit
      # alle → Rest hart als unknown auflösen. Terminiert immer.
      ready == [] or fuel <= 0 ->
        Enum.reduce(waiting, done, fn {_f, id}, acc ->
          Map.put(acc, id, unknown())
        end)

      true ->
        done2 =
          Enum.reduce(ready, done, fn {f, id}, acc ->
            Map.put(acc, id, Resolver.resolve_one(f, cal, anchor_day, resolved_days))
          end)

        resolve_loop(waiting, cal, anchor_day, done2, fuel - 1)
    end
  end

  # Ein Fakt ist auflösbar, wenn er nicht event-verankert ist ODER sein Ziel
  # bereits verarbeitet wurde (steht in `done` — auch wenn dessen Tag nil ist,
  # dann wird dieser Fakt sauber zu unknown).
  defp ready?(%{"time_anchor" => "event:" <> target}, done), do: Map.has_key?(done, target)
  defp ready?(_fact, _done), do: true

  # ─── Helpers ─────────────────────────────────────────────────────────

  defp fact_id(%{"id" => id}, _i) when is_binary(id) and id != "", do: id
  defp fact_id(_f, i), do: "auto-#{i}"

  defp merge_resolved(fact, %{in_game_day: day, precision: prec, display: disp, anchor_status: st}) do
    Map.merge(fact, %{
      "in_game_day" => day,
      "precision" => Atom.to_string(prec),
      "display" => disp,
      "anchor_status" => Atom.to_string(st)
    })
  end

  defp unknown,
    do: %{in_game_day: nil, precision: :unknown, display: "unbestimmt", anchor_status: :unknown}
end
