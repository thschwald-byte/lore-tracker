defmodule Hub.CloudKeysTest do
  @moduledoc """
  Issue #27: Cloud-API-Key-Storage roundtrip mit Cloak-Verschlüsselung.
  Mnesia-Adapter; nicht async wegen Singleton-Tabelle.
  """

  use ExUnit.Case, async: false

  setup do
    {:atomic, :ok} = :mnesia.clear_table(Hub.Storage.CloudKeys.Mnesia.table())
    :ok
  end

  test "put/get roundtrip — Klartext bleibt nicht auf disk" do
    :ok = Hub.CloudKeys.put("anthropic", "sk-ant-secret-12345", "user-1")

    # Direct disk-read sieht nur Ciphertext (kein "sk-ant-" Plaintext).
    [{_, "anthropic", ciphertext, _, _, "user-1"}] =
      :mnesia.dirty_read(Hub.Storage.CloudKeys.Mnesia.table(), "anthropic")

    refute ciphertext == "sk-ant-secret-12345"
    refute String.contains?(ciphertext, "sk-ant-")

    # get/1 dekriptiert wieder.
    assert {:ok, "sk-ant-secret-12345"} = Hub.CloudKeys.get("anthropic")
  end

  test "get/1 ohne hinterlegten Key → :error" do
    assert :error = Hub.CloudKeys.get("anthropic")
  end

  test "info/1 leakt den encrypted_key nicht" do
    :ok = Hub.CloudKeys.put("anthropic", "secret", nil)
    {:ok, meta} = Hub.CloudKeys.info("anthropic")

    refute Map.has_key?(meta, :encrypted_key)
    assert meta.provider == "anthropic"
  end

  test "delete/1 entfernt den Key" do
    :ok = Hub.CloudKeys.put("anthropic", "secret", nil)
    assert Hub.CloudKeys.configured?("anthropic")

    :ok = Hub.CloudKeys.delete("anthropic")
    refute Hub.CloudKeys.configured?("anthropic")
  end

  test "list_providers/0 zeigt alle Provider ohne Key-Daten" do
    :ok = Hub.CloudKeys.put("anthropic", "a", nil)
    :ok = Hub.CloudKeys.put("openai", "b", nil)

    list = Hub.CloudKeys.list_providers()
    assert length(list) == 2
    assert Enum.all?(list, fn p -> not Map.has_key?(p, :encrypted_key) end)
    assert Enum.map(list, & &1.provider) == ["anthropic", "openai"]
  end

  test "put/3 zweimal überschreibt + bumpt updated_at" do
    :ok = Hub.CloudKeys.put("anthropic", "first", "user-1")
    {:ok, first_meta} = Hub.CloudKeys.info("anthropic")

    # einen Tick warten damit updated_at messbar weiterläuft
    Process.sleep(2)
    :ok = Hub.CloudKeys.put("anthropic", "second", "user-2")
    {:ok, second_meta} = Hub.CloudKeys.info("anthropic")

    assert {:ok, "second"} = Hub.CloudKeys.get("anthropic")
    assert second_meta.created_at == first_meta.created_at
    assert DateTime.compare(second_meta.updated_at, first_meta.updated_at) == :gt
    assert second_meta.created_by_discord_id == "user-2"
  end
end
