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
  | `:delete_session(c)`    | ✓      | ✓                         | ✗                                 |
  | `:assign_speaker(c)`    | ✓      | ✓                         | ✗                                 |
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

  # Offener Map-Typ (analog campaign()/utterance()): Aufrufer reichen perm_user-
  # Maps mit Extra-Keys durch (z.B. `is_member?` aus den Admin-LVs). Ein
  # geschlossener Typ ließ Dialyzer jeden can?-Call für „will never succeed"
  # halten → mount no_return → ~30 Cascade-Findings (#589). campaign_role wird
  # zur Laufzeit via Map.get geprüft, daher als any tolerierbar.
  @type user :: %{
          required(:discord_id) => String.t(),
          required(:role) => global_role(),
          optional(any) => any
        }

  @type campaign :: %{
          required(:id) => String.t(),
          optional(any) => any
        }

  @type utterance :: %{
          required(:discord_id) => String.t(),
          optional(any) => any
        }

  @doc """
  Issue #545: Wire-String → globale Rolle (Atom). Eine Stelle statt der früheren
  1:1-Duplikate `parse_viewer_role/1` in `DashboardLive` + `CampaignLive`.
  Unbekannt/`nil` → `:spieler` (Least-Privilege-Default).
  """
  @spec parse_role(any()) :: :admin | :spielleiter | :spieler
  def parse_role("admin"), do: :admin
  def parse_role("spielleiter"), do: :spielleiter
  def parse_role("spieler"), do: :spieler
  def parse_role(_), do: :spieler

  @doc """
  Issue #720: der Admin-LV-`perm_user` an EINER Stelle statt 7 Mount-Duplikaten
  (einstellungen/admin_users/cloud_api/admin_probelauf/admin_errors/admin_jobs/
  admin_spend). `current_user_role` kommt aus dem SidebarContext-on_mount-Hook
  (#387); fehlt er → `:spieler` (Least-Privilege-Default, `:view_admin`-Gate
  schickt dann auf "/"). `is_member?:`-Option für Sonderfälle (Probelauf).
  """
  @spec admin_perm_user(%{:discord_id => String.t(), optional(any()) => any()}, any(), keyword()) ::
          user()
  def admin_perm_user(user, current_user_role, opts \\ []) do
    %{
      discord_id: user.discord_id,
      role: current_user_role || :spieler,
      is_member?: Keyword.get(opts, :is_member?, false)
    }
  end

  # ─── 0-arg actions ──────────────────────────────────────────────

  @spec can?(user(), atom()) :: boolean()
  def can?(%{role: :admin}, _), do: true
  def can?(%{role: :spielleiter}, :create_campaign), do: true
  def can?(_, :create_campaign), do: false
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
             :delete_session,
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
             :demote_member,
             :assign_speaker,
             # Issue #724: In-Game-Datum-Anker pro Session + Kampagnen-Kalender.
             :set_session_date,
             :edit_calendar,
             # Issue #724 Slice F: Review-Queue-Fakt-Korrektur (Datum setzen /
             # dauerhaft ausblenden).
             :set_fact_date
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
      Map.get(user, :campaign_role) == :spielleiter ->
        true

      Map.get(user, :campaign_role) == :spieler and user.discord_id == utterance.discord_id ->
        true

      true ->
        false
    end
  end

  def can?(_user, _action, _utterance, _campaign), do: false
end
