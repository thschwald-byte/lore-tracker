defmodule Worker.LLMSpendCapTest do
  @moduledoc """
  Issue #632: Spend-Cap-Härtung. Deckt die drei geschlossenen Lücken in
  `Worker.LLM.check_spend_cap/4` ab:

    - Fix #1: `nil` admin_discord_id auf einem Cloud-Backend → hart verweigert
      (`{:error, :no_admin}`), NICHT mehr `:ok`.
    - Fix #2: Pre-Call-Token-Estimate — ein Call der spent+estimate über den
      Cap treibt wird schon VOR dem Call geblockt, nicht erst der nächste.
    - Fix #3: Per-Action-Burst-Limit — max. 50 Cloud-Calls in 60s pro
      discord_id, unabhängig vom Cap.

  `:local`-Backend bleibt in allen drei Fällen ungegated (kostenlos, kein
  Risiko).
  """
  use ExUnit.Case, async: false
  import Worker.TestHelper
  alias Worker.Schema.Builder, as: SB
  alias Worker.Schema.Mnesia, as: S

  @discord_id "632-user"
  @expensive_model "claude-opus-4-7"

  setup do
    clear_all_tables!()
    :ok
  end

  defp write_spend_row!(discord_id, ts, cost, opts \\ []) do
    row = {
      S.llm_spend(),
      Keyword.get(opts, :event_id, "evt-#{System.unique_integer([:positive])}"),
      ts,
      Keyword.get(opts, :provider, "anthropic"),
      Keyword.get(opts, :model, @expensive_model),
      Keyword.get(opts, :input_tokens, 100),
      Keyword.get(opts, :output_tokens, 100),
      cost,
      discord_id,
      Keyword.get(opts, :session_id, nil),
      Keyword.get(opts, :stage, "stage2"),
      Keyword.get(opts, :duration_ms, 100)
    }

    SB.write!(row)
  end

  describe "Fix #1 — nil admin_discord_id" do
    test ":local Backend bleibt bei nil discord_id erlaubt (kein Cloud-Call, kein Risiko)" do
      assert :ok == Worker.LLM.check_spend_cap(:local, nil, nil, "irrelevant prompt")
    end

    test "Cloud-Backend mit nil discord_id wird hart verweigert" do
      assert {:error, :no_admin} ==
               Worker.LLM.check_spend_cap(:anthropic, nil, @expensive_model, "hallo welt")
    end

    test "gilt für alle Cloud-Backends, nicht nur anthropic" do
      for backend <- [:anthropic, :openai, :google] do
        assert {:error, :no_admin} ==
                 Worker.LLM.check_spend_cap(backend, nil, "some-model", "prompt")
      end
    end
  end

  describe "Fix #2 — Pre-Call-Token-Estimate" do
    test "Call kurz unter dem Cap mit großem Prompt wird VOR dem Call geblockt" do
      SB.write!(SB.user(@discord_id, monthly_spend_cap_usd: 10.0))
      # spent = 9.99, knapp unterm Cap
      write_spend_row!(@discord_id, DateTime.utc_now(), 9.99)

      # Riesiger Prompt: 400_000 Zeichen / 4 = 100_000 Input-Tokens, + 4096
      # Output-Tokens fix. Bei claude-opus-4-7 ($15/$75 pro 1M):
      #   100_000/1e6*15 + 4096/1e6*75 ≈ 1.5 + 0.31 ≈ 1.81 USD estimate.
      # spent (9.99) + estimate (~1.81) >> cap (10.0) → muss blocken.
      huge_prompt = String.duplicate("x", 400_000)

      Worker.Settings.put(:model_stage2_anthropic, @expensive_model)

      assert {:error, :cap_estimate_exceeded} ==
               Worker.LLM.check_spend_cap(:anthropic, @discord_id, @expensive_model, huge_prompt)
    end

    test "kleiner Prompt weit unter dem Cap bleibt erlaubt" do
      SB.write!(SB.user(@discord_id, monthly_spend_cap_usd: 100.0))
      write_spend_row!(@discord_id, DateTime.utc_now(), 1.0)

      assert :ok ==
               Worker.LLM.check_spend_cap(:anthropic, @discord_id, @expensive_model, "hi there")
    end

    test "unbekanntes Modell schätzt Kosten als 0.0 — kein falscher Block" do
      SB.write!(SB.user(@discord_id, monthly_spend_cap_usd: 1.0))
      write_spend_row!(@discord_id, DateTime.utc_now(), 0.99)

      huge_prompt = String.duplicate("x", 400_000)

      assert :ok ==
               Worker.LLM.check_spend_cap(
                 :anthropic,
                 @discord_id,
                 "some-unknown-model-xyz",
                 huge_prompt
               )
    end

    test "nil Modell (kein Model konfiguriert) schätzt Kosten als 0.0" do
      SB.write!(SB.user(@discord_id, monthly_spend_cap_usd: 1.0))
      write_spend_row!(@discord_id, DateTime.utc_now(), 0.99)

      assert :ok ==
               Worker.LLM.check_spend_cap(:anthropic, @discord_id, nil, "prompt egal wie lang")
    end

    test "fehlender Cap (nil) bleibt trotz riesigem Prompt unbegrenzt erlaubt" do
      SB.write!(SB.user(@discord_id, monthly_spend_cap_usd: nil))
      huge_prompt = String.duplicate("x", 400_000)

      assert :ok ==
               Worker.LLM.check_spend_cap(:anthropic, @discord_id, @expensive_model, huge_prompt)
    end
  end

  describe "Fix #3 — Per-Action-Burst-Limit" do
    test "50 Calls in den letzten 60s blocken den 51. Call, unabhängig vom Cap" do
      # Kein Cap gesetzt (unbegrenzt) — Burst-Limit muss trotzdem greifen.
      SB.write!(SB.user(@discord_id, monthly_spend_cap_usd: nil))

      now = DateTime.utc_now()

      for i <- 1..50 do
        write_spend_row!(@discord_id, DateTime.add(now, -i, :second), 0.001)
      end

      assert {:error, :burst_limit_exceeded} ==
               Worker.LLM.check_spend_cap(:anthropic, @discord_id, @expensive_model, "prompt")
    end

    test "49 Calls in den letzten 60s bleiben erlaubt (Limit noch nicht erreicht)" do
      SB.write!(SB.user(@discord_id, monthly_spend_cap_usd: nil))

      now = DateTime.utc_now()

      for i <- 1..49 do
        write_spend_row!(@discord_id, DateTime.add(now, -i, :second), 0.001)
      end

      assert :ok ==
               Worker.LLM.check_spend_cap(:anthropic, @discord_id, @expensive_model, "prompt")
    end

    test "Calls außerhalb des 60s-Fensters zählen nicht fürs Burst-Limit" do
      SB.write!(SB.user(@discord_id, monthly_spend_cap_usd: nil))

      now = DateTime.utc_now()
      # 60 Calls, aber alle älter als 60s -> Fenster ist leer.
      for i <- 1..60 do
        write_spend_row!(@discord_id, DateTime.add(now, -(120 + i), :second), 0.001)
      end

      assert :ok ==
               Worker.LLM.check_spend_cap(:anthropic, @discord_id, @expensive_model, "prompt")
    end

    test "Burst-Check läuft vor dem teureren Cap-Estimate-Check" do
      # Cap ist schon längst überschritten UND Burst-Limit ist erreicht.
      # Der Fehler-Grund muss :burst_limit_exceeded sein (billigerer Check
      # zuerst), nicht :cap_estimate_exceeded.
      SB.write!(SB.user(@discord_id, monthly_spend_cap_usd: 1.0))

      now = DateTime.utc_now()

      for i <- 1..50 do
        write_spend_row!(@discord_id, DateTime.add(now, -i, :second), 1.0)
      end

      assert {:error, :burst_limit_exceeded} ==
               Worker.LLM.check_spend_cap(:anthropic, @discord_id, @expensive_model, "prompt")
    end

    test ":local Backend ist vom Burst-Limit ausgenommen" do
      SB.write!(SB.user(@discord_id, monthly_spend_cap_usd: nil))

      now = DateTime.utc_now()

      for i <- 1..60 do
        write_spend_row!(@discord_id, DateTime.add(now, -i, :second), 0.001)
      end

      assert :ok == Worker.LLM.check_spend_cap(:local, @discord_id, nil, "prompt")
    end
  end

  describe "Worker.Repo.recent_call_count/2" do
    test "zählt nur Calls im Zeitfenster für den gegebenen discord_id" do
      now = DateTime.utc_now()
      write_spend_row!(@discord_id, DateTime.add(now, -10, :second), 0.01)
      write_spend_row!(@discord_id, DateTime.add(now, -70, :second), 0.01)
      write_spend_row!("other-user", DateTime.add(now, -5, :second), 0.01)

      assert Worker.Repo.recent_call_count(@discord_id, 60) == 1
      assert Worker.Repo.recent_call_count(@discord_id, 120) == 2
      assert Worker.Repo.recent_call_count("other-user", 60) == 1
      assert Worker.Repo.recent_call_count("nobody", 60) == 0
    end
  end

  describe "complete/3 Call-Site-Integration" do
    test "no_admin bubbled als {:error, :no_admin} durch complete/3" do
      Worker.Settings.put(:backend_stage2, :anthropic)
      Worker.Settings.put(:model_stage2_anthropic, @expensive_model)
      # admin_discord_id explizit nicht gesetzt -> get_state liefert nil.

      assert {:error, :no_admin} == Worker.LLM.complete(:summary, "irgendein prompt")
    end
  end
end
