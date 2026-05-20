defmodule HubWeb.Permissions do
  @moduledoc """
  Zentrales Permission-Modul (Issue #34, Userverwaltung).

  Eine einzige Wahrheits-Quelle für „darf User X die Action Y (im Kontext
  Z) ausführen?". Ersetzt die historisch verstreuten `owner?` /
  `is_member?`-Checks in den LVs.

  ## Rollen-Modell

  Jeder User hat eine **globale Rolle** (`worker_users.role`, Issue #34):

  - `:admin` — darf alles. Auf jeder Instance gibt es typischerweise
    einen (der zuerst-gepairte User).
  - `:spielleiter` — darf eigene Kampagnen anlegen + alles in seinen
    Kampagnen. Sonst keine Spezial-Rechte.
  - `:spieler` (Default) — darf nur „Mikro beitreten", eigene Protokoll-
    Zeilen ändern/löschen, und den eigenen Charakter-Alias setzen.

  Zusätzlich gibt es **per-Campaign-Membership** (`campaign_members`-
  Tabelle): `owner` (= Gründer der Kampagne) oder `player`. Per-Campaign-
  Owner ≠ globale Rolle :spielleiter — ein Spieler-Globale-Rolle-User
  kann nicht Owner werden weil er keine Kampagne anlegen darf.

  ## Rules-Table

  | Action                          | :admin | :spielleiter        | :spieler                        |
  |---------------------------------|--------|---------------------|---------------------------------|
  | `:create_campaign`              | ✓      | ✓                   | ✗                               |
  | `:view_admin`                   | ✓      | ✗                   | ✗                               |
  | `:delete_campaign(c)`           | ✓      | wenn `c.owner==self`| ✗                               |
  | `:edit_summary(c)`              | ✓      | wenn `c.owner==self`| ✗                               |
  | `:edit_epos(c)`                 | ✓      | wenn `c.owner==self`| ✗                               |
  | `:edit_chronik(c)`              | ✓      | wenn `c.owner==self`| ✗                               |
  | `:edit_flavor(c)`               | ✓      | wenn `c.owner==self`| ✗                               |
  | `:add_utterance(c)`             | ✓      | wenn `c.owner==self`| ✗                               |
  | `:join_mic(c)`                  | ✓      | wenn member          | wenn member                     |
  | `:set_own_alias(c)`             | ✓      | wenn member          | wenn member                     |
  | `:edit_utterance(u,c)`          | ✓      | wenn `c.owner==self`| wenn `u.discord_id==self`        |
  | `:delete_utterance(u,c)`        | ✓      | wenn `c.owner==self`| wenn `u.discord_id==self`        |

  Membership wird zur Laufzeit nicht hier geprüft (kein DB-Zugriff im
  Modul — bleibt rein funktional). Der Caller muss `:is_member?` im
  socket vor-resolved haben und reichts unter `user.is_member?` mit rein,
  wenn relevant.
  """

  @type role :: :admin | :spielleiter | :spieler

  @type user :: %{
          required(:discord_id) => String.t(),
          required(:role) => role(),
          optional(:is_member?) => boolean()
        }

  @type campaign :: %{
          required(:owner_discord_id) => String.t(),
          optional(any) => any
        }

  @type utterance :: %{
          required(:discord_id) => String.t(),
          optional(any) => any
        }

  # ─── 0-arg actions ──────────────────────────────────────────────

  @spec can?(user(), atom()) :: boolean()
  def can?(%{role: :admin}, _), do: true
  def can?(%{role: :spielleiter}, :create_campaign), do: true
  def can?(_, :create_campaign), do: false
  def can?(%{role: :admin}, :view_admin), do: true
  def can?(_, :view_admin), do: false

  # ─── 1-context (campaign) actions ────────────────────────────────

  @spec can?(user(), atom(), campaign()) :: boolean()
  def can?(%{role: :admin}, _action, _campaign), do: true

  def can?(user, action, campaign)
      when action in [
             :delete_campaign,
             :edit_summary,
             :edit_epos,
             :edit_chronik,
             :edit_flavor,
             :add_utterance
           ] do
    user.role == :spielleiter and user.discord_id == campaign.owner_discord_id
  end

  def can?(user, action, _campaign)
      when action in [:join_mic, :set_own_alias] do
    Map.get(user, :is_member?, false)
  end

  def can?(_user, _action, _campaign), do: false

  # ─── 2-context (utterance + campaign) actions ───────────────────

  @spec can?(user(), atom(), utterance(), campaign()) :: boolean()
  def can?(%{role: :admin}, _action, _utterance, _campaign), do: true

  def can?(user, action, utterance, campaign)
      when action in [:edit_utterance, :delete_utterance] do
    cond do
      user.role == :spielleiter and user.discord_id == campaign.owner_discord_id -> true
      Map.get(user, :is_member?, false) and user.discord_id == utterance.discord_id -> true
      true -> false
    end
  end

  def can?(_user, _action, _utterance, _campaign), do: false
end
