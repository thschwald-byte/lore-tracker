# Issue #544 (Cut 2): die 4 portierten lore.audit-Checks. Wie beim Spike via
# requires geladen + credo-App starten (runtime: false).
for f <-
      ~w(unsupervised_task_start hardcoded_event_kind timer_without_cleanup ignored_intents_publish) do
  Code.require_file(Path.expand("../../../../tools/credo/#{f}.ex", __DIR__))
end

{:ok, _} = Application.ensure_all_started(:credo)

defmodule LoreTracker.Credo.Check.PortedChecksTest do
  @moduledoc """
  Issue #544 / #557-Lesson #2: pro Check ein Positiv- + Negativ-Fixture. Die
  Negativ-Fälle sperren die FP-Klassen ein, die der jeweilige Regex-Vorgänger
  hatte (besonders der `@moduledoc`-FP von `hardcoded_event_kind`, der den
  events_ssot_guard/#471 + lore.audit/#536 rotfärbte).
  """
  use Credo.Test.Case

  alias LoreTracker.Credo.Check.HardcodedEventKind
  alias LoreTracker.Credo.Check.IgnoredIntentsPublish
  alias LoreTracker.Credo.Check.TimerWithoutCleanup
  alias LoreTracker.Credo.Check.UnsupervisedTaskStart

  @worker "apps/worker/lib/worker/foo.ex"

  describe "UnsupervisedTaskStart" do
    test "Positiv: Task.start/1 wird geflaggt" do
      """
      defmodule Worker.Foo do
        def go, do: Task.start(fn -> work() end)
      end
      """
      |> to_source_file(@worker)
      |> run_check(UnsupervisedTaskStart)
      |> assert_issue(fn i -> assert i.trigger == "Task.start" end)
    end

    test "Negativ: Task.start_link + Task.Supervisor.start_child bleiben still" do
      """
      defmodule Worker.Foo do
        def go do
          Task.start_link(fn -> work() end)
          Task.Supervisor.start_child(Worker.TaskSup, fn -> work() end)
        end
      end
      """
      |> to_source_file(@worker)
      |> run_check(UnsupervisedTaskStart)
      |> refute_issues()
    end

    test "Negativ: Task.start in einem Mix-Task ist ausgenommen" do
      """
      defmodule Mix.Tasks.Foo do
        def run(_), do: Task.start(fn -> work() end)
      end
      """
      |> to_source_file("apps/worker/lib/mix/tasks/foo.ex")
      |> run_check(UnsupervisedTaskStart)
      |> refute_issues()
    end
  end

  describe "HardcodedEventKind" do
    test "Positiv: %{\"kind\" => \"Foo\"} wird geflaggt" do
      """
      defmodule Worker.Foo do
        def go, do: Worker.Intents.publish(%{"kind" => "SessionEnded", "id" => 1})
      end
      """
      |> to_source_file(@worker)
      |> run_check(HardcodedEventKind)
      |> assert_issue()
    end

    test "Negativ (#471-FP): \"kind\" => \"Foo\" im @moduledoc-String bleibt still" do
      ~S'''
      defmodule Worker.Foo do
        @moduledoc "Beispiel-Pattern: %{\"kind\" => \"SessionEnded\"} nicht hardcoden."
        def go, do: :ok
      end
      '''
      |> to_source_file(@worker)
      |> run_check(HardcodedEventKind)
      |> refute_issues()
    end

    test "Negativ: events.ex (SSoT-Definition) ist ausgenommen" do
      """
      defmodule Shared.Events do
        def session_ended, do: "SessionEnded"
        def m, do: %{"kind" => "SessionEnded"}
      end
      """
      |> to_source_file("apps/shared/lib/shared/events.ex")
      |> run_check(HardcodedEventKind)
      |> refute_issues()
    end

    test "Negativ: nicht-PascalCase + nicht-String bleibt still" do
      """
      defmodule Worker.Foo do
        def go(k), do: [%{"kind" => "lowercase"}, %{"kind" => k}]
      end
      """
      |> to_source_file(@worker)
      |> run_check(HardcodedEventKind)
      |> refute_issues()
    end
  end

  describe "TimerWithoutCleanup" do
    test "Positiv: send_after(self()) ohne cancel_timer" do
      """
      defmodule Worker.Foo do
        def tick(s), do: Process.send_after(self(), :tick, 1000)
      end
      """
      |> to_source_file(@worker)
      |> run_check(TimerWithoutCleanup)
      |> assert_issue(fn i -> assert i.trigger == "Process.send_after" end)
    end

    test "Negativ: send_after MIT cancel_timer im File bleibt still" do
      """
      defmodule Worker.Foo do
        def tick(s) do
          if s.ref, do: Process.cancel_timer(s.ref)
          %{s | ref: Process.send_after(self(), :tick, 1000)}
        end
      end
      """
      |> to_source_file(@worker)
      |> run_check(TimerWithoutCleanup)
      |> refute_issues()
    end
  end

  describe "IgnoredIntentsPublish" do
    test "Positiv: bare publish als Nicht-letztes Statement" do
      """
      defmodule Worker.Foo do
        def go(id) do
          Worker.Intents.publish(%{"id" => id})
          :ok
        end
      end
      """
      |> to_source_file(@worker)
      |> run_check(IgnoredIntentsPublish)
      |> assert_issue(fn i -> assert i.trigger == "Worker.Intents.publish" end)
    end

    test "Negativ: gematcht / gepiped / als Return-Statement bleibt still" do
      """
      defmodule Worker.Foo do
        def a(id), do: {:ok, _} = Worker.Intents.publish(%{"id" => id})
        def b(id), do: %{"id" => id} |> Worker.Intents.publish()
        def c(id) do
          log(id)
          Worker.Intents.publish(%{"id" => id})
        end
      end
      """
      |> to_source_file(@worker)
      |> run_check(IgnoredIntentsPublish)
      |> refute_issues()
    end
  end
end
