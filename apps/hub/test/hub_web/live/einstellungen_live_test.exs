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

  test "J4 (#1207): Stufe 2 ist der Jack-Block, Stufe 3 ist weg, 4/5 behalten ihren Backend-Stack",
       %{
         conn: conn
       } do
    lv = mount_as_admin(conn)
    html = render(lv)

    assert html =~ "Jack: Extract/verify"
    assert html =~ "Render — Resümee"
    assert html =~ "Render — Epos-Kapitel"
    refute html =~ "Extraktion (Wahrheitsbild)"
    refute html =~ "Verify (Grounding + Attribution)"

    for stage <- ["4", "5"] do
      assert has_element?(
               lv,
               ~s{input[phx-click="set_active_backend"][phx-value-stage="#{stage}"][phx-value-backend="anthropic"]}
             )
    end

    # Jack ist immer lokal: kein Backend-Radio, keine Cloud-Box für Stufe 2/3.
    for stage <- ["2", "3"] do
      refute has_element?(
               lv,
               ~s{input[phx-click="set_active_backend"][phx-value-stage="#{stage}"]}
             )

      refute has_element?(lv, ~s{button[phx-click="toggle_box"][phx-value-stage="#{stage}"]})
    end
  end

  test "J4 (#1207): der Jack-Block hat Modell, Regler und Kontextfenster mit Hilfetext", %{
    conn: conn
  } do
    lv = mount_as_admin(conn)
    html = render(lv)

    for key <- ~w(jack_temperature jack_top_p jack_frequency_penalty jack_max_tokens ctx_jack) do
      assert has_element?(lv, ~s{#jack-form input[name="settings[#{key}]"]})
    end

    # Das Modellfeld ist das live_select auf model_stage2_local.
    assert has_element?(lv, "#jack-form #settings_model_stage2_local_live_select_component")

    # Hilfetext am Kontextfenster: es setzt nicht das Fenster des Servers.
    assert html =~ "OLLAMA_CONTEXT_LENGTH"
    assert html =~ "/v1/chat/completions"
    assert html =~ "Figuren- und Strang-Zuordnung"

    # Die entfernten Stufe-2-Regler gibt es nicht mehr als Feld.
    for key <- ~w(extract_num_predict_cap ctx_stage2 temperature_stage2 model_stage2_think) do
      refute has_element?(lv, ~s{input[name="settings[#{key}]"]})
    end
  end

  test "J4 (#1207): local_endpoint hat genau EIN Eingabefeld — der Jack-Block zeigt ihn nur an",
       %{
         conn: conn
       } do
    # Zwei Felder mit demselben Namen wären zwei Orte zum Ändern, und nach dem
    # Speichern der einen Form stünde in der anderen ein veralteter Wert.
    lv = mount_as_admin(conn)
    html = render(lv)

    assert length(Regex.scan(~r/name="settings\[local_endpoint\]"/, html)) == 1
    refute has_element?(lv, ~s{#jack-form input[name="settings[local_endpoint]"]})
    assert has_element?(lv, "#jack-form", "Local-Endpoint URL")
  end

  test "J4 (#1207): Jack speichern läuft über das save-Event — ohne Worker ein Fehler statt Crash",
       %{conn: conn} do
    lv = mount_as_admin(conn)

    html =
      lv
      |> element("form#jack-form")
      |> render_submit(%{"settings" => %{"jack_temperature" => "0.5", "ctx_jack" => "65536"}})

    assert html =~ "Worker offline — Settings nicht gespeichert."
  end

  test "#755 Reopen: num_predict-Felder schreiben echte Keys (Stage 4/5 optional)", %{
    conn: conn
  } do
    # Das frühere generische num_predict_stage{n}-Feld schrieb einen Key
    # außerhalb der Settings-Whitelist — der Save wurde still verworfen
    # (totes Eingabefeld). Jetzt echt verdrahtet: Stage 4/5 →
    # num_predict_stage{n} als optionale Notbremse (leer = aus). Dass alle
    # Keys in der Whitelist stehen, sichert der Drift-Guard
    # (Worker.SettingsUiDriftTest).
    lv = mount_as_admin(conn)

    for n <- [4, 5] do
      assert has_element?(lv, ~s{input[name="settings[num_predict_stage#{n}]"]})
    end

    for n <- [2, 3] do
      refute has_element?(lv, ~s{input[name="settings[num_predict_stage#{n}]"]})
    end
  end

  test "#874: Thinking-Level-Radios pro Stage (4/5) in der Local-Box, Default 'auto' checked", %{
    conn: conn
  } do
    # Für Reasoning-Modelle mit nicht abschaltbarem Thinking (gpt-oss):
    # think:false erzwingt unter JSON-Schema-Zwang ein leeres Objekt — das
    # Level-Setting ist der Ausweg. Ohne Settings-Snapshot muss das
    # auto-Radio vorgewählt sein (heutiges #700-Verhalten als Default).
    # Seit J4 (#1207) hat Stufe 2 den Schalter nicht mehr.
    lv = mount_as_admin(conn)

    refute has_element?(lv, ~s{input[name="settings[model_stage2_think]"]})
    refute has_element?(lv, ~s{input[name="settings[model_stage2_local_endpoint]"]})

    for n <- 4..5 do
      for level <- ~w(auto low medium high) do
        assert has_element?(
                 lv,
                 ~s{input[type="radio"][name="settings[model_stage#{n}_think]"][value="#{level}"]}
               )
      end

      assert has_element?(
               lv,
               ~s{input[name="settings[model_stage#{n}_think]"][value="auto"][checked]}
             )

      refute has_element?(
               lv,
               ~s{input[name="settings[model_stage#{n}_think]"][value="medium"][checked]}
             )
    end
  end

  test "#874 Nachtrag: Gap-Fill hat eigene Endpoint-/Thinking-Radios (Defaults generate/auto)", %{
    conn: conn
  } do
    lv = mount_as_admin(conn)

    for ep <- ~w(generate chat) do
      assert has_element?(
               lv,
               ~s{input[type="radio"][name="settings[gapfill_local_endpoint]"][value="#{ep}"]}
             )
    end

    for level <- ~w(auto low medium high) do
      assert has_element?(
               lv,
               ~s{input[type="radio"][name="settings[gapfill_think]"][value="#{level}"]}
             )
    end

    assert has_element?(
             lv,
             ~s{input[name="settings[gapfill_local_endpoint]"][value="generate"][checked]}
           )

    assert has_element?(lv, ~s{input[name="settings[gapfill_think]"][value="auto"][checked]})
  end

  test "#755 Reopen: Config-Reihenfolge = Pipeline-Reihenfolge — Stage 1 (Whisper) ZUERST", %{
    conn: conn
  } do
    # Tom-Kernanforderung aus #812 („erst Stage 1, dann 2, dann 3, dann 4"),
    # die dort nie umgesetzt wurde: der Whisper-Block (Stage 1) stand UNTER
    # den LLM-Stages. DOM-Positions-Beweis über die Fieldset-Legenden.
    lv = mount_as_admin(conn)
    html = render(lv)

    # Seit J4 (#1207): Stufe 2 ist der Jack-Block, Stufe 3 gibt es nicht mehr.
    positions =
      for n <- [1, 2, 4, 5] do
        pos = :binary.match(html, "Stage #{n}</legend>") |> elem(0)
        {n, pos}
      end

    sorted = Enum.sort_by(positions, fn {_n, pos} -> pos end) |> Enum.map(&elem(&1, 0))

    assert sorted == [1, 2, 4, 5],
           "Stage-Blöcke nicht in Pipeline-Reihenfolge: #{inspect(sorted)}"

    assert :binary.match(html, "Stage 3</legend>") == :nomatch

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
        ~s{button[phx-click="toggle_box"][phx-value-stage="4"][phx-value-backend="anthropic"]}
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
        ~s{input[phx-click="set_active_backend"][phx-value-stage="4"][phx-value-backend="anthropic"]}
      )
      |> render_click()

    assert html =~ "Worker offline"
  end

  test "save_backend_box ohne Worker → Fehler-Badge; Event-Shape stimmt", %{conn: conn} do
    lv = mount_as_admin(conn)

    # Anthropic-Box aufklappen, dann deren Form submitten.
    lv
    |> element(
      ~s{button[phx-click="toggle_box"][phx-value-stage="4"][phx-value-backend="anthropic"]}
    )
    |> render_click()

    html =
      lv
      |> element(~s{form#box-form-4-anthropic})
      |> render_submit(%{
        "stage" => "4",
        "backend" => "anthropic",
        "settings" => %{"model_stage4_anthropic" => "claude-haiku-4-5"}
      })

    assert html =~ "Worker offline"
    # Optimistisches Merge: der gespeicherte Wert steht sofort in der UI.
    assert html =~ "claude-haiku-4-5"
  end

  test "#786-Regression: Box-Save + Toggle für Stage 4/5 crasht die LV NICHT (parse_stage!)", %{
    conn: conn
  } do
    # Seit #786 akzeptierte parse_stage! nur Stage 2 — jeder Speichern-Klick in
    # den Stage-3/4/5-Boxen warf ArgumentError → LV-Re-Mount → „Werte springen
    # zurück" (Teststage-Befund 2026-07-16). Seit J4 (#1207) gibt es nur noch
    # die Boxen der Stages 4 und 5.
    lv = mount_as_admin(conn)

    for n <- [4, 5] do
      lv
      |> element(
        ~s{button[phx-click="toggle_box"][phx-value-stage="#{n}"][phx-value-backend="local"]}
      )
      |> render_click()

      html =
        lv
        |> element(~s{form#box-form-#{n}-local})
        |> render_submit(%{
          "stage" => "#{n}",
          "backend" => "local",
          "settings" => %{"model_stage#{n}_local" => "qwen2.5:7b"}
        })

      # Ohne Worker: Fehler-Badge statt Crash — die LV lebt noch.
      assert html =~ "Worker offline"
    end
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

  # ─── #1076: Gateway-Zustand neben dem Token-Status ─────────────────

  describe "#1076: Discord-Gateway-Zustand" do
    test "ohne Worker-Meldung steht 'unbekannt' — nicht stillschweigend 'alles gut'", %{
      conn: conn
    } do
      html = conn |> mount_as_admin() |> render()

      assert html =~ "Gateway-Verbindung"
      assert html =~ "unbekannt"
    end

    test "der Zustand wird in Worten gerendert, nicht als roher Code", %{conn: conn} do
      # Der ganze Punkt von #1076 ist Ablesbarkeit: „Token gesetzt" und
      # „Gateway verbunden" sind zwei Aussagen, und ihre Verwechslung hielt
      # einen toten Discord-Pfad tagelang unsichtbar. Farbe allein trägt das
      # nicht (nicht zugänglich), also muss der Text es sagen.
      # stub_reader!/1 startet einen Agent — nur EIN Aufruf pro Test, also
      # Rolle und Gateway-Zustand in derselben Antwort.
      stub_reader!(%{
        "users" => [
          %{"discord_id" => "did-test", "role" => "admin", "display_name" => "Test"}
        ],
        "discord_gateway" => %{
          "state" => "retrying",
          "detail" => "nxdomain",
          "attempts" => 3,
          "since" => "2026-08-18T06:48:12Z"
        }
      })

      user = Fixtures.user(discord_id: "did-test", role: :admin)
      {:ok, lv, _html} = conn |> log_in(user) |> live("/settings")
      _ = render_async(lv)
      html = render(lv)

      assert html =~ "kein Netz — versucht es erneut"
      assert html =~ "nxdomain"
      assert html =~ "3 Fehlversuch"
      # Der Token-Status bleibt eine EIGENE Aussage daneben.
      assert html =~ "discord_bot_token"
    end
  end
end
