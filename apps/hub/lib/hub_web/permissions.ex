defmodule HubWeb.Permissions do
  @moduledoc """
  Zentrales Permission-Modul (Issue #34, Userverwaltung; Issue #140,
  per-Campaign-Rollen).

  Eine einzige Wahrheits-Quelle für „darf User X die Action Y (im Kontext
  Z) ausführen?". Ersetzt die historisch verstreuten `owner?` /
  `is_member?`-Checks in den LVs.

  ## Rollen-Modell

  **Globale Rolle** pro User (`worker_users.role`):

  - `:admin` — darf alles. Auf jeder Instance gibt es typischerweise
    einen (der zuerst-gepairte User).
  - `:spielleiter` — darf eigene Kampagnen anlegen. Per-Campaign-GM-Rechte
    hängen NICHT mehr automatisch hier dran — siehe per-Campaign-Rolle.
  - `:spieler` (Default) — darf nur „Mikro beitreten", eigene Protokoll-
    Zeilen ändern/löschen, und den eigenen Charakter-Alias setzen.

  **Per-Campaign-Rolle** pro Membership (`campaign_members.role`, Issue
  #140):

  - `:spielleiter` — GM dieser Campaign (Ersteller automatisch).
  - `:spieler` — Mitspieler (Default für eingeladene).

  Globale Rolle und per-Campaign-Rolle sind unabhängig: ein globaler
  `:spieler` kann in einer Campaign per-Campaign-`:spielleiter` sein
  (befördert vom GM via #140-Phase B). Globaler `:admin` darf weiterhin
  alles, unabhängig von Campaign-Membership.

  ## Rules-Table

  | Action                  | :admin | per-Campaign :spielleiter | per-Campaign :spieler             |
  |-------------------------|--------|---------------------------|-----------------------------------|
  | `:create_campaign`      | ✓      | globale Rolle :spielleiter | ✗                                |
  | `:view_admin`           | ✓      | ✗                         | ✗                                 |
  | `:delete_campaign(c)`   | ✓      | ✓                         | ✗                                 |
  | `:edit_summary(c)`      | ✓      | ✓                         | ✗                                 |
  | `:edit_epos(c)`         | ✓      | ✓                         | ✗                                 |
  | `:edit_chronik(c)`      | ✓      | ✓                         | ✗                                 |
  | `:edit_flavor(c)`       | ✓      | ✓                         | ✗                                 |
  | `:edit_vocab(c)`        | ✓      | ✓                         | ✗                                 |
  | `:add_utterance(c)`     | ✓      | ✓                         | ✗                                 |
  | `:invite_to_campaign(c)`| ✓      | ✓                         | ✗                                 |
  | `:regenerate_session(c)`| ✓      | ✓                         | ✗                                 |
  | `:regenerate_campaign(c)`| ✓     | ✓                         | ✗                                 |
  | `:promote_member(c)`    | ✓      | ✓                         | ✗                                 |
  | `:demote_member(c)`     | ✓      | ✓                         | ✗                                 |
  | `:join_mic(c)`          | ✓      | ✓                         | ✓                                 |
  | `:set_own_alias(c)`     | ✓      | ✓                         | ✓                                 |
  | `:edit_utterance(u,c)`  | ✓      | ✓                         | wenn `u.discord_id==self`          |
  | `:delete_utterance(u,c)`| ✓      | ✓                         | wenn `u.discord_id==self`          |

  Per-Campaign-Membership wird hier nicht aus der DB gelesen — der Caller
  muss `:campaign_role` im socket vor-resolved haben (typischerweise via
  `Worker.Repo.campaign_role/2`) und unter `user.campaign_role` mit rein-
  geben. Nicht-Member ⇒ `:campaign_role => nil`.
  """

  @type global_role :: :admin | :spielleiter | :spieler
  @type campaign_role :: :spielleiter | :spieler | nil

  @type user :: %{
          required(:discord_id) => String.t(),
          required(:role) => global_role(),
          optional(:campaign_role) => campaign_role()
        }

  @type campaign :: %{
          required(:id) => String.t(),
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
  def can?(_user, _action), do: false

  # ─── 1-context (campaign) actions ────────────────────────────────

  @spec can?(user(), atom(), campaign()) :: boolean()
  def can?(%{role: :admin}, _action, _campaign), do: true

  # GM-Actions: per-Campaign-:spielleiter reicht (egal welche globale
  # Rolle).
  def can?(user, action, _campaign)
      when action in [
             :delete_campaign,
             :edit_summary,
             :edit_epos,
             :edit_chronik,
             :edit_flavor,
             :edit_vocab,
             :add_utterance,
             :invite_to_campaign,
             :regenerate_session,
             :regenerate_campaign,
             :promote_member,
             :demote_member
           ] do
    Map.get(user, :campaign_role) == :spielleiter
  end

  # Member-Actions: jeder Member darf (egal ob :spielleiter oder
  # :spieler in der Campaign).
  def can?(user, action, _campaign)
      when action in [:join_mic, :set_own_alias] do
    case Map.get(user, :campaign_role) do
      :spielleiter -> true
      :spieler -> true
      _ -> false
    end
  end

  def can?(_user, _action, _campaign), do: false

  # ─── 2-context (utterance + campaign) actions ───────────────────

  @spec can?(user(), atom(), utterance(), campaign()) :: boolean()
  def can?(%{role: :admin}, _action, _utterance, _campaign), do: true

  def can?(user, action, utterance, _campaign)
      when action in [:edit_utterance, :delete_utterance] do
    cond do
      Map.get(user, :campaign_role) == :spielleiter -> true
      Map.get(user, :campaign_role) == :spieler and user.discord_id == utterance.discord_id -> true
      true -> false
    end
  end

  def can?(_user, _action, _utterance, _campaign), do: false
end
