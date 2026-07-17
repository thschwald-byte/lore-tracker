defmodule Hub.PromptPreviewPendingTest do
  @moduledoc """
  Issue #876 (Free-Tier-Guard): pending-Map-Hygiene von `Hub.PromptPreview` —
  analog `Hub.ReaderPendingTest` (400-MB-Pod, verwaiste pending-Einträge sind
  die Unbounded-RAM-Klasse). Callbacks direkt getrieben, CI-tauglich.
  """

  use ExUnit.Case, async: true

  alias Hub.PromptPreview

  defp entry do
    %{from: {self(), make_ref()}, timer: Process.send_after(self(), :never, 60_000)}
  end

  test "Response entfernt den pending-Eintrag und cancelt den Timer" do
    e = entry()
    {_pid, ref} = e.from
    segments = [%{"kind" => "locked", "text" => "…"}]

    {:noreply, state} =
      PromptPreview.handle_cast({:response, "rid-1", segments}, %{pending: %{"rid-1" => e}})

    assert state.pending == %{}
    assert Process.read_timer(e.timer) == false
    assert_receive {^ref, {:ok, ^segments}}
  end

  test "Late Response ist ein No-op — kein Geister-Eintrag, Bestand unberührt" do
    {:noreply, state} = PromptPreview.handle_cast({:response, "weg", []}, %{pending: %{}})
    assert state.pending == %{}

    other = entry()

    {:noreply, state2} =
      PromptPreview.handle_cast({:response, "weg", []}, %{pending: %{"anderer" => other}})

    assert Map.keys(state2.pending) == ["anderer"]
  end

  test "Timeout entfernt den Eintrag und antwortet {:error, :timeout}" do
    e = entry()
    {_pid, ref} = e.from

    {:noreply, state} =
      PromptPreview.handle_info({:timeout, "rid-t"}, %{pending: %{"rid-t" => e}})

    assert state.pending == %{}
    assert_receive {^ref, {:error, :timeout}}
  end

  test "Timeout auf unbekannte request_id ist ein No-op" do
    {:noreply, state} = PromptPreview.handle_info({:timeout, "weg"}, %{pending: %{}})
    assert state.pending == %{}
  end
end
