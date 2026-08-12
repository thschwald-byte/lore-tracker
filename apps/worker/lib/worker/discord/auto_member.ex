defmodule Worker.Discord.AutoMember do
  @moduledoc """
  Issue #988: wer im Discord-Voice-Kanal einwilligt und noch **kein Mitglied**
  der Kampagne ist, wird als `:spieler` aufgenommen.

  Begründung (Produktentscheidung): wer im Voice-Channel sitzt, wurde ohnehin auf
  den Discord-Server eingeladen — die Hürde ist also schon genommen. Will der GM
  die Person nicht dabeihaben, entfernt er sie nachträglich aus der Kampagne
  (`MemberRemoved`). Das ist die leichtgewichtigere Richtung als ein
  Bestätigungs-Schritt, der jeden Spielabend blockieren würde.

  Damit entfällt im UI ein eigener „Gast"-Zustand: nach der Einwilligung ist
  jeder Sprecher ein Mitglied, und es bleiben genau die zwei Icon-Zustände
  „Einwilligung erteilt" (farbig) und „keine Einwilligung" (grau + durchgestrichen).

  ## Zwei Events, beide feldkonservativ

  - `UserUpserted` trägt **Name + Avatar** ein (von der Discord-API geholt — die
    Person war womöglich nie im Hub eingeloggt, es gibt also keinen anderen Weg
    an diese Daten).
  - `AdminMemberAdded` legt über `member_join_apply/5` die **Member-Row** an
    (Rolle `:spieler`) und die users-Row, falls sie noch fehlt.

  Beide Folds bewahren `avatar_url`/`joined_at` (#879-Klasse), die Reihenfolge
  ist deshalb egal — kein Clobber-Risiko in beide Richtungen.

  ## `added_by`

  Das Feld ist im ganzen Projekt **write-only** (reine Audit-Spur im Event-Log,
  nirgends gelesen). Eingetragen wird der Spielleiter der Kampagne — eine
  gültige, auflösbare Discord-ID statt eines Marker-Strings, der einem künftigen
  Leser auf die Füße fiele. Die *tatsächliche* Herkunft steht ohnehin im
  zeitgleichen `AudioConsentRecorded`-Event derselben `discord_id`.
  """

  require Logger

  @doc """
  Nimmt `discord_id` in die Kampagne auf, falls noch nicht Mitglied.

  Idempotent: ein bereits eingetragenes Mitglied (egal welcher Rolle) wird nicht
  angefasst — insbesondere wird ein Spielleiter **nicht** auf `:spieler`
  zurückgestuft. Best-effort: ein Fehler hier darf die laufende Aufnahme nie
  stören (die Einwilligung selbst ist längst persistiert).
  """
  @spec ensure(String.t(), String.t() | non_neg_integer()) :: :ok
  def ensure(campaign_id, discord_id) do
    did = to_string(discord_id)

    if member?(campaign_id, did) do
      :ok
    else
      add_member(campaign_id, did)
    end
  rescue
    e ->
      Logger.warning(
        "Worker.Discord.AutoMember: Aufnahme fehlgeschlagen campaign=#{campaign_id} " <>
          "did=#{discord_id}: #{Exception.message(e)}"
      )

      :ok
  catch
    kind, reason ->
      Logger.warning(
        "Worker.Discord.AutoMember: Aufnahme fehlgeschlagen campaign=#{campaign_id} " <>
          "did=#{discord_id}: #{inspect({kind, reason})}"
      )

      :ok
  end

  defp member?(campaign_id, did), do: Worker.Repo.campaign_role(campaign_id, did) != nil

  defp add_member(campaign_id, did) do
    {display_name, avatar_url} = profile(did)

    Logger.info(
      "Worker.Discord.AutoMember: #{display_name} (#{did}) wird durch Einwilligung " <>
        ":spieler in campaign=#{campaign_id}"
    )

    # `{:ok, _} =` statt Return ignorieren (Credo `ignored_intents_publish`):
    # `Intents.publish/1` liefert seit #430 immer `{:ok, …}`; ein anderer Wert
    # wäre ein echter Bruch und soll hier laut scheitern — der `rescue` in
    # `ensure/2` fängt das ab, die Aufnahme läuft weiter.
    {:ok, _} =
      Worker.Intents.publish(%{
        "kind" => Shared.Events.user_upserted(),
        "discord_id" => did,
        "display_name" => display_name,
        "avatar_url" => avatar_url
      })

    {:ok, _} =
      Worker.Intents.publish(%{
        "kind" => Shared.Events.admin_member_added(),
        "campaign_id" => campaign_id,
        "discord_id" => did,
        "display_name" => display_name,
        "added_by" => added_by(campaign_id)
      })

    :ok
  end

  # Name + Avatar von der Discord-API. Wer nie im Hub eingeloggt war, hat weder
  # das eine noch das andere bei uns — das ist der einzige Weg an die Daten.
  # Scheitert der Call (Rate-Limit, Netz), bleibt die Discord-ID als Anzeigename:
  # ein Mitglied ohne schönen Namen ist besser als gar keine Aufnahme in die
  # Kampagne (der Name korrigiert sich beim ersten Hub-Login von selbst).
  defp profile(did) do
    with {id, ""} <- Integer.parse(did),
         {:ok, user} <- fetch_user(id) do
      # Kein `|| did`-Fallback: Nostrum typisiert `username` als `binary()`
      # (Dialyzer flaggt den Zweig zu Recht als unerreichbar). Wäre er wider
      # Erwarten doch nil, defaulten BEIDE Folds ohnehin auf die Discord-ID
      # (`display_name || discord_id`) — die Absicherung sitzt also flussabwärts.
      {user.username, safe_avatar_url(user)}
    else
      _ -> {did, nil}
    end
  end

  # `Nostrum.Api.User.get/1` WIRFT, wenn kein Bot-Prozess erreichbar ist — es
  # liefert kein `{:error, _}`. Ohne dieses rescue landete die Exception im
  # äußeren Handler von `ensure/2` und hätte die Aufnahme in die Kampagne
  # komplett verschluckt (von einem Test gefunden, nicht theoretisch): der
  # Fehlerpfad hätte still das Gegenteil dessen getan, was das Moduledoc
  # verspricht.
  defp fetch_user(id) do
    Nostrum.Api.User.get(id)
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp safe_avatar_url(user) do
    Nostrum.Struct.User.avatar_url(user, "png")
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # Der Spielleiter der Kampagne (abgeleitet, s. #140) — fällt auf den
  # Beitretenden selbst zurück, wenn keiner ermittelbar ist.
  defp added_by(campaign_id) do
    case Worker.Repo.get_campaign(campaign_id) do
      %{owner_discord_id: owner} when is_binary(owner) and owner != "" -> owner
      _ -> "discord_voice_consent"
    end
  end
end
