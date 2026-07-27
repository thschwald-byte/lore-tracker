defmodule Worker.Repo.Render do
  @moduledoc """
  Issue #914 (Cut 0): die Anzeige-Ableitung der Prosa-Artefakte (Resümee/
  Epos-Kapitel/Chronik-Eintrag) aus den zwei Slots — **Status als Ableitung,
  nicht als Schreibkonflikt** (Arc-Muster #903).

  Zwei getrennte Slots pro Artefakt:
  - **generiert-Slot** (`generated_md` + `generated_version_id`): der Regenerate
    schreibt hier unbedingt rein, jede Fassung mit einer `version_id`
    (event_id des erzeugenden Generated-Events).
  - **kuratiert-Slot** (`curated_md` + `curated_event_id`): manuelle Edits.
  - **Freigabe** (`released_version_id` + `release_event_id`): `RenderReleaseSet`
    referenziert GENAU eine `version_id` des generiert-Slots.

  Die angezeigte Fassung ist eine PURE Ableitung, event_id-geordnet (KEIN
  `updated_at` — order-insensitiv, #781-Muster):

  - Ist der jüngste Kurator-Akt eine Freigabe für GENAU die aktuell vorliegende
    `generated_version_id` → **generiert**, kein Prompt (der Kurator hat exakt
    diese Fassung akzeptiert).
  - Sonst, wenn ein kuratiert-Slot existiert → **kuratiert**; im Bearbeiten-Modus
    ein „Rebuild hat eine neue Fassung — übernehmen?"-Prompt, sofern die
    generierte Fassung existiert und abweicht.
  - Sonst → **generiert**, kein Prompt.

  Ein neuer Rebuild vergibt eine neue `version_id` → die Freigabe greift nicht
  mehr → der Prompt erscheint wieder. Einmal-Zustimmung ist damit strukturell
  die einzige darstellbare Form (nie „alle künftigen Rebuilds vorab
  akzeptiert"). Nichts wird vernichtet, nichts eingefroren, der Konflikt wird
  sichtbar statt entschieden. `:kuratiert` überlagert `:generiert`, nie
  destruktiv.
  """

  @typedoc """
  Die Slot-Rohdaten einer Prosa-Zeile. `*_event_id`/`*_version_id` sind
  UUIDv7-Strings (zeit-geordnet lexikografisch) oder `nil` (Slot leer).
  Bewusst offen (`optional(atom())`): die Aufrufer reichen die volle Row-Map
  durch (mit Zusatzfeldern wie campaign_id) — `displayed/1` liest nur die
  Slot-Keys via Access.
  """
  @type slots :: %{optional(atom()) => term()}

  @type displayed :: %{
          content_md: String.t() | nil,
          source: :generiert | :kuratiert,
          rebuild_available?: boolean()
        }

  @doc """
  Leitet die anzuzeigende Fassung + Herkunft + „neue Fassung verfügbar?"-Flag
  aus den Slots ab. PURE.

  `rebuild_available?` ist das Signal für den Bearbeiten-Modus-Prompt
  („übernehmen?") — true genau dann, wenn eine kuratierte Fassung angezeigt
  wird, aber eine abweichende, nicht-freigegebene generierte Fassung daneben
  liegt.
  """
  @spec displayed(slots()) :: displayed()
  def displayed(slots) when is_map(slots) do
    gen_md = slots[:generated_md]
    gen_ver = slots[:generated_version_id]
    cur_md = slots[:curated_md]
    cur_eid = slots[:curated_event_id]
    rel_ver = slots[:released_version_id]
    rel_eid = slots[:release_event_id]

    cond do
      release_matches_current?(rel_ver, rel_eid, gen_ver, cur_eid) ->
        %{content_md: gen_md, source: :generiert, rebuild_available?: false}

      is_binary(cur_md) ->
        %{
          content_md: cur_md,
          source: :kuratiert,
          rebuild_available?: is_binary(gen_md) and gen_md != cur_md
        }

      true ->
        %{content_md: gen_md, source: :generiert, rebuild_available?: false}
    end
  end

  # Die Freigabe zeigt die generierte Fassung gdw. (a) sie überhaupt existiert,
  # (b) sie GENAU die aktuell vorliegende generierte Fassung referenziert, und
  # (c) sie der jüngste Kurator-Akt ist (jünger als der letzte kuratierte Edit;
  # ein Edit NACH der Freigabe holt die manuelle Fassung zurück).
  defp release_matches_current?(rel_ver, rel_eid, gen_ver, cur_eid) do
    is_binary(rel_ver) and is_binary(rel_eid) and is_binary(gen_ver) and
      rel_ver == gen_ver and release_is_latest?(rel_eid, cur_eid)
  end

  # event_id-Vergleich (UUIDv7 lexikografisch = zeit-geordnet). Kein kuratierter
  # Edit (cur_eid nil) → die Freigabe ist trivial der jüngste Akt.
  defp release_is_latest?(rel_eid, nil), do: is_binary(rel_eid)
  defp release_is_latest?(rel_eid, cur_eid), do: rel_eid >= cur_eid
end
