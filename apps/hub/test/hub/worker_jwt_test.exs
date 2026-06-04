defmodule Hub.WorkerJWTTest do
  use ExUnit.Case, async: false

  alias Hub.WorkerJWT

  setup do
    # Pro-Test eigenes Secret damit Tokens aus verschiedenen Tests sich
    # nicht versehentlich gegenseitig verifizieren. Reset über on_exit.
    secret = Base.encode64(:crypto.strong_rand_bytes(32))
    prev = Application.get_env(:hub, :jwt_secret)
    Application.put_env(:hub, :jwt_secret, secret)
    on_exit(fn -> Application.put_env(:hub, :jwt_secret, prev) end)
    :ok
  end

  test "sign_token + verify_token roundtrip" do
    token =
      WorkerJWT.sign_token(%{worker_id: "019e-abc", admin_discord_id: "615614311255244801"})

    assert {:ok, claims} = WorkerJWT.verify_token(token)
    assert claims["worker_id"] == "019e-abc"
    assert claims["admin_discord_id"] == "615614311255244801"
    assert claims["iss"] == "loretracker-hub"
    assert is_integer(claims["iat"])
    assert is_integer(claims["exp"])
    assert is_binary(claims["jti"])
  end

  test "verify rejects tampered token" do
    token =
      WorkerJWT.sign_token(%{worker_id: "019e-abc", admin_discord_id: "615614311255244801"})

    tampered = token <> "x"
    assert {:error, _} = WorkerJWT.verify_token(tampered)
  end

  test "verify rejects token signed with different secret" do
    token =
      WorkerJWT.sign_token(%{worker_id: "019e-abc", admin_discord_id: "615614311255244801"})

    # Secret rotieren — alte Tokens sind nun ungültig
    Application.put_env(:hub, :jwt_secret, Base.encode64(:crypto.strong_rand_bytes(32)))

    assert {:error, _} = WorkerJWT.verify_token(token)
  end

  test "verify rejects alg:none attack" do
    # Manually craft an unsigned token with alg:none header
    header_b64 =
      %{"alg" => "none", "typ" => "JWT"} |> Jason.encode!() |> Base.url_encode64(padding: false)

    payload_b64 =
      %{"worker_id" => "evil", "admin_discord_id" => "evil", "iss" => "loretracker-hub"}
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    none_token = header_b64 <> "." <> payload_b64 <> "."

    assert {:error, _} = WorkerJWT.verify_token(none_token)
  end

  test "verify rejects expired token" do
    secret = Application.get_env(:hub, :jwt_secret)
    signer = Joken.Signer.create("HS256", secret)

    # Generate a token with exp in the past
    past = System.system_time(:second) - 100

    claims = %{
      "worker_id" => "019e-abc",
      "admin_discord_id" => "615614311255244801",
      "iss" => "loretracker-hub",
      "iat" => past - 1,
      "exp" => past,
      "jti" => "test-jti"
    }

    {:ok, token, _claims} = Joken.encode_and_sign(claims, signer)

    assert {:error, _} = WorkerJWT.verify_token(token)
  end

  test "sign_token requires LORE_JWT_SECRET" do
    Application.put_env(:hub, :jwt_secret, nil)

    assert_raise RuntimeError, ~r/LORE_JWT_SECRET/, fn ->
      WorkerJWT.sign_token(%{worker_id: "x", admin_discord_id: "y"})
    end
  end

  # Issue #360: HS256 ist nur so stark wie sein Secret — ein zu kurzes Secret
  # schwächt die ganze Worker-Auth. Hard-fail statt stiller Schwächung.
  test "sign_token rejects a too-short LORE_JWT_SECRET (< 32 bytes)" do
    Application.put_env(:hub, :jwt_secret, "changeme")

    assert_raise RuntimeError, ~r/too short/, fn ->
      WorkerJWT.sign_token(%{worker_id: "x", admin_discord_id: "y"})
    end
  end

  test "verify_token rejects a too-short LORE_JWT_SECRET (< 32 bytes)" do
    Application.put_env(:hub, :jwt_secret, "short")

    assert_raise RuntimeError, ~r/too short/, fn ->
      WorkerJWT.verify_token("any.jwt.here")
    end
  end

  test "exactly 32 bytes is accepted" do
    Application.put_env(:hub, :jwt_secret, String.duplicate("a", 32))

    token = WorkerJWT.sign_token(%{worker_id: "w", admin_discord_id: "d"})
    assert {:ok, _claims} = WorkerJWT.verify_token(token)
  end
end
