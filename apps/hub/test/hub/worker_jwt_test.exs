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
end
