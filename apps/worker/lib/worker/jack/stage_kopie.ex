defmodule Worker.Jack.StageKopie do
  @moduledoc """
  Eine Prod-Sitzung als Ereignisse für eine Teststage (J5, #1209, B5): die
  Kampagne, ihre Spieler mit den Aliasen, die Vorgaben und Töne aus „Stil
  setzen“, die Sitzung und ihre Roh-Utterances — sonst nichts. Keine
  Glättung, keine Fakten, kein Resümee: die Pipeline der Stage baut alles
  selbst auf (Maintainer, 13.09.2026: „das sehen wir wie der lauf alles
  aufbaut“).

  Pur: `ereignisse/1` bekommt, was `mix lore.jack.stage_kopie` lesend aus
  `worker_prod` holt, und liefert die Payloads in Veröffentlichungsreihenfolge.
  Veröffentlicht werden sie auf dem Worker der Stage (`Worker.Intents`).

  **Die IDs bleiben die aus Prod** (Kampagne, Sitzung, Utterances). Die
  Stage ist nicht mit Prod verbunden, und nur mit denselben Utterance-IDs
  entstehen dieselben inhaltsadressierten Block-IDs wie dort.

  **Kein Handle auf der Stage:** jeder Spieler bekommt seinen Alias als
  Anzeigenamen (`UserUpserted`, `AdminMemberAdded`, `owner_display_name`).
  Ein Mitglied ohne Alias ist deshalb ein Fehler, ebenso ein Sprecher, der
  kein Mitglied ist — beides würde auf der Stage als Discord-ID oder Handle
  erscheinen und bei Jack als „Sprecher ohne Namen“.

  **Kein Pipeline-Auslöser:** es gibt kein `UtterancesTranscribed`. Die
  Pipeline startet erst, wenn jemand sie startet — nach dem Setzen der
  Einstellungen (etwa `gapfill_model`) auf der Stage.
  """

  alias Shared.Events

  @doc """
  Die Payloads für eine Sitzung, in Veröffentlichungsreihenfolge:
  `CampaignCreated` (der Spielleiter als Ersteller), je Spieler
  `UserUpserted` und — außer für den Spielleiter — `AdminMemberAdded`, je
  Spieler `CampaignAliasSet`, die Vorgaben (`CampaignVorgabeSet`) und Töne
  (`CampaignFlavorSet`), dann `SessionScheduled`, `SessionStarted`, alle
  `UtteranceAppended` und `SessionEnded`.

  `roh`: `%{kampagne:, mitglieder:, sitzung:, utterances:}` in der Form von
  `Worker.Repo.get_campaign/1`, `list_members/1`, `get_session/1` und
  `list_utterances(sid, limit: :all)`.

  Fehler: `{:kein_spielleiter}`, `{:mehrere_spielleiter, n}`,
  `{:mitglieder_ohne_alias, ids}`, `{:sprecher_ohne_mitgliedschaft, ids}`,
  `:keine_utterances`.
  """
  @spec ereignisse(map()) :: {:ok, [map()]} | {:error, term()}
  def ereignisse(%{kampagne: c, mitglieder: ms, sitzung: s, utterances: us}) do
    with :ok <- utterances_da(us),
         :ok <- aliase_da(ms),
         :ok <- sprecher_sind_mitglieder(us, ms),
         {:ok, sl} <- spielleiter(ms) do
      {:ok,
       [kampagne(c, sl)] ++
         mitglieder(c, ms, sl) ++
         Enum.map(ms, &alias_setzen(c, &1)) ++
         vorgaben(c, sl) ++
         toene(c, sl) ++
         sitzung(c, s) ++
         Enum.map(us, &utterance(s, &1)) ++
         [%{"kind" => Events.session_ended(), "id" => s.id}]}
    end
  end

  defp utterances_da([]), do: {:error, :keine_utterances}
  defp utterances_da(_us), do: :ok

  defp aliase_da(ms) do
    case for(m <- ms, leer?(m.character_name), do: m.discord_id) do
      [] -> :ok
      ids -> {:error, {:mitglieder_ohne_alias, ids}}
    end
  end

  defp sprecher_sind_mitglieder(us, ms) do
    bekannt = MapSet.new(ms, & &1.discord_id)

    case us |> Enum.map(& &1.discord_id) |> Enum.uniq() |> Enum.reject(&(&1 in bekannt)) do
      [] -> :ok
      ids -> {:error, {:sprecher_ohne_mitgliedschaft, ids}}
    end
  end

  defp spielleiter(ms) do
    case Enum.filter(ms, &(&1.role == :spielleiter)) do
      [sl] -> {:ok, sl}
      [] -> {:error, {:kein_spielleiter}}
      viele -> {:error, {:mehrere_spielleiter, length(viele)}}
    end
  end

  defp kampagne(c, sl) do
    %{
      "kind" => Events.campaign_created(),
      "id" => c.id,
      "name" => c.name,
      "icon_url" => c[:icon_url],
      "theme_blurb" => c[:theme_blurb],
      "owner_discord_id" => sl.discord_id,
      "owner_display_name" => sl.character_name
    }
  end

  # Der Spielleiter wird über `CampaignCreated` Mitglied; `AdminMemberAdded`
  # setzte ihn auf `:spieler` zurück (Rejoin = Reset, #896).
  defp mitglieder(c, ms, sl) do
    Enum.flat_map(ms, fn m ->
      user = %{
        "kind" => Events.user_upserted(),
        "discord_id" => m.discord_id,
        "display_name" => m.character_name
      }

      if m.discord_id == sl.discord_id,
        do: [user],
        else: [
          user,
          %{
            "kind" => Events.admin_member_added(),
            "campaign_id" => c.id,
            "discord_id" => m.discord_id,
            "display_name" => m.character_name,
            "added_by" => sl.discord_id
          }
        ]
    end)
  end

  defp alias_setzen(c, m) do
    %{
      "kind" => Events.campaign_alias_set(),
      "campaign_id" => c.id,
      "discord_id" => m.discord_id,
      "character_name" => m.character_name
    }
  end

  defp vorgaben(c, sl) do
    for {stage, v} <- Enum.sort(c[:vorgaben] || %{}) do
      %{
        "kind" => Events.campaign_vorgabe_set(),
        "campaign_id" => c.id,
        "stage" => stage,
        "name" => feld(v, :name),
        "darstellungsform" => feld(v, :darstellungsform),
        "set_by" => sl.discord_id
      }
    end
  end

  defp toene(c, sl) do
    for {slot, text} <- Enum.sort(c[:flavors] || %{}), is_binary(text), not leer?(text) do
      %{
        "kind" => Events.campaign_flavor_set(),
        "campaign_id" => c.id,
        "slot" => slot,
        "flavor" => text,
        "edited_by" => sl.discord_id
      }
    end
  end

  defp sitzung(c, s) do
    [
      %{
        "kind" => Events.session_scheduled(),
        "id" => s.id,
        "campaign_id" => c.id,
        "number" => s.number,
        "name" => s.name,
        "scheduled_for" => iso(s[:scheduled_for] || s[:started_at])
      },
      %{"kind" => Events.session_started(), "id" => s.id}
    ]
  end

  defp utterance(s, u) do
    %{
      "kind" => Events.utterance_appended(),
      "id" => u.id,
      "session_id" => s.id,
      "discord_id" => u.discord_id,
      "timestamp" => iso(u.timestamp),
      "text" => u.text,
      "confidence" => jsonfaehig(u[:confidence]),
      "status" => to_string(u[:status] || :confirmed)
    }
  end

  # Die Konfidenz liegt je nach Alter als Map mit String- oder Atom-Schlüsseln
  # vor; über die Leitung geht sie als JSON.
  defp jsonfaehig(nil), do: nil
  defp jsonfaehig(x), do: x |> Jason.encode!() |> Jason.decode!()

  defp iso(%DateTime{} = t), do: DateTime.to_iso8601(t)
  defp iso(t) when is_binary(t), do: t
  defp iso(_), do: nil

  defp feld(m, k) when is_map(m), do: Map.get(m, k) || Map.get(m, Atom.to_string(k))
  defp feld(_m, _k), do: nil

  defp leer?(t), do: not is_binary(t) or String.trim(t) == ""
end
