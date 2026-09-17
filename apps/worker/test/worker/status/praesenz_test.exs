defmodule Worker.Status.PraesenzTest do
  @moduledoc """
  Issue #1218, Schnitt 2: der Präsenz-Zwischenspeicher.

  Drei Zusagen werden hier festgenagelt, und jede hat einen Grund:
  die Discord-Kennung verlässt den Worker nie, die Kennung bleibt innerhalb
  eines Laufs stabil (sonst springt die Anzeige), und ein Stand verfällt
  (sonst zeigt die Anzeige Leute, die längst gegangen sind).
  """
  use ExUnit.Case, async: false

  alias Worker.Status.Praesenz

  @did "615614311255244801"

  setup do
    unless Process.whereis(Praesenz), do: start_supervised!(Praesenz)
    :ets.match_delete(:worker_status_praesenz, {{:sitzung, :_}, :_, :_})
    :ok
  end

  defp stand(opts \\ []) do
    [
      %{
        "discord_id" => @did,
        "speaking" => Keyword.get(opts, :spricht, true),
        "consent" => Keyword.get(opts, :zustimmung, true)
      }
    ]
  end

  describe "melden und lesen" do
    test "der gemeldete Stand kommt pseudonymisiert zurück" do
      :ok = Praesenz.melden("s1", stand(), 1000)

      assert [%{"id" => id, "spricht" => true, "zustimmung" => true}] = Praesenz.lesen(1000)
      assert is_binary(id) and byte_size(id) == 8
    end

    test "die Discord-Kennung taucht nirgends auf" do
      :ok = Praesenz.melden("s1", stand(), 1000)
      json = Jason.encode!(Praesenz.lesen(1000))

      refute json =~ @did
      refute json =~ "discord"
    end

    test "fehlende Zustimmung bleibt sichtbar — sie ist nicht Stille" do
      :ok = Praesenz.melden("s1", stand(spricht: false, zustimmung: false), 1000)
      assert [%{"spricht" => false, "zustimmung" => false}] = Praesenz.lesen(1000)
    end

    test "mehrere Sitzungen kommen zusammen, jede Kennung nur einmal" do
      :ok = Praesenz.melden("s1", stand(), 1000)
      :ok = Praesenz.melden("s2", stand(), 1000)

      assert [_einer] = Praesenz.lesen(1000)
    end
  end

  describe "die Kennung" do
    test "ist innerhalb eines Laufs stabil — sonst springt die Anzeige" do
      assert Praesenz.pseudonym(@did) == Praesenz.pseudonym(@did)
    end

    test "unterscheidet zwei Personen" do
      refute Praesenz.pseudonym(@did) == Praesenz.pseudonym("999")
    end

    test "ist nicht die Kennung und nicht ihr nackter Hash" do
      p = Praesenz.pseudonym(@did)
      nackt = :sha256 |> :crypto.hash(@did) |> Base.encode16(case: :lower) |> binary_part(0, 8)

      refute p == @did
      refute p == nackt, "ohne Salz wäre der Hash nur eine andere Schreibweise der Kennung"
    end
  end

  describe "Alter" do
    test "ein veralteter Stand fällt heraus" do
      :ok = Praesenz.melden("s1", stand(), 1000)

      assert Praesenz.lesen(1000 + Praesenz.frist_ms()) != []
      assert Praesenz.lesen(1000 + Praesenz.frist_ms() + 1) == []
    end
  end

  describe "ohne laufenden Prozess" do
    test "stört der Statusdienst die Aufnahme nicht" do
      # Die Aufnahme meldet auch dann, wenn es den Zwischenspeicher nicht gibt
      # (nicht gepaarter Worker). Sie darf daran nicht scheitern.
      :ok = stop_supervised(Praesenz)
      assert :ok = Praesenz.melden("s1", stand(), 1000)
      assert Praesenz.lesen(1000) == []
      assert Praesenz.pseudonym(@did) == nil
    end
  end
end
