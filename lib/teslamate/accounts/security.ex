defmodule TeslaMate.Accounts.Security do
  @moduledoc "Session-bound TOTP enrollment, single-use challenges and recovery codes."
  import Ecto.Query
  alias TeslaMate.{Accounts, Repo}
  alias TeslaMate.Accounts.{Authenticator, LoginChallenge, Password, User}

  @window 600
  @attempt_limit 5

  def enabled?(%User{id: id}) do
    Repo.exists?(from a in Authenticator, where: a.user_id == ^id and not is_nil(a.enabled_at))
  end

  def status(user, token) do
    case Repo.get(Authenticator, user.id) do
      nil ->
        %{enabled?: false, recovery_count: 0, setup_key: nil}

      a ->
        %{
          enabled?: not is_nil(a.enabled_at),
          recovery_count: length(a.recovery_hashes),
          setup_key: if(pending?(a, token), do: Base.encode32(a.pending_secret, padding: false))
        }
    end
  end

  def begin_enrollment(user, token, password) do
    transaction(fn ->
      current = lock_user(user)
      a = lock_authenticator(current)

      cond do
        not current_session?(current, token) ->
          {:error, :forbidden}

        a.enabled_at != nil ->
          {:error, :already_enabled}

        not available?(a) ->
          {:error, :rate_limited}

        not verify_password(current, password) ->
          fail(a)

        true ->
          a =
            update(a, %{
              pending_secret: NimbleTOTP.secret(),
              pending_session_hash: hash(token),
              pending_expires_at: DateTime.add(now(), @window),
              failed_attempts: 0,
              attempt_window_at: now()
            })

          {:ok, Base.encode32(a.pending_secret, padding: false)}
      end
    end)
  end

  def enable(user, token, code, metadata \\ %{}) do
    transaction(fn ->
      current = lock_user(user)
      a = lock_authenticator(current)

      cond do
        not current_session?(current, token) ->
          {:error, :forbidden}

        a.enabled_at != nil or not pending?(a, token) ->
          {:error, :setup_expired}

        not available?(a) ->
          {:error, :rate_limited}

        true ->
          case matching_step(a.pending_secret, code, nil) do
            nil ->
              fail(a)

            step ->
              codes = recovery_codes()

              update(a, %{
                secret: a.pending_secret,
                enabled_at: now(),
                last_used_step: step,
                recovery_hashes: Enum.map(codes, &recovery_hash/1),
                pending_secret: nil,
                pending_session_hash: nil,
                pending_expires_at: nil,
                failed_attempts: 0,
                attempt_window_at: now()
              })

              {:ok, token} = rotate_sessions(current, metadata)
              {:ok, codes, token}
          end
      end
    end)
  end

  def disable(user, token, password, code, metadata \\ %{}) do
    manage(user, token, password, code, metadata, :disable)
  end

  def regenerate_recovery_codes(user, token, password, code, metadata \\ %{}) do
    manage(user, token, password, code, metadata, :recovery)
  end

  defp manage(user, token, password, code, metadata, action) do
    transaction(fn ->
      current = lock_user(user)
      a = lock_authenticator(current)

      cond do
        not current_session?(current, token) ->
          {:error, :forbidden}

        a.enabled_at == nil ->
          {:error, :not_enabled}

        not available?(a) ->
          {:error, :rate_limited}

        not verify_password(current, password) ->
          fail(a)

        true ->
          case consume_factor(a, code) do
            {:ok, a} ->
              codes = if action == :recovery, do: recovery_codes(), else: []

              changes =
                if action == :disable do
                  %{
                    secret: nil,
                    enabled_at: nil,
                    last_used_step: nil,
                    recovery_hashes: [],
                    pending_secret: nil,
                    pending_session_hash: nil,
                    pending_expires_at: nil
                  }
                else
                  %{recovery_hashes: Enum.map(codes, &recovery_hash/1)}
                end

              update(a, changes)
              {:ok, new_token} = rotate_sessions(current, metadata)
              {:ok, codes, new_token}

            error ->
              error
          end
      end
    end)
  end

  def authorize_password_change(user, token, password, code) do
    transaction(fn ->
      current = lock_user(user)
      a = lock_authenticator(current)

      cond do
        not current_session?(current, token) ->
          {:error, :forbidden}

        not available?(a) ->
          {:error, :rate_limited}

        not verify_password(current, password) ->
          fail(a)

        is_nil(a.enabled_at) ->
          :ok

        true ->
          case consume_factor(a, code) do
            {:ok, _} -> :ok
            error -> error
          end
      end
    end)
  end

  def create_challenge(%User{} = user) do
    transaction(fn ->
      current = lock_user(user)

      if current.auth_version != user.auth_version or not enabled?(current) do
        {:error, :invalid_challenge}
      else
        token = random_token()
        Repo.delete_all(from c in LoginChallenge, where: c.expires_at <= ^now())

        Repo.insert!(%LoginChallenge{
          token_hash: hash(token),
          user_id: current.id,
          auth_version: current.auth_version,
          expires_at: DateTime.add(now(), 300)
        })

        {:ok, token}
      end
    end)
  end

  def challenge_user(token) when is_binary(token) and byte_size(token) <= 128 do
    Repo.one(
      from c in LoginChallenge,
        join: u in User,
        on: u.id == c.user_id,
        where:
          c.token_hash == ^hash(token) and c.expires_at > ^now() and
            c.attempts < ^@attempt_limit and u.status == :active and
            c.auth_version == u.auth_version,
        select: u
    )
  end

  def challenge_user(_), do: nil

  def complete_challenge(token, code, metadata \\ %{}) do
    case challenge_user(token) do
      nil ->
        {:error, :invalid_challenge}

      user ->
        transaction(fn ->
          current = lock_user(user)
          challenge = Repo.get(LoginChallenge, hash(token))
          a = lock_authenticator(current)

          cond do
            is_nil(challenge) or challenge.auth_version != current.auth_version or
              DateTime.compare(challenge.expires_at, now()) != :gt or
                challenge.attempts >= @attempt_limit ->
              {:error, :invalid_challenge}

            is_nil(a.enabled_at) ->
              {:error, :invalid_challenge}

            not available?(a) ->
              {:error, :rate_limited}

            true ->
              case consume_factor(a, code) do
                {:ok, _} ->
                  Repo.delete!(challenge)
                  {:ok, session} = Accounts.create_session(current, metadata)
                  {:ok, current, session}

                error ->
                  challenge
                  |> Ecto.Changeset.change(attempts: challenge.attempts + 1)
                  |> Repo.update!()

                  error
              end
          end
        end)
    end
  end

  defp consume_factor(a, code) do
    case matching_step(a.secret, code, a.last_used_step) do
      step when is_integer(step) ->
        {:ok, update(a, %{last_used_step: step, failed_attempts: 0, attempt_window_at: now()})}

      nil ->
        value = if is_binary(code), do: recovery_hash(code), else: <<>>
        used = Enum.find(a.recovery_hashes, &Plug.Crypto.secure_compare(&1, value))

        if used do
          {:ok,
           update(a, %{
             recovery_hashes: List.delete(a.recovery_hashes, used),
             failed_attempts: 0,
             attempt_window_at: now()
           })}
        else
          fail(a)
        end
    end
  end

  defp matching_step(secret, code, last) when is_binary(secret) and is_binary(code) do
    if Regex.match?(~r/^[0-9]{6}$/, code) do
      step = div(System.system_time(:second), 30)

      Enum.find([step, step - 1], fn candidate ->
        (is_nil(last) or candidate > last) and
          NimbleTOTP.valid?(secret, code, time: candidate * 30)
      end)
    end
  end

  defp matching_step(_, _, _), do: nil

  defp available?(a), do: expired_window?(a) or a.failed_attempts < @attempt_limit
  defp expired_window?(%{attempt_window_at: nil}), do: true
  defp expired_window?(a), do: DateTime.diff(now(), a.attempt_window_at) >= @window

  defp fail(a) do
    changes =
      if expired_window?(a),
        do: %{failed_attempts: 1, attempt_window_at: now()},
        else: %{failed_attempts: a.failed_attempts + 1}

    update(a, changes)
    {:error, :invalid_verification}
  end

  defp pending?(a, token) do
    is_binary(token) and is_binary(a.pending_secret) and is_binary(a.pending_session_hash) and
      a.pending_expires_at != nil and DateTime.compare(a.pending_expires_at, now()) == :gt and
      Plug.Crypto.secure_compare(a.pending_session_hash, hash(token))
  end

  defp current_session?(user, token) do
    case Accounts.get_user_by_session_token(token) do
      %User{id: id} -> id == user.id
      _ -> false
    end
  end

  defp lock_user(user) do
    case Repo.one(from u in User, where: u.id == ^user.id, lock: "FOR UPDATE") do
      %User{status: :active} = current -> current
      _ -> Repo.rollback(:forbidden)
    end
  end

  defp lock_authenticator(user) do
    Repo.get(Authenticator, user.id) || Repo.insert!(%Authenticator{user_id: user.id})
  end

  defp rotate_sessions(user, metadata) do
    current = user |> Ecto.Changeset.change(auth_version: user.auth_version + 1) |> Repo.update!()
    Accounts.delete_user_sessions(current)
    Repo.delete_all(from c in LoginChallenge, where: c.user_id == ^user.id)
    Accounts.create_session(current, metadata)
  end

  defp verify_password(user, password) when is_binary(password),
    do: Password.verify(password, user.password_hash)

  defp verify_password(_, _), do: false

  defp recovery_codes,
    do: for(_ <- 1..10, do: :crypto.strong_rand_bytes(10) |> Base.encode16(case: :lower))

  defp recovery_hash(code), do: code |> String.trim() |> String.downcase() |> hash()
  defp random_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  defp hash(value), do: :crypto.hash(:sha256, value)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp update(record, attrs), do: record |> Ecto.Changeset.change(attrs) |> Repo.update!()

  defp transaction(fun) do
    case Repo.transaction(fun) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end
end
