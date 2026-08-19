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

  @doc """
  Issue #1069 (E7): dieselbe Frage, aber mit dem Session-Zeitrahmen als
  zweiter Quelle. Trägt der Rahmen (`rahmen_belegt?/1`), zählt JEDER Fakt der
  Session als datierbar — er sitzt dann nicht mehr „nur wegen Präsens" am
  Anker-Tag, sondern weil für diese Session belegt ist, wann sie spielt.

  **Das hebt den #958-Vorfilter für belegte Sessions bewusst auf.** Gemessen an
  Free Seattle S1: 16 → 175 Chronik-Einträge. Die Chronik wird damit für solche
  Sessions eine nach Tagen gruppierte Vollansicht statt einer Auswahl. Das ist
  eine Produktentscheidung (2026-08-19), keine Nebenwirkung — wer sie
  zurücknimmt, ändert hier die eine Zeile und nicht den Vorlauf.

  Für Sessions OHNE belegten Rahmen bleibt #958 unverändert in Kraft. Das ist
  der Grund, warum `rahmen_belegt?/1` streng ist: es entscheidet, ob eine
  Session in die Vollansicht kippt.
  """
  def time_signal?(fact, rahmen) when is_map(fact) do
    time_signal?(fact) or rahmen_belegt?(rahmen)
  end

  @doc """
  Trägt dieser Session-Zeitrahmen genug, um die Session zu datieren?

  Streng, weil daran die Chronik-Menge hängt (s. `time_signal?/2`). Es zählt
  nur, was ein Mensch als Beleg akzeptieren würde:

  - **mindestens ein harter DATUMS-Anker** — nach D8/D9/D11 heisst „hart"
    bereits *nicht ASR-degradiert*. Eine Session, deren sämtliche
    Zeitfundstellen auf wackeligem ASR sitzen (der Block-37-Fall: „um 20.10
    Uhr" für 2010), öffnet die Chronik nicht. Ein Jahres-Anker zählt hier
    NICHT mit, auch wenn er hart ist — gemessen an S1 sind alle drei harten
    Anker Jahreszahlen, und keine davon positioniert einen Tag.
  - **oder eine bestätigte Tageszeit** — die entsteht im Vorlauf nur aus
    mindestens zwei übereinstimmenden Fundstellen im selben Fenster (D2), ein
    einzelnes „Guten Abend" begründet sie nicht.

  Ausdrücklich NICHT ausreichend: `jahr_kandidaten`. Ein Jahr verengt, aber es
  datiert keinen Tag — und gemessen gehört jeder dritte gefundene Jahres-Anker
  zur erzählten Weltgeschichte statt zur Handlungszeit.
  """
  def rahmen_belegt?(rahmen) when is_map(rahmen) do
    # `harte_datums_anker`, NICHT `harte_anker`: ein Jahr ist hart, positioniert
    # aber keinen Tag (s. `Vorlauf.rahmen/1`). Fehlt das Feld — alter
    # persistierter Rahmen —, zählt es als 0; die Tageszeit muss dann tragen.
    harte = rahmen["harte_datums_anker"] || rahmen[:harte_datums_anker] || 0
    tageszeit = rahmen["tageszeit"] || rahmen[:tageszeit]

    (is_integer(harte) and harte > 0) or gesetzt?(tageszeit)
  end

  def rahmen_belegt?(_), do: false

  # Die Tageszeit reist als Atom (`:abend`, frisch aus dem Vorlauf) oder als
  # String (`"abend"`, aus dem persistierten Rahmen). Beide Wege führen hier
  # vorbei; `blank_to_nil/1` verwirft Atome still zu nil und hätte den
  # Vorlauf-Pfad lautlos immer als unbelegt gewertet.
  defp gesetzt?(nil), do: false
  defp gesetzt?(v) when is_atom(v), do: true
  defp gesetzt?(v) when is_binary(v), do: String.trim(v) != ""
  defp gesetzt?(_), do: false

  @doc """
  Issue #911/#958: hat dieser Fakt ein EIGENES Zeit-Signal — mehr als den
  reinen Präsens-Fallback (`Resolver.resolve_one/4`s cond-Klausel: kein
  Anker, kein Offset, sitzt nur deshalb am Session-Anker-Tag, weil
  `narration_time == "present"` ist)? PURE, operiert auf den rohen
  Fakt-Feldern VOR jeder Resolver-Auflösung — der Vorfilter für die Chronik
  (nur echt datierte Fakten, kein Session-Anker-Massenpinning).

  Muss mit `Resolver.resolve_one/4`s Branches synchron bleiben (dedizierte
  Spiegel-Tests in `graph_test.exs` pinnen das): ein struktuell vorhandenes,
  aber kaputtes `time_offset` zählt hier bewusst als "ja" (der Resolver
  verwirft es später ohnehin zu `unknown`, `Render.timeline`s `dated?/1`
  filtert den Fakt dann nachgelagert — funktional folgenlos, kein
  Sonderfall nötig).
  """
  @spec time_signal?(map()) :: boolean()
  def time_signal?(fact) when is_map(fact) do
    anchor = fact["time_anchor"]
    absolute = blank_to_nil(fact["time_absolute"]) || blank_to_nil(fact["in_game_date"])

    anchor in ["absolute", "session"] or
      (is_binary(anchor) and String.starts_with?(anchor, "event:")) or
      fact["time_offset"] != nil or
      not is_nil(absolute)
  end

  @doc """
  Issue #1068 (E3): trägt der Zeitausdruck dieses Fakts überhaupt eine
  **Position**? Ergänzt `time_signal?/1` um die Typ-Frage, die dort nicht
  gestellt werden kann, weil sie einen Kalender braucht.

  `time_signal?/1` prüft „steht da irgendetwas Zeitliches" — und das trifft auf
  „sechs Jahre lang" genauso zu wie auf „24. Dezember 2011". Erst der Typ
  entscheidet, ob es auf einen Zeitstrahl gehört: eine Dauer, eine Uhrzeit und
  ein wiederkehrender Ausdruck haben keine Position, egal wie eindeutig sie
  formuliert sind.

  **Nur der Roh-Ausdruck wird geprüft, nicht `time_anchor`/`time_offset`.** Ein
  Fakt mit Anker oder Offset trägt seine Position anderswoher und passiert hier
  ungeprüft — die Frage gilt allein dem Datums-String.

  **Was der Parser NICHT versteht, bleibt drin.** Das ist der wichtigere Teil:
  seit #724 gilt, dass ein unauflösbarer Datums-String („Tag 5", ein
  Fantasy-Datum ohne passenden Kalender) seinen Chronik-Eintrag bekommt — mit
  `in_game_day: nil` und bewahrtem Roh-String, sortiert über die #650-Familie.
  Kein Datenverlust, nur keine globale Chronologie.

  Aussortiert wird deshalb ausschliesslich, was der Parser **erkannt und als
  positionslos eingestuft** hat. „Ich verstehe es nicht" und „ich verstehe es,
  und es ist keine Position" sind verschiedene Aussagen — sie hier
  zusammenzuwerfen hiesse, bestehende Einträge stillschweigend verschwinden zu
  lassen.
  """
  @spec datierbar?(map(), Calendar.t()) :: boolean()
  def datierbar?(fact, %Calendar{} = cal) when is_map(fact) do
    ausdruck = blank_to_nil(fact["time_absolute"]) || blank_to_nil(fact["in_game_date"])

    cond do
      # Anker oder Offset tragen die Position — der Datums-String ist dann
      # nicht die Quelle und muss nicht datierbar sein.
      fact["time_anchor"] not in [nil, "", "unknown"] -> true
      fact["time_offset"] != nil -> true
      is_nil(ausdruck) -> false
      true -> not positionslos?(cal, ausdruck)
    end
  end

  def datierbar?(_, _), do: false

  # Nur ein ERKANNTER Nicht-Datums-Typ schliesst aus. `:error` (nichts
  # erkannt) lässt den Fakt durch — s. Moduldoc oben.
  defp positionslos?(cal, ausdruck) do
    case Worker.Timeline.Parser.parse(cal, ausdruck) do
      {:ok, %{typ: typ}} when typ in [:duration, :time, :set, :vage] -> true
      _ -> false
    end
  end

  defp blank_to_nil(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: s)
  defp blank_to_nil(_), do: nil

  @spec resolve([map()], Calendar.t(), integer() | nil, Calendar.precision() | nil) :: [map()]
  def resolve(facts, %Calendar{} = cal, session_anchor_day, anchor_precision \\ nil)
      when is_list(facts) do
    # Stabile Arbeits-IDs (falls ein Fakt kein "id"-Feld hat).
    indexed = Enum.with_index(facts, fn f, i -> {f, fact_id(f, i)} end)
    normalized = Enum.map(indexed, fn {f, id} -> {normalize_event_anchor(f, id, indexed), id} end)

    done =
      resolve_loop(
        normalized,
        cal,
        {session_anchor_day, anchor_precision},
        %{},
        length(normalized) + 1
      )

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

  defp resolve_loop(pending, cal, {anchor_day, anchor_precision} = anchor, done, fuel) do
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
            Map.put(
              acc,
              id,
              Resolver.resolve_one(f, cal, anchor_day, resolved_days, anchor_precision)
            )
          end)

        resolve_loop(waiting, cal, anchor, done2, fuel - 1)
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
