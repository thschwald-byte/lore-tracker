defmodule Worker.VersionTest do
  use ExUnit.Case, async: true

  test "current/0 returns a map with vsn, sha, dirty?" do
    %{vsn: vsn, sha: sha, dirty?: dirty?} = Worker.Version.current()
    assert is_binary(vsn) and vsn != ""
    assert is_binary(sha) and sha != ""
    assert is_boolean(dirty?)
  end

  test "current/0 vsn matches mix.exs" do
    %{vsn: vsn} = Worker.Version.current()
    assert vsn == Mix.Project.config()[:version]
  end

  test "display/0 contains the mix.exs version" do
    display = Worker.Version.display()
    assert is_binary(display) and display != ""
    assert display =~ Mix.Project.config()[:version]
  end
end
