defmodule HubWeb.Fixtures do
  @moduledoc """
  Gemeinsame Test-Fixtures für Hub-Tests (Issue #66).

  Ersetzt die pro Test inline gebauten User-Maps (`@admin`/`@spieler_member`/…
  in `permissions_test.exs`) und den ad-hoc zusammengesteckten Snapshot, den
  ein LiveView-/`derive_assigns`-Test braucht.

  - `user/1` — Superset-User-Map, brauchbar als Permission-Subjekt
    (`role`/`campaign_role`/`is_member?`) UND als Session-User für den Login
    (`discord_id`/`display_name`).
  - `member/2` — Member-Eintrag in Snapshot-Shape (String-Keys).
  - `snapshot/1` — string-keyed Worker-Snapshot, minimal aber valide für
    `HubWeb.CampaignLive.derive_assigns/2` und `apply_snapshot/2`.
  """

  @doc """
  User-Map. Defaults: globaler `:spieler`, kein Member.

  ## Optionen
    - `:discord_id` (Default `"did-test"`)
    - `:display_name` (Default `"Test User"`)
    - `:role` — globale Rolle `:admin | :spielleiter | :spieler` (Default `:spieler`)
    - `:campaign_role` — `:spielleiter | :spieler | nil` (Default `nil`)
    - `:is_member?` (Default abgeleitet: `campaign_role != nil`)
  """
  def user(opts \\ []) do
    campaign_role = Keyword.get(opts, :campaign_role, nil)

    %{
      discord_id: Keyword.get(opts, :discord_id, "did-test"),
      display_name: Keyword.get(opts, :display_name, "Test User"),
      role: Keyword.get(opts, :role, :spieler),
      campaign_role: campaign_role,
      is_member?: Keyword.get(opts, :is_member?, campaign_role != nil)
    }
  end

  @doc "Member-Eintrag in Snapshot-Shape (String-Keys). `role` z.B. `\"spielleiter\"`/`\"spieler\"`."
  def member(discord_id, role, display_name \\ nil) do
    %{
      "discord_id" => discord_id,
      "role" => role,
      "display_name" => display_name || "Member #{discord_id}"
    }
  end

  @doc """
  String-keyed Worker-Snapshot. Defaults reichen für `derive_assigns/2`; die
  Listen-/Map-Felder sind leer, weil `apply_snapshot/2` sie mit `|| []`/`|| %{}`
  defaultet.

  ## Optionen
    - `:campaign_id` (Default `"c-test"`) / `:name` (Default `"Test Campaign"`)
    - `:viewer_role` — `"admin" | "spielleiter" | "spieler"` (Default `"spieler"`)
    - `:members` — Liste von `member/2`-Maps (Default `[]`)
    - `:sessions`, `:utterances`, `:users`, `:summaries`, `:chronik` — optionale Overrides
  """
  def snapshot(opts \\ []) do
    campaign_id = Keyword.get(opts, :campaign_id, "c-test")

    %{
      "campaign" => %{
        "id" => campaign_id,
        "name" => Keyword.get(opts, :name, "Test Campaign")
      },
      "viewer_role" => Keyword.get(opts, :viewer_role, "spieler"),
      "members" => Keyword.get(opts, :members, []),
      "sessions" => Keyword.get(opts, :sessions, []),
      "utterances" => Keyword.get(opts, :utterances, []),
      "users" => Keyword.get(opts, :users, %{}),
      "summaries" => Keyword.get(opts, :summaries, []),
      "chronik" => Keyword.get(opts, :chronik, []),
      # Issue #746: Review-Queue (verifizierte, unplatzierbare Fakten).
      "review_facts" => Keyword.get(opts, :review_facts, []),
      # Issue #871/#883: geglättete Block-Ebene (Session-Views mit blocks).
      "smoothed" => Keyword.get(opts, :smoothed, []),
      # Issue #839/#885: Handlungsstränge (Arcs + Contexte) fürs Fäden-Panel.
      "campaign_threads" => Keyword.get(opts, :campaign_threads, []),
      "invites" => [],
      "markers" => [],
      "epos" => nil,
      "epos_history" => []
    }
  end
end
