# Issue #544: der Custom-Check liegt unter tools/ (via .credo.exs `requires:`,
# nicht app-kompiliert) → für den Test explizit laden.
Code.require_file(Path.expand("../../../../tools/credo/sync_reader_in_mount.ex", __DIR__))

# credo ist `runtime: false` → seine Services (SourceFileAST-Cache etc.) starten
# nicht automatisch. Credo.Test.Case braucht sie → hier explizit hochfahren.
{:ok, _} = Application.ensure_all_started(:credo)

defmodule LoreTracker.Credo.Check.SyncReaderInMountTest do
  @moduledoc """
  Issue #544 / #557-Lesson #2: jede historische FP-Klasse wird ein
  „war-rot/bleibt-grün"-`refute_issues`-Fixture. Die Negativ-Fälle sind genau
  die, die der sync_reader-Check NIE wieder flaggen darf — inkl. der multi-line-
  und piped-Formen, die die same-line-Regex (#549) strukturell nicht erkennt.
  """
  use Credo.Test.Case

  alias LoreTracker.Credo.Check.SyncReaderInMount

  @live "apps/hub/lib/hub_web/live/foo_live.ex"

  describe "Positiv — echte sync Reads werden geflaggt" do
    test "bare Reader.read im LiveView" do
      """
      defmodule HubWeb.FooLive do
        def mount(_p, _s, socket), do: {:ok, apply_snapshot(socket, Reader.read(scope(socket)))}
      end
      """
      |> to_source_file(@live)
      |> run_check(SyncReaderInMount)
      |> assert_issue(fn issue -> assert issue.trigger == "Reader.read" end)
    end
  end

  describe "Negativ — async-gewrappte Reads bleiben still (historische FPs)" do
    test "#535: start_async single-line (der Original-FP)" do
      """
      defmodule HubWeb.FooLive do
        def handle_info(_m, socket) do
          {:noreply, start_async(socket, :reload, fn -> Reader.read(scope(socket)) end)}
        end
      end
      """
      |> to_source_file(@live)
      |> run_check(SyncReaderInMount)
      |> refute_issues()
    end

    test "multi-line: Reader.read in anderer Zeile als start_async (Regex-blind)" do
      """
      defmodule HubWeb.FooLive do
        def handle_info(_m, socket) do
          start_async(socket, :reload, fn ->
            s = scope(socket)
            Reader.read(s)
          end)
        end
      end
      """
      |> to_source_file(@live)
      |> run_check(SyncReaderInMount)
      |> refute_issues()
    end

    test "piped: scope |> Reader.read() in start_async (andere AST-Arity)" do
      """
      defmodule HubWeb.FooLive do
        def handle_info(_m, socket) do
          start_async(socket, :reload, fn -> socket |> scope() |> Reader.read() end)
        end
      end
      """
      |> to_source_file(@live)
      |> run_check(SyncReaderInMount)
      |> refute_issues()
    end

    test "assign_async / Task.start wrappen ebenfalls" do
      """
      defmodule HubWeb.FooLive do
        def mount(_p, _s, socket) do
          socket = assign_async(socket, :a, fn -> {:ok, %{a: Reader.read(x())}} end)
          Task.start(fn -> Reader.read(y()) end)
          {:ok, socket}
        end
      end
      """
      |> to_source_file(@live)
      |> run_check(SyncReaderInMount)
      |> refute_issues()
    end
  end

  describe "Scope — nur LiveView-Schicht" do
    test "bare Reader.read außerhalb /hub_web/live/ wird ignoriert" do
      """
      defmodule Worker.Foo do
        def go(scope), do: Reader.read(scope)
      end
      """
      |> to_source_file("apps/worker/lib/worker/foo.ex")
      |> run_check(SyncReaderInMount)
      |> refute_issues()
    end
  end
end
