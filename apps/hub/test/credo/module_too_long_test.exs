Code.require_file(Path.expand("../../../../tools/credo/module_too_long.ex", __DIR__))

{:ok, _} = Application.ensure_all_started(:credo)

defmodule LoreTracker.Credo.Check.ModuleTooLongTest do
  @moduledoc "Issue #544: God-Module-Check (#544-Headline). Threshold via :max_lines-Param testbar."
  use Credo.Test.Case

  alias LoreTracker.Credo.Check.ModuleTooLong

  @src "apps/worker/lib/worker/foo.ex"

  defp source(n_lines) do
    body = Enum.map_join(1..n_lines, "\n", fn i -> "  def f#{i}, do: #{i}" end)
    "defmodule Worker.Foo do\n#{body}\nend\n"
  end

  test "Positiv: File über :max_lines wird geflaggt" do
    source(30)
    |> to_source_file(@src)
    |> run_check(ModuleTooLong, max_lines: 10)
    |> assert_issue(fn i -> assert i.trigger == "defmodule" end)
  end

  test "Negativ: File unter :max_lines bleibt still" do
    source(5)
    |> to_source_file(@src)
    |> run_check(ModuleTooLong, max_lines: 10)
    |> refute_issues()
  end

  test "Default-Threshold 1000: ein kleines File bleibt still" do
    source(20)
    |> to_source_file(@src)
    |> run_check(ModuleTooLong)
    |> refute_issues()
  end
end
