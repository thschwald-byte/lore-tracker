defmodule HubWeb.EinstellungenLiveTest do
  @moduledoc """
  Issue #451 (Track A): `/settings` ist ein Admin-only Bereich. Spieler/
  Spielleiter ohne globale Admin-Rolle werden beim Mount auf "/" geleitet,
  Admins kommen rein.

  Der SidebarContext-on_mount-Hook (Issue #387) liest die globale Rolle
  via `Reader.read(%{"kind" => "all_users"})`. Im Test gibt der ReaderStub
  diese Antwort an alle Reader-Calls weiter — sowohl an den Hook als auch
  an `load_settings/1`. Settings-relevante Felder bleiben leer; das LV
  fällt im Reader-Pfad auf den Default-Branch und mountet wartend, was
  für den Permission-Test reicht.
  """

  use HubWeb.ConnCase, async: false

  defp stub_with_role(role) when role in [:admin, :spielleiter, :spieler] do
    stub_reader!(%{
      "users" => [
        %{
          "discord_id" => "did-test",
          "role" => Atom.to_string(role),
          "display_name" => "Test"
        }
      ]
    })
  end

  test "Spieler mountet /settings → redirect zu / mit Flash", %{conn: conn} do
    stub_with_role(:spieler)
    user = Fixtures.user(discord_id: "did-test", role: :spieler)

    assert {:error, {:live_redirect, %{to: "/", flash: flash}}} =
             conn |> log_in(user) |> live("/settings")

    assert flash["error"] =~ "Admin-only"
  end

  test "Spielleiter (ohne globale Admin-Rolle) wird ebenfalls weggeschickt", %{conn: conn} do
    stub_with_role(:spielleiter)
    user = Fixtures.user(discord_id: "did-test", role: :spielleiter)

    assert {:error, {:live_redirect, %{to: "/"}}} =
             conn |> log_in(user) |> live("/settings")
  end

  test "Admin mountet /settings — kein Redirect, Seite rendert", %{conn: conn} do
    stub_with_role(:admin)
    user = Fixtures.user(discord_id: "did-test", role: :admin)

    {:ok, _lv, html} =
      conn |> log_in(user) |> live("/settings")

    # Heading der Einstellungen-LV ist im Test sichtbar — kein Redirect.
    assert html =~ "Einstellungen" or html =~ "Worker"
  end

  # ─── #451 Track C: Backend-Stack pro Stage ─────────────────────────

  defp mount_as_admin(conn) do
    stub_with_role(:admin)
    user = Fixtures.user(discord_id: "did-test", role: :admin)
    {:ok, lv, _html} = conn |> log_in(user) |> live("/settings")
    # Snapshot-Load ist async — erst nach render_async steht der Stack.
    _ = render_async(lv)
    lv
  end

  test "Stage-Block rendert den Backend-Stack: 4 Boxen mit Radio, Local aktiv", %{conn: conn} do
    lv = mount_as_admin(conn)
    html = render(lv)

    for label <- ["Local (Ollama)", "Anthropic (Claude)", "OpenAI (GPT)", "Google (Gemini)"] do
      assert html =~ label
    end

    # Ohne Settings-Snapshot ist Local aktiv/expanded; inaktive Boxen zeigen
    # die Kein-Modell-Zeile.
    assert html =~ "(kein Modell gewählt)"
    assert html =~ "Local (Ollama) speichern"
    # Radio-Buttons je Stage vorhanden (set_active_backend verdrahtet).
    assert html =~ "set_active_backend"
    assert html =~ "toggle_box"
  end

  test "#783 Phase 2 (+ Nachtrag): Stage 3/4/5 (Verify/Resümee/Epos) rendern jetzt eigene Backend-Stacks",
       %{
         conn: conn
       } do
    # Vor #783 Phase 2 hatte @stages nur 2 Einträge (Stage 1 Platzhalter +
    # Stage 2) — Stage 3/4 waren nie im DOM. Nachtrag: Resümee und Epos
    # liefen anfangs noch zusammen auf Stage 4, jetzt hat jeder Schritt
    # seinen eigenen unabhängigen Radio+Modell-Block (2/3/4/5).
    lv = mount_as_admin(conn)
    html = render(lv)

    assert html =~ "Extraktion (Wahrheitsbild)"
    assert html =~ "Verify (Grounding + Attribution)"
    assert html =~ "Render — Resümee"
    assert html =~ "Render — Epos-Kapitel"

    for stage <- ["2", "3", "4", "5"] do
      assert has_element?(
               lv,
               ~s{input[phx-click="set_active_backend"][phx-value-stage="#{stage}"][phx-value-backend="anthropic"]}
             )
    end
  end

  test "#755 Reopen: num_predict-Felder schreiben echte Keys (Stage 2 Cap, 3/4/5 optional)", %{
    conn: conn
  } do
    # Das frühere generische num_predict_stage{n}-Feld schrieb einen Key
    # außerhalb der Settings-Whitelist — der Save wurde still verworfen
    # (totes Eingabefeld). Jetzt echt verdrahtet: Stage 2 → das immer aktive
    # extract_num_predict_cap (#763), Stage 3/4/5 → num_predict_stage{n} als
    # optionale Notbremse (leer = aus). Dass alle Keys in der Whitelist
    # stehen, sichert der Drift-Guard (Worker.SettingsUiDriftTest).
    lv = mount_as_admin(conn)

    assert has_element?(lv, ~s{input[name="settings[extract_num_predict_cap]"]})

    for n <- [3, 4, 5] do
      assert has_element?(lv, ~s{input[name="settings[num_predict_stage#{n}]"]})
    end

    refute has_element?(lv, ~s{input[name="settings[num_predict_stage2]"]})
  end

  test "#755 Reopen: Config-Reihenfolge = Pipeline-Reihenfolge — Stage 1 (Whisper) ZUERST", %{
    conn: conn
  } do
    # Tom-Kernanforderung aus #812 („erst Stage 1, dann 2, dann 3, dann 4"),
    # die dort nie umgesetzt wurde: der Whisper-Block (Stage 1) stand UNTER
    # den LLM-Stages. DOM-Positions-Beweis über die Fieldset-Legenden.
    lv = mount_as_admin(conn)
    html = render(lv)

    positions =
      for n <- 1..5 do
        pos = :binary.match(html, "Stage #{n}</legend>") |> elem(0)
        {n, pos}
      end

    sorted = Enum.sort_by(positions, fn {_n, pos} -> pos end) |> Enum.map(&elem(&1, 0))

    assert sorted == [1, 2, 3, 4, 5],
           "Stage-Blöcke nicht in Pipeline-Reihenfolge: #{inspect(sorted)}"

    # Stage 1 trägt die Whisper-Felder (nicht nur ein leerer Rahmen).
    assert has_element?(lv, ~s{input[name="settings[whisper_bin]"]})
    assert has_element?(lv, ~s{input[name="settings[ffmpeg_bin]"]})
  end

  test "toggle_box expandiert eine inaktive Box (eigener Speichern-Button sichtbar)", %{
    conn: conn
  } do
    lv = mount_as_admin(conn)

    html =
      lv
      |> element(
        ~s{button[phx-click="toggle_box"][phx-value-stage="2"][phx-value-backend="anthropic"]}
      )
      |> render_click()

    assert html =~ "Anthropic (Claude) speichern"
  end

  test "set_active_backend ohne Worker → Fehler-Badge statt Crash", %{conn: conn} do
    # Kein Worker im Registry (Test-Env) → selected_worker_id ist nil. Der
    # Radio-Klick darf nicht crashen, sondern zeigt den Offline-Status.
    lv = mount_as_admin(conn)

    html =
      lv
      |> element(
        ~s{input[phx-click="set_active_backend"][phx-value-stage="2"][phx-value-backend="anthropic"]}
      )
      |> render_click()

    assert html =~ "Worker offline"
  end

  test "save_backend_box ohne Worker → Fehler-Badge; Event-Shape stimmt", %{conn: conn} do
    lv = mount_as_admin(conn)

    # Anthropic-Box aufklappen, dann deren Form submitten.
    lv
    |> element(
      ~s{button[phx-click="toggle_box"][phx-value-stage="2"][phx-value-backend="anthropic"]}
    )
    |> render_click()

    html =
      lv
      |> element(~s{form#box-form-2-anthropic})
      |> render_submit(%{
        "stage" => "2",
        "backend" => "anthropic",
        "settings" => %{"model_stage2_anthropic" => "claude-haiku-4-5"}
      })

    assert html =~ "Worker offline"
    # Optimistisches Merge: der gespeicherte Wert steht sofort in der UI.
    assert html =~ "claude-haiku-4-5"
  end

  # ─── #865 (Epic #861 Slice E): Stage-1.1-Felder + merge_gap-Warnung ────

  test "#865: Stage-1.1-Panel rendert merge_gap_seconds + gapfill_model Felder", %{conn: conn} do
    lv = mount_as_admin(conn)

    assert has_element?(lv, ~s{input[name="settings[merge_gap_seconds]"]})
    assert has_element?(lv, ~s{input[name="settings[gapfill_model]"]})
  end

  test "#865: merge_gap-Warnung nennt N + Review-noetig, verspricht NIE verwirft", %{
    conn: conn
  } do
    # Der ReaderStub beantwortet ALLE Reader-Calls mit derselben Map — der
    # settings-Snapshot-Load sieht so luecken_kuration_count == 3.
    stub_reader!(%{
      "users" => [
        %{"discord_id" => "did-test", "role" => "admin", "display_name" => "Test"}
      ],
      "settings" => %{},
      "luecken_kuration_count" => 3
    })

    user = Fixtures.user(discord_id: "did-test", role: :admin)
    {:ok, lv, _html} = conn |> log_in(user) |> live("/settings")
    _ = render_async(lv)
    html = render(lv)

    # Warntext-Assertion (Plan Runde 6): mit Re-Attach landen nicht-mehr-
    # paarende Kurationen in der Review-Queue — das UI darf kein Verwerfen
    # versprechen, das das System nicht (mehr) hat.
    assert html =~ "berührt 3 Kuration(en) (Review nötig)"
    refute html =~ "verwirft"
    refute html =~ "verworfen werden"
  end

  test "#865: ohne Kurationen keine merge_gap-Warnung", %{conn: conn} do
    lv = mount_as_admin(conn)
    refute render(lv) =~ "Review nötig"
  end
end
