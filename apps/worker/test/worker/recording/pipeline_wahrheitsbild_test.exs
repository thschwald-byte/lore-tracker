defmodule Worker.Recording.PipelineWahrheitsbildTest do
  @moduledoc """
  Issues #714 + #716: End-to-End-Test des Wahrheitsbild-Orchestrators
  (`Pipeline.run_wahrheitsbild/4`) mit injizierten Schritt-Deps (kein LLM,
  kein Sidecar — die Pur-Kerne haben eigene Tests).

  Abgedeckt:
  - Happy path: extract → registry → verify → render → SessionSummaryGenerated
    (Worker-First-Apply, Summary + source_refs-Union im Repo).
  - #714: Registry läuft ZWISCHEN Extraktion und Verify; Registry-Fehler
    bricht die Pipeline NICHT (Fakten unverändert, Lauf wird :ok).
  - #716: Schritt-Fehler landen getaggt in /admin/errors mit der richtigen
    Fehlerklasse (sidecar_offline / no_verified_facts / extraction_empty),
    Folge-Schritte laufen nicht mehr.
  - classify_pipeline_error-Klauseln für die neuen Wrapper-Tags (pure).
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Worker.TestHelper

  alias Worker.Recording.Pipeline
  alias Worker.Repo
  alias Worker.Schema.Builder

  @session %{id: "s-wb"}
  @campaign %{id: "c-wb"}

  setup do
    clear_all_tables!()
    mat = ensure_materializer!()
    on_exit(fn -> if mat && Process.alive?(mat), do: Process.exit(mat, :kill) end)

    Builder.write!(Builder.campaign("c-wb"))
    Builder.write!(Builder.session("s-wb", "c-wb", number: 1))
    :ok
  end

  defp fact(id, refs) do
    %{
      "id" => id,
      "claim" => "Claim #{id}",
      "entity_id" => "e",
      "character_alias" => "Figur",
      "source_refs" => refs,
      "grounded?" => true,
      "attributed?" => true,
      "verified?" => true
    }
  end

  defp rendered(md), do: %{md: md, traceable: [String.trim(md)], flagged: [], clean?: true}

  # Schritt-Stub, der seinen Aufruf an den Test-Prozess meldet (Reihenfolge-
  # und Nicht-Aufruf-Beweise) und `result` liefert.
  defp step(tag, result) do
    parent = self()

    fn ->
      send(parent, {:step, tag})
      result
    end
  end

  defp last_error do
    Worker.Repo.Snapshots.last_n_pipeline_errors(1) |> List.first()
  end

  test "happy path: publiziert SessionSummaryGenerated mit source_refs-Union" do
    verified = [fact("f1", ["u-1", "u-2"]), fact("f2", ["u-2", "u-3"])]

    deps = %{
      extract: step(:extract, {:ok, verified}),
      resolve: step(:resolve, {:ok, %{"könig" => "koenig"}}),
      verify: step(:verify, {:ok, verified}),
      render: fn facts ->
        send(self(), {:step, :render})
        assert facts == verified
        {:ok, rendered("Es begab sich aber zu der Zeit.")}
      end
    }

    capture_log(fn ->
      assert :ok = Pipeline.run_wahrheitsbild(@session, @campaign, [], deps)
    end)

    summary = Repo.get_session_summary("s-wb")
    assert summary.content_md == "Es begab sich aber zu der Zeit."
    assert Enum.sort(summary.source_refs) == ["u-1", "u-2", "u-3"]
  end

  test "#714: Registry läuft zwischen Extraktion und Verify (Reihenfolge)" do
    verified = [fact("f1", ["u-1"])]

    deps = %{
      extract: step(:extract, {:ok, verified}),
      resolve: step(:resolve, {:ok, %{}}),
      verify: step(:verify, {:ok, verified}),
      render: fn _ ->
        send(self(), {:step, :render})
        {:ok, rendered("ok.")}
      end
    }

    capture_log(fn ->
      assert :ok = Pipeline.run_wahrheitsbild(@session, @campaign, [], deps)
    end)

    assert {:messages, [{:step, :extract}, {:step, :resolve}, {:step, :verify}, {:step, :render}]} =
             Process.info(self(), :messages)
  end

  test "#714: Registry-Fehler bricht die Pipeline NICHT (best-effort, Fakten unverändert)" do
    verified = [fact("f1", ["u-1"])]

    deps = %{
      extract: step(:extract, {:ok, verified}),
      resolve: step(:resolve, {:error, :parse_failed}),
      verify: step(:verify, {:ok, verified}),
      render: fn _ -> {:ok, rendered("trotzdem da.")} end
    }

    log =
      capture_log(fn ->
        assert :ok = Pipeline.run_wahrheitsbild(@session, @campaign, [], deps)
      end)

    assert log =~ "Entity-Registry-Clustering fehlgeschlagen"
    assert Repo.get_session_summary("s-wb").content_md == "trotzdem da."
  end

  test "#716: Verify-Sidecar offline → getaggter Fehler, Render läuft nicht, /admin/errors-Klasse stimmt" do
    deps = %{
      extract: step(:extract, {:ok, [fact("f1", ["u-1"])]}),
      resolve: step(:resolve, {:ok, %{}}),
      verify: step(:verify, {:error, :sidecar_offline}),
      render: fn _ ->
        send(self(), {:step, :render})
        {:ok, rendered("nie.")}
      end
    }

    capture_log(fn ->
      assert {:error, {:verify, :sidecar_offline}} =
               Pipeline.run_wahrheitsbild(@session, @campaign, [], deps)
    end)

    refute_received {:step, :render}
    assert Repo.get_session_summary("s-wb") == nil

    err = last_error()
    assert err.error_type == "sidecar_offline"
    assert err.stage == "verify"
    assert err.session_id == "s-wb"
  end

  test "#716: Render ohne verifizierte Fakten → no_verified_facts in /admin/errors" do
    verified = [fact("f1", ["u-1"])]

    deps = %{
      extract: step(:extract, {:ok, verified}),
      resolve: step(:resolve, {:ok, %{}}),
      verify: step(:verify, {:ok, verified}),
      render: fn _ -> {:error, :no_verified_facts} end
    }

    capture_log(fn ->
      assert {:error, {:render, :no_verified_facts}} =
               Pipeline.run_wahrheitsbild(@session, @campaign, [], deps)
    end)

    err = last_error()
    assert err.error_type == "no_verified_facts"
    assert err.stage == "render"
  end

  test "#716: leere Extraktion → extraction_empty, Registry/Verify laufen nicht" do
    deps = %{
      extract: step(:extract, {:error, {:extraction, :empty}}),
      resolve: step(:resolve, {:ok, %{}}),
      verify: step(:verify, {:ok, []}),
      render: fn _ -> {:ok, rendered("nie.")} end
    }

    capture_log(fn ->
      assert {:error, {:extraction, :empty}} =
               Pipeline.run_wahrheitsbild(@session, @campaign, [], deps)
    end)

    refute_received {:step, :resolve}
    refute_received {:step, :verify}

    assert last_error().error_type == "extraction_empty"
  end

  describe "classify_pipeline_error/1 — Wahrheitsbild-Tags (pure, #716)" do
    test "Schritt-Wrapper werden gestrippt wie die Chain-Wrapper" do
      assert Pipeline.classify_pipeline_error({:extraction, :timeout}) == "timeout"
      assert Pipeline.classify_pipeline_error({:verify, :no_facts}) == "no_facts"

      assert Pipeline.classify_pipeline_error({:render, :spend_cap_exceeded}) ==
               "spend_cap_exceeded"
    end

    test "Wahrheitsbild-Klassen" do
      assert Pipeline.classify_pipeline_error({:verify, :sidecar_offline}) == "sidecar_offline"

      assert Pipeline.classify_pipeline_error({:render, :no_verified_facts}) ==
               "no_verified_facts"

      assert Pipeline.classify_pipeline_error({:extraction, :empty}) == "extraction_empty"

      assert Pipeline.classify_pipeline_error({:extraction, :all_chunks_failed}) ==
               "all_chunks_failed"
    end
  end
end
