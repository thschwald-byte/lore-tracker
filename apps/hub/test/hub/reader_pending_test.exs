defmodule Hub.ReaderPendingTest do
  @moduledoc """
  Issue #876 (Free-Tier-Guard): pending-Map-Hygiene von `Hub.Reader`.

  Der Hub läuft auf einem 400-MB-Free-Tier-Pod — die `pending`-Map ist einer
  der wenigen Hub-States, die bei einem Cleanup-Regressions-Bug unbounded
  wachsen (jeder verwaiste Eintrag hält from-Ref + Scope + Worker-Restliste
  bis zum OOMKill). Diese Tests nageln die drei Aufräum-Pfade fest, indem sie
  die GenServer-Callbacks direkt treiben (kein Tracker/Worker-Pool nötig —
  anders als der `:integration`-getaggte reader_test.exs laufen sie in CI).
  """

  use ExUnit.Case, async: true

  alias Hub.Reader

  defp entry(overrides \\ %{}) do
    Map.merge(
      %{
        from: {self(), make_ref()},
        remaining: [],
        scope: %{"kind" => "campaign", "id" => "c-1"},
        timer: Process.send_after(self(), :never, 60_000),
        attempts_left: 0
      },
      overrides
    )
  end

  test "Response entfernt den pending-Eintrag und cancelt den Timer" do
    e = entry()
    {pid, ref} = e.from
    assert pid == self()

    {:noreply, state} =
      Reader.handle_cast({:response, "rid-1", %{"campaign" => %{}}}, %{
        pending: %{"rid-1" => e}
      })

    assert state.pending == %{}
    # Timer gecancelt — sonst leakt pro Read ein aktiver Timer-Ref.
    assert Process.read_timer(e.timer) == false
    assert_receive {^ref, {:ok, %{"campaign" => %{}}}}
  end

  test "Late Response (nach Timeout/Abschluss) ist ein No-op — kein Geister-Eintrag" do
    {:noreply, state} = Reader.handle_cast({:response, "unbekannt", %{}}, %{pending: %{}})
    assert state.pending == %{}

    # Auch mit fremdem Bestand: nur ein Drop, kein Wachstum, Bestand unberührt.
    other = entry()

    {:noreply, state2} =
      Reader.handle_cast({:response, "unbekannt", %{}}, %{pending: %{"anderer" => other}})

    assert Map.keys(state2.pending) == ["anderer"]
  end

  test "finaler Timeout (keine Versuche mehr) entfernt den Eintrag und antwortet Fehler" do
    e = entry(%{attempts_left: 0, remaining: []})
    {_pid, ref} = e.from

    {:noreply, state} = Reader.handle_info({:timeout, "rid-t"}, %{pending: %{"rid-t" => e}})

    assert state.pending == %{}
    assert_receive {^ref, {:error, :timeout}}
  end

  test "Timeout auf unbekannte request_id ist ein No-op" do
    {:noreply, state} = Reader.handle_info({:timeout, "weg"}, %{pending: %{}})
    assert state.pending == %{}
  end

  test "Retry hält die pending-Größe konstant bei 1 (alte rid raus, neue rein)" do
    # Der Leak-kritische Pfad: retryable Response mit verbleibenden Workern
    # erzeugt einen NEUEN Eintrag — der alte muss dabei verschwinden, sonst
    # wächst die Map pro Retry-Hop.
    e =
      entry(%{
        attempts_left: 2,
        remaining: [{"w2", %{channel_pid: self()}}]
      })

    {:noreply, state} =
      Reader.handle_cast({:response, "rid-alt", %{"forbidden" => true}}, %{
        pending: %{"rid-alt" => e}
      })

    assert map_size(state.pending) == 1
    [new_rid] = Map.keys(state.pending)
    refute new_rid == "rid-alt"
    # Der nächste Worker wurde tatsächlich angesprochen (channel_pid = self()).
    assert_receive {:snapshot_request, %{"kind" => "campaign"}, ^new_rid, _reader_pid}
    # Verbrauchter Versuch + geschrumpfte Restliste — der Retry konvergiert.
    assert state.pending[new_rid].attempts_left == 1
    assert state.pending[new_rid].remaining == []
  end

  test "Timeout mit verbleibenden Workern retried ebenfalls größen-konstant" do
    e =
      entry(%{
        attempts_left: 1,
        remaining: [{"w2", %{channel_pid: self()}}]
      })

    {:noreply, state} = Reader.handle_info({:timeout, "rid-alt"}, %{pending: %{"rid-alt" => e}})

    assert map_size(state.pending) == 1
    refute Map.has_key?(state.pending, "rid-alt")
  end
end
