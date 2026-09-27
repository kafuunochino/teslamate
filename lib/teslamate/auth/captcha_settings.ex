defmodule TeslaMate.Auth.CaptchaSettings.Record do
  use Ecto.Schema

  @schema_prefix "private"
  @primary_key {:id, :integer, autogenerate: false}
  schema "captcha_settings" do
    field :provider, :string
    field :profiles, TeslaMate.Vault.Encrypted.Binary, redact: true
    field :revision, :integer, default: 0
    timestamps()
  end
end

defmodule TeslaMate.Auth.CaptchaSettings do
  @moduledoc "Encrypted provider profiles. Only a verified draft can replace a saved profile."
  import Ecto.Query
  alias TeslaMate.{Accounts, Repo}
  alias TeslaMate.Accounts.User
  alias TeslaMate.Auth.{Captcha, CaptchaSettings.Record}
  alias TeslaMateWeb.{Config, Endpoint}

  @salt "captcha-configuration-v1"
  @providers ~w(cloudflare aliyun tencent)
  @public %{
    "cloudflare" => ~w(site_key hostnames),
    "aliyun" => ~w(region prefix scene_id),
    "tencent" => ~w(app_id)
  }
  @secrets %{
    "cloudflare" => ~w(secret_key),
    "aliyun" => ~w(access_key_id access_key_secret),
    "tencent" => ~w(app_secret_key secret_id secret_key)
  }

  def providers, do: @providers
  def label("cloudflare"), do: "Cloudflare Turnstile"
  def label("aliyun"), do: "阿里云验证码 2.0"
  def label("tencent"), do: "腾讯云验证码 2.0"
  def label(_), do: "未启用"

  def active do
    record = Repo.get!(Record, 1)
    provider = record.provider || if(Config.turnstile_enabled?(), do: "cloudflare")
    %{provider: provider, config: profile(record, provider), revision: record.revision}
  end

  def public_config(%{provider: provider, config: config, revision: revision}) do
    %{provider: provider, config: Map.take(config, Map.get(@public, provider, [])), revision: revision}
  end

  def preferences do
    record = Repo.get!(Record, 1)

    profiles = Map.new(@providers, fn provider ->
      config = profile(record, provider)
      {provider, %{
        values: Map.take(config, @public[provider]),
        secrets: Map.new(@secrets[provider], &{&1, present?(config[&1])}),
        saved: configured?(provider, config)
      }}
    end)

    %{provider: record.provider || if(Config.turnstile_enabled?(), do: "cloudflare"), profiles: profiles}
  end

  def configured?(provider, config) when provider in @providers do
    Enum.all?(@public[provider] ++ @secrets[provider], &present?(config[&1]))
  end
  def configured?(_, _), do: false

  # The browser receives only an authenticated, encrypted, short-lived draft.
  # Nothing is saved or activated until the actual provider accepts a challenge.
  def prepare(%User{id: id}, attrs) when is_map(attrs) do
    with :ok <- authorize(id),
         provider when provider in @providers <- attrs["provider"],
         record <- Repo.get!(Record, 1),
         {:ok, config} <- candidate(provider, profile(record, provider), attrs) do
      if config == profile(record, provider) and configured?(provider, config) do
        persist(id, provider, config, record.revision)
      else
        token = Phoenix.Token.encrypt(Endpoint, @salt, %{
          user_id: id, provider: provider, config: config, revision: record.revision
        })
        {:verify, token}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :configuration}
    end
  end
  def prepare(_, _), do: {:error, :forbidden}

  def draft(%User{id: id}, token) when is_binary(token) and byte_size(token) < 16_384 do
    with :ok <- authorize(id),
         {:ok, %{user_id: ^id} = draft} <- Phoenix.Token.decrypt(Endpoint, @salt, token, max_age: 600),
         %{revision: revision} <- Repo.get!(Record, 1),
         true <- revision == draft.revision do
      {:ok, draft}
    else
      _ -> {:error, :expired}
    end
  end
  def draft(_, _), do: {:error, :expired}

  def verify_and_save(user, token, params, ip) do
    with {:ok, draft} <- draft(user, token),
         :ok <- Captcha.verify(draft, params, ip, "settings") do
      persist(user.id, draft.provider, draft.config, draft.revision)
    end
  end

  defp persist(id, provider, config, revision) do
    Repo.transaction(fn ->
      with :ok <- authorize(id),
           record <- Repo.one!(from s in Record, where: s.id == 1, lock: "FOR UPDATE"),
           true <- record.revision == revision do
        # Capture legacy CF credentials too, so switching back does not depend
        # on subsequently changing container environment variables.
        profiles = decoded(record)
        legacy = profile(record, "cloudflare")
        profiles = if configured?("cloudflare", legacy),
          do: Map.put_new(profiles, "cloudflare", legacy), else: profiles

        record
        |> Ecto.Changeset.change(provider: provider,
          profiles: Jason.encode!(Map.put(profiles, provider, config)), revision: revision + 1)
        |> Repo.update!()
        :saved
      else
        {:error, reason} -> Repo.rollback(reason)
        _ -> Repo.rollback(:expired)
      end
    end)
  end

  defp candidate(provider, previous, attrs) do
    keys = @public[provider] ++ @secrets[provider]
    config = Enum.reduce(keys, previous, fn key, acc ->
      case attrs[key] do
        value when is_binary(value) ->
          case String.trim(value) do
            "" -> acc
            trimmed -> Map.put(acc, key, trimmed)
          end
        nil -> acc
        _ -> Map.put(acc, key, nil)
      end
    end)
    config = if provider == "aliyun", do: Map.put_new(config, "region", "cn"), else: config
    config = if provider == "cloudflare" and is_binary(config["hostnames"]),
      do: Map.update!(config, "hostnames", &normalize_hosts/1), else: config

    if configured?(provider, config) and Enum.all?(config, fn {key, value} ->
         is_binary(value) and byte_size(value) <= 1024 and valid_field?(key, value)
       end), do: {:ok, Map.take(config, keys)}, else: {:error, :configuration}
  end

  defp valid_field?("region", value), do: value in ["cn", "sgp"]
  defp valid_field?("hostnames", value), do: Regex.match?(~r/\A[a-z0-9.-]+(?:,[a-z0-9.-]+)*\z/, value)
  defp valid_field?("prefix", value), do: Regex.match?(~r/\A[a-zA-Z0-9-]{1,64}\z/, value)
  defp valid_field?("app_id", value), do: Regex.match?(~r/\A[1-9][0-9]{0,11}\z/, value)
  defp valid_field?(_, value), do: Regex.match?(~r/\A[a-zA-Z0-9_+=.\/-]+\z/, value)
  defp normalize_hosts(value), do: value |> String.downcase() |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq() |> Enum.join(",")
  defp present?(value), do: is_binary(value) and value != ""
  defp authorize(id), do: if(Accounts.admin?(Repo.get(User, id)), do: :ok, else: {:error, :forbidden})
  defp decoded(%Record{profiles: nil}), do: %{}
  defp decoded(%Record{profiles: profiles}), do: Jason.decode!(profiles)
  defp profile(record, "cloudflare"), do: Map.get(decoded(record), "cloudflare", %{
    "site_key" => Config.turnstile_site_key(), "secret_key" => Config.turnstile_secret_key(),
    "hostnames" => Enum.join(Config.turnstile_hostnames(), ",")
  })
  defp profile(record, provider), do: Map.get(decoded(record), provider, %{})
end
