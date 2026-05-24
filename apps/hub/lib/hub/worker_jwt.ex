defmodule Hub.WorkerJWT do
  @moduledoc """
  RFC 7519 JWT für stateless Worker-Pairing (Issue #160, Etappe 5a).

  Algorithmus HS256 (HMAC-SHA256) gegen `LORE_JWT_SECRET`. Joken
  validiert beim Verify, dass der `alg`-Header zum Signer passt —
  die `alg: none`-CVE ist damit ausgeschlossen.

  Custom-Claims:
  - `worker_id` (UUID string)
  - `admin_discord_id` (Discord snowflake string)

  Standard-Claims (von Joken automatisch):
  - `iat` (issued-at)
  - `exp` (expires-at, default: 1 Jahr)
  - `iss` (issuer = "loretracker-hub")
  - `jti` (token-id, für künftige Revocation-Logging)

  Token-Header trägt: `{"alg":"HS256","typ":"JWT"}`.

  Revocation: keine Liste. Bei Worker-Kompromittierung wird
  `LORE_JWT_SECRET` rotiert — alle Worker müssen einmal neu pairen.
  Bei Self-Hosted-Setups mit <10 Workern akzeptabler Trade-off.
  """

  use Joken.Config

  @one_year_seconds 60 * 60 * 24 * 365

  @impl Joken.Config
  def token_config do
    default_claims(
      default_exp: @one_year_seconds,
      iss: "loretracker-hub",
      skip: [:aud, :nbf]
    )
    |> add_claim("worker_id", nil, &is_binary/1)
    |> add_claim("admin_discord_id", nil, &is_binary/1)
  end

  # Funktionsnamen sign_token/verify_token statt sign/verify — der `use
  # Joken.Config` definiert sign/1, verify/1, validate/1 etc. mit default-
  # Signer-Lookup, die hätten unsere Klauseln verschattet (Warning + Bug).
  @spec sign_token(%{worker_id: String.t(), admin_discord_id: String.t()}) :: String.t()
  def sign_token(%{worker_id: worker_id, admin_discord_id: admin_discord_id})
      when is_binary(worker_id) and is_binary(admin_discord_id) do
    generate_and_sign!(
      %{"worker_id" => worker_id, "admin_discord_id" => admin_discord_id},
      signer()
    )
  end

  @spec verify_token(String.t()) :: {:ok, map()} | {:error, term()}
  def verify_token(token) when is_binary(token) do
    verify_and_validate(token, signer())
  end

  defp signer do
    # Wir lesen aus :hub-App-Env, nicht direkt System.get_env — dotenvy
    # schreibt nicht ins OS-Env (siehe runtime.exs), die App-Env ist der
    # konsistente Pfad. In runtime.exs erzwungen via env!/2.
    secret =
      Application.get_env(:hub, :jwt_secret) ||
        raise "LORE_JWT_SECRET environment variable not set (config :hub, :jwt_secret)"

    Joken.Signer.create("HS256", secret)
  end
end
