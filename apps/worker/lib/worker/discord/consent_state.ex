defmodule Worker.Discord.ConsentState do
  @moduledoc """
  Issue #1005: welche Frames eines Sprechers durch eine Einwilligung **gedeckt**
  sind — als PURE Funktion, ohne GenServer und ohne Discord-Verbindung.

  ## Warum Intervalle und nicht eine Grenze

  Der erste Entwurf hatte einen einzelnen Zeitstempel („ab `since_ms` ist alles
  erlaubt"). Mit Widerruf ist die gedeckte Menge aber ein **Intervall**
  `[grant, revoke)`, und bei Grant→Revoke→Re-Grant innerhalb einer Session eine
  **Intervall-Menge**. Ein einzelnes `since_ms` würde beim Re-Grant das erste
  Intervall verlieren (oder, wenn man nur das letzte Verdikt hält, die Lücke
  überhaupt nicht kennen). Deshalb rechnet dieses Modul auf der **Historie** der
  Übergänge.

  ## Die Invariante

  > Kein Frame, der außerhalb eines Grant-Intervalls liegt, darf gespeichert
  > werden.

  Das ist die technische Fassung der Kernentscheidung: **die Einwilligung wirkt
  nur nach vorn.** Wer erst in Minute 12 zustimmt, dessen Audio aus Minute 0–12
  wird verworfen und nicht nachträglich freigegeben.

  Trifft ein Widerruf ein, während Frames noch ungeflusht im Puffer liegen
  (Grant bei 0, Widerruf bei 12 min, Flush bei 15 min), bleibt der **gedeckte**
  Teil erhalten (0–12) und nur 12–15 fällt weg — das ist die Intervall-Semantik.
  Die Alternative („ein Widerruf verwirft alles Ungeflushte") wäre konservativer,
  würde aber Material vernichten, für das eine gültige Einwilligung vorlag; sie
  ist bewusst nicht gewählt.

  ## Eine Uhr, nicht zwei

  Alle Zeitstempel hier — Frame-`arrival_ms` **und** die Übergänge — sind
  session-relative Millisekunden **derselben lokalen monotonen Uhr**
  (`System.monotonic_time(:millisecond) - session_start_ms`). Ein Klick wird
  bewusst NICHT mit dem Discord-Zeitstempel der Interaction eingetragen: ein
  Vergleich über Uhrengrenzen wäre bei Skew genau an der Kante falsch, auf die
  es ankommt.

  Grenzsemantik: Grant-Beginn ist **inklusiv** (`>=`), Widerruf **exklusiv**
  (`<`) — ein Frame genau auf dem Grant zählt als gedeckt, einer genau auf dem
  Widerruf nicht.
  """

  @typedoc "Ein Übergang: Verdikt + session-relative Zeit in ms."
  @type transition :: {:granted | :revoked, non_neg_integer()}

  @typedoc """
  Historie eines Sprechers, chronologisch. `pre_granted?` sagt, ob **vor** dem
  ersten Übergang schon eine gültige (persistierte) Einwilligung bestand — dann
  beginnt das erste Intervall bei 0.
  """
  @type history :: %{pre_granted?: boolean(), transitions: [transition()]}

  @doc "Leere Historie eines Sprechers ohne vorbestehende Einwilligung."
  @spec new(boolean()) :: history()
  def new(pre_granted? \\ false), do: %{pre_granted?: pre_granted?, transitions: []}

  @doc """
  Übergang anhängen. Zeitlich unsortierte Einträge werden einsortiert (ein
  verspätet zugestellter Klick darf die Reihenfolge nicht verdrehen).

  Nur **exakte** Duplikate (gleiches Verdikt zur gleichen Zeit) werden verworfen.
  Redundanz wird bewusst NICHT hier gefiltert, sondern erst in
  `granted_intervals/1`: dort ist die Reihenfolge vollständig bekannt.

  Der Grund ist ein echter Fehlerfall, den ein Test aufgedeckt hat: filtert man
  „gleiches Verdikt wie der Vorgänger" schon beim Einfügen, verschwindet ein
  legitimer Re-Grant, solange der dazwischenliegende Widerruf noch nicht
  zugestellt ist (`grant@100, grant@400, revoke@200` ⇒ der Grant bei 400 wäre
  weg und die Frames danach fälschlich verworfen).
  """
  @spec put(history(), :granted | :revoked, non_neg_integer()) :: history()
  def put(%{transitions: ts} = history, verdict, at_ms)
      when verdict in [:granted, :revoked] and is_integer(at_ms) and at_ms >= 0 do
    %{history | transitions: insert_sorted(ts, {verdict, at_ms})}
  end

  def put(history, _verdict, _at_ms), do: history

  @doc """
  Die gedeckten Zeit-Intervalle als Liste von `{from_ms, to_ms | :infinity}`.
  PURE, und die eigentliche Stelle, an der die Invariante entsteht.
  """
  @spec granted_intervals(history()) :: [{non_neg_integer(), non_neg_integer() | :infinity}]
  def granted_intervals(%{pre_granted?: pre_granted?, transitions: transitions}) do
    initial = if pre_granted?, do: [{0, :infinity}], else: []

    transitions
    |> Enum.reduce(initial, fn
      # Ein Grant öffnet ein Intervall — es sei denn, eines ist schon offen.
      {:granted, at}, acc ->
        if open?(acc), do: acc, else: [{at, :infinity} | acc]

      # Ein Widerruf schließt das offene Intervall. Ohne offenes Intervall ist er
      # ein No-op (nichts war gedeckt).
      {:revoked, at}, [{from, :infinity} | rest] ->
        [{from, at} | rest]

      {:revoked, _at}, acc ->
        acc
    end)
    |> Enum.reverse()
  end

  @doc """
  Die Frames eines Sprechers, die gespeichert werden dürfen.

  `frames` sind Maps mit `arrival_ms` (session-relativ, dieselbe Uhr wie die
  Übergänge). Alles außerhalb der Grant-Intervalle fällt weg.
  """
  @spec keepable_frames([map()], history()) :: [map()]
  def keepable_frames(frames, history) when is_list(frames) do
    case granted_intervals(history) do
      [] ->
        []

      intervals ->
        Enum.filter(frames, fn frame ->
          at = Map.get(frame, :arrival_ms)
          is_integer(at) and covered?(intervals, at)
        end)
    end
  end

  def keepable_frames(_frames, _history), do: []

  @doc "Liegt dieser Zeitpunkt in einem gedeckten Intervall?"
  @spec covered?([{non_neg_integer(), non_neg_integer() | :infinity}], integer()) :: boolean()
  def covered?(intervals, at_ms) do
    Enum.any?(intervals, fn
      {from, :infinity} -> at_ms >= from
      {from, to} -> at_ms >= from and at_ms < to
    end)
  end

  @doc "Gilt zum Zeitpunkt `at_ms` eine Einwilligung? (für Anzeige/Ansage-Logik)"
  @spec granted_at?(history(), integer()) :: boolean()
  def granted_at?(history, at_ms), do: covered?(granted_intervals(history), at_ms)

  # ─── intern ──────────────────────────────────────────────────────

  defp open?([{_from, :infinity} | _]), do: true
  defp open?(_), do: false

  # Chronologisch einsortieren; bei gleichem Zeitstempel hinten anfügen. Nur
  # exakte Duplikate (Verdikt UND Zeit gleich) werden verworfen — Redundanz
  # löst `granted_intervals/1` auf, wo die volle Reihenfolge bekannt ist.
  defp insert_sorted(transitions, entry) do
    if entry in transitions do
      transitions
    else
      {at_or_before, after_} =
        Enum.split_while(transitions, fn {_v, t} -> t <= elem(entry, 1) end)

      at_or_before ++ [entry] ++ after_
    end
  end
end
