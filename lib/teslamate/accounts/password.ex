defmodule TeslaMate.Accounts.Password do
  @moduledoc false

  @algorithm "pbkdf2-sha256"
  @version 1
  @iterations 600_000
  @salt_bytes 16
  @digest_bytes 32

  @dummy_hash "$pbkdf2-sha256$v=1$i=600000$c2FsdHNhbHRzYWx0c2FsdA$X9jT0VTcxJxJwQoJk1rj7F2rWwzq8GppgV8G3xYFQsU"

  def hash(password) when is_binary(password) do
    salt = :crypto.strong_rand_bytes(@salt_bytes)
    digest = derive(password, salt, @iterations)

    Enum.join(
      [
        "$#{@algorithm}",
        "v=#{@version}",
        "i=#{@iterations}",
        encode(salt),
        encode(digest)
      ],
      "$"
    )
  end

  def verify(password, encoded) when is_binary(password) and is_binary(encoded) do
    with ["", @algorithm, "v=" <> version, "i=" <> iterations, salt64, digest64] <-
           String.split(encoded, "$"),
         {@version, ""} <- Integer.parse(version),
         {iterations, ""} when iterations >= 100_000 and iterations <= 2_000_000 <-
           Integer.parse(iterations),
         {:ok, salt} <- decode(salt64),
         {:ok, expected} <- decode(digest64),
         true <- byte_size(salt) >= 16,
         true <- byte_size(expected) == @digest_bytes do
      password
      |> derive(salt, iterations)
      |> Plug.Crypto.secure_compare(expected)
    else
      _ -> false
    end
  end

  def verify(_, _), do: false

  def no_user_verify(password) when is_binary(password), do: verify(password, @dummy_hash)
  def no_user_verify(_), do: false

  defp derive(password, salt, iterations) do
    :crypto.pbkdf2_hmac(:sha256, password, salt, iterations, @digest_bytes)
  end

  defp encode(binary), do: Base.url_encode64(binary, padding: false)
  defp decode(value), do: Base.url_decode64(value, padding: false)
end
