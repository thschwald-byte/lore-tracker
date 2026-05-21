defmodule Hub.Vault do
  @moduledoc """
  AES-GCM-Vault für Cloud-API-Keys (Issue #27).

  Cloak-`Vault` mit AES-256-GCM. Master-Key kommt aus `LORE_CLOAK_KEY` (Base64-
  encoded, 32 Bytes). Ohne den ENV-Eintrag startet die Hub-App nicht, wenn
  irgendein Cloud-Backend aktiviert wurde — fail-loud statt silent-Klartext.

  Verwendung:

      ciphertext = Hub.Vault.encrypt!(plaintext_key)
      plaintext = Hub.Vault.decrypt!(ciphertext)

  Wird **nur** für `Hub.CloudKeys` benutzt — EventLog/Mnesia-Domain-Daten
  bleiben unverschlüsselt (das ist Klartext-by-design, event-sourced + replay-
  fähig).
  """

  use Cloak.Vault, otp_app: :hub

  @doc """
  Vault-Init: zieht den Master-Key aus `LORE_CLOAK_KEY` (Base64) und
  konfiguriert AES.GCM als Default-Cipher. Wenn der ENV fehlt, läuft der
  Vault mit einem ephemeren In-Memory-Key — nur sinnvoll für `:test`/`:dev`,
  in `:prod` brüllt `Hub.CloudKeys.put/3` los wenn nichts persistiert wird.
  """
  @impl GenServer
  def init(config) do
    key =
      case System.get_env("LORE_CLOAK_KEY") do
        nil -> :crypto.strong_rand_bytes(32)
        encoded -> Base.decode64!(encoded)
      end

    config =
      Keyword.put(config, :ciphers,
        default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: key}
      )

    {:ok, config}
  end
end
