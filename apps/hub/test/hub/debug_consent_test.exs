defmodule Hub.DebugConsentTest do
  @moduledoc """
  Issue #144: ETS-backed Debug-Consent — grant/valid?/revoke + Auto-Expire +
  PubSub-Broadcasts.
  """

  use ExUnit.Case, async: false

  alias Hub.DebugConsent

  @did "user-debug-test"

  setup do
    # DebugConsent läuft als named GenServer im Hub.Application. Im Test
    # nehmen wir die existierende Instanz an (vom Hub.Application-Start)
    # und säubern den State pro Test via revoke.
    pid =
      case Process.whereis(DebugConsent) do
        nil ->
          {:ok, pid} = DebugConsent.start_link([])
          pid

        pid ->
          pid
      end

    on_exit(fn ->
      if Process.alive?(pid) and Process.whereis(DebugConsent) == pid do
        # Cleanup: alle Test-grants entfernen
        DebugConsent.revoke(@did)
      end
    end)

    Phoenix.PubSub.subscribe(Hub.PubSub, DebugConsent.topic())
    :ok
  end

  test "grant macht valid?/1 true; status/1 liefert expires_at" do
    refute DebugConsent.valid?(@did)
    assert :ok = DebugConsent.grant(@did, 60)
    assert DebugConsent.valid?(@did)

    assert %{expires_at: %DateTime{} = at} = DebugConsent.status(@did)
    assert DateTime.compare(at, DateTime.utc_now()) == :gt
  end

  test "revoke macht valid?/1 false sofort" do
    DebugConsent.grant(@did, 60)
    assert DebugConsent.valid?(@did)

    assert :ok = DebugConsent.revoke(@did)
    refute DebugConsent.valid?(@did)
    refute DebugConsent.status(@did)
  end

  test "broadcastet :granted und :revoked auf debug_consent-Topic" do
    DebugConsent.grant(@did, 60)
    assert_receive {:granted, @did, %DateTime{}}, 1_000

    DebugConsent.revoke(@did)
    assert_receive {:revoked, @did}, 1_000
  end

  test "zweiter grant überschreibt + cancelt den alten Timer" do
    DebugConsent.grant(@did, 60)
    assert %{expires_at: at1} = DebugConsent.status(@did)

    Process.sleep(50)

    DebugConsent.grant(@did, 300)
    assert %{expires_at: at2} = DebugConsent.status(@did)

    assert DateTime.compare(at2, at1) == :gt
  end

  test "Auto-Expire feuert :expired-Broadcast und macht valid? false" do
    # 1-sekunden-grant
    DebugConsent.grant(@did, 1)
    assert DebugConsent.valid?(@did)

    # Auf den Expire-Broadcast warten — generös 2s Timeout
    assert_receive {:expired, @did}, 2_000
    refute DebugConsent.valid?(@did)
  end

  test "valid?/1 returnt false wenn expires_at in der Vergangenheit liegt" do
    # ETS-direktes Manipulieren um eine vergangene Ablaufzeit zu simulieren
    # ohne 1s Test-Sleep — Sanity-Check der valid?/1-Logik.
    past = DateTime.utc_now() |> DateTime.add(-10, :second)
    :ets.insert(:hub_debug_consent, {@did, past})

    refute DebugConsent.valid?(@did)
    refute DebugConsent.status(@did)
  end
end
