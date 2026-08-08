defmodule Worker.Recording.Pipeline.PraesenzPing do
  @moduledoc """
  Issue #965 (Epic #911 Slice 2): ASR-Halluzinations-Filter für „Präsenz-
  Ping"-Phrasen ("(Ja,) ich bin da/hier") in der Glättung (Stage 1.1).

  Gemessen bei der Free-Seattle-Analyse (Epic #911): 47 Treffer in einer
  Session, 41 davon mitten im eigenen Satz der SL-Spur — ein Whisper-
  Stille-Artefakt, kein reales Sprecher-Ereignis. Reale Verifikation gegen
  die Prod-Kampagne „Free Seattle" (`seattle-bereinigt-1`) zeigt: die
  klaren Treffer unterbrechen denselben Sprecher MITTEN im eigenen Monolog
  ("...Kreditkarte und USB-Stick vorgestellt." → „Ja, ich bin da." → „Und
  die sind quasi auf deine ID getrimmt.") — keine Anwesenheitsfrage in der
  Nähe. Ein Grenzfall (Sprecherwechsel davor+danach, keine Monolog-
  Unterbrechung) bleibt bewusst unangetastet — konservativ, wie `Ooc`.

  **Erkennung**: zwei enge, WHOLE-UTTERANCE-verankerte Regexes (kein loses
  Substring-Matching — sonst würde z.B. „...vollständig noch da ist." als
  Treffer erscheinen, obwohl klar kein Ping). `@ping` matched nur, wenn der
  GESAMTE getrimmte Text der Form entspricht — das schließt echten Inhalt
  wie „Ja, ich bin da, ich lese gerade was..." bereits aus, unabhängig vom
  Guard.

  **Guard (kombiniert, beide Bedingungen für ein Strippen nötig)**:
  1. Keine Anwesenheitsfrage (`@question`, beliebiger Sprecher) innerhalb
     `@guard_window_seconds`.
  2. Monolog-Unterbrechung: die unmittelbar vorhergehende UND die
     unmittelbar nachfolgende Utterance in der vollen chronologischen Liste
     sind BEIDE vom selben Sprecher wie die Ping-Utterance. Fehlt ein
     Nachbar (erste/letzte Utterance) → konservativ NICHT strippen.

  **Ehrlich benannt**: `@question` ist NICHT gegen echte Positiv-Treffer
  kalibriert — in der gesichteten Session kam keine Anwesenheitsfrage vor.
  Best-Effort, Nachschärfen bei Bedarf über den bestehenden
  `rules_version`-Heilungsweg (Regenerate).

  `fingerprint/0` fließt in `Smoothing.rules_version/0` ein — die Regel
  bestimmt die Block-Komposition, exakt wie `Ooc.fingerprint/0` heute schon.
  """

  @ping ~r/^(ja,?\s*)?(ich bin (da|hier)[.,!]?\s*)+$/iu
  @question ~r/^(bist du|seid ihr)\s*(noch\s+)?(da|hier)\s*\??$/iu

  @guard_window_seconds 30

  @doc "True, wenn der Text (whole-utterance) ein Präsenz-Ping-Kandidat ist."
  @spec ping?(String.t() | nil) :: boolean()
  def ping?(text) when is_binary(text), do: Regex.match?(@ping, String.trim(text))
  def ping?(_), do: false

  @doc "True, wenn der Text (whole-utterance) eine Anwesenheitsfrage ist."
  @spec question?(String.t() | nil) :: boolean()
  def question?(text) when is_binary(text), do: Regex.match?(@question, String.trim(text))
  def question?(_), do: false

  # Issue #862-Muster (Ooc.fingerprint/0): Regel-Daten fließen in die
  # Glättungs-rules_version ein — eine Regex-Änderung invalidiert Block-IDs
  # ehrlich, statt Kurationen still auf verändertem Umgebungstext sitzen zu
  # lassen.
  @doc false
  @spec fingerprint() :: non_neg_integer()
  def fingerprint,
    do: :erlang.phash2({Regex.source(@ping), Regex.source(@question), @guard_window_seconds})

  @doc """
  Entfernt Präsenz-Ping-Halluzinationen aus der chronologischen Utterance-
  Liste (Reihenfolge bleibt erhalten). Gibt `{gefilterte_utterances,
  verworfene_ids}` zurück — Aufrufer reicht die gefilterte Liste an
  `merge_runs/2` weiter, die verworfenen IDs sind für den Audit-Trail
  (`praesenz_ping_verworfen`, analog `ooc_verworfen`).
  """
  @spec filter([map()]) :: {[map()], [String.t()]}
  def filter(utterances) when is_list(utterances) do
    indexed = Enum.with_index(utterances)
    question_ts = for {u, _i} <- indexed, question?(u_text(u)), do: u_ts(u)

    {kept_rev, discarded_rev} =
      Enum.reduce(indexed, {[], []}, fn {u, i}, {kept, discarded} ->
        if ping?(u_text(u)) and not nearby_question?(u, question_ts) and
             monologue_interruption?(u, i, indexed) do
          {kept, [u_id(u) | discarded]}
        else
          {[u | kept], discarded}
        end
      end)

    {Enum.reverse(kept_rev), Enum.reverse(discarded_rev)}
  end

  defp nearby_question?(u, question_ts) do
    ts = u_ts(u)

    is_struct(ts, DateTime) and
      Enum.any?(question_ts, fn qt ->
        is_struct(qt, DateTime) and abs(DateTime.diff(qt, ts, :second)) <= @guard_window_seconds
      end)
  end

  # i > 0 explizit geprüft, BEVOR i - 1 an Enum.at geht: negative Indizes
  # wickeln in Elixir von hinten (Enum.at(list, -1) = letztes Element) — ein
  # naiver i - 1-Aufruf bei i == 0 würde also fälschlich das LETZTE Element
  # der Liste als "vorherigen Nachbarn" behandeln.
  defp monologue_interruption?(_u, 0, _indexed), do: false

  defp monologue_interruption?(u, i, indexed) do
    case {Enum.at(indexed, i - 1), Enum.at(indexed, i + 1)} do
      {{prev, _}, {next, _}} ->
        spk = u_speaker(u)
        spk != nil and u_speaker(prev) == spk and u_speaker(next) == spk

      _ ->
        false
    end
  end

  # ── Utterance-Zugriff (Atom- ODER String-Keys, wie Smoothing) ────────────

  defp u_id(u), do: Map.get(u, :id) || Map.get(u, "id")
  defp u_text(u), do: Map.get(u, :text) || Map.get(u, "text") || ""
  defp u_speaker(u), do: Map.get(u, :discord_id) || Map.get(u, "discord_id")
  defp u_ts(u), do: Map.get(u, :timestamp) || Map.get(u, "timestamp")
end
