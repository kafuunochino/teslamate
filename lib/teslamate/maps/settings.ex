defmodule TeslaMate.Maps.Settings do
  use Ecto.Schema
  import Ecto.Changeset

  @schema_prefix "private"
  @primary_key {:id, :integer, autogenerate: false}
  schema "map_settings" do
    field :provider, Ecto.Enum, values: [:openstreetmap, :amap], default: :openstreetmap
    field :amap_key, TeslaMate.Vault.Encrypted.Binary, redact: true
    field :amap_security_code, TeslaMate.Vault.Encrypted.Binary, redact: true
    timestamps()
  end

  def changeset(settings, attrs) do
    # A blank credential means retain the saved value. Never return saved
    # credentials to the admin form or put this schema in the browser session.
    attrs =
      attrs
      |> Map.take(["provider", "amap_key", "amap_security_code"])
      |> Enum.reduce(%{}, fn
        {key, value}, acc when key in ["amap_key", "amap_security_code"] and is_binary(value) ->
          case String.trim(value) do
            "" -> acc
            value -> Map.put(acc, key, value)
          end

        {key, value}, acc ->
          Map.put(acc, key, value)
      end)

    settings
    |> cast(attrs, [:provider, :amap_key, :amap_security_code])
    |> validate_required([:provider], message: "请选择地图提供商")
    |> validate_format(:amap_key, ~r/\A[a-zA-Z0-9_-]{16,128}\z/, message: "请输入有效的高德 Web 端 Key")
    |> validate_format(:amap_security_code, ~r/\A[a-zA-Z0-9_-]{16,128}\z/,
      message: "请输入有效的高德安全密钥"
    )
    |> require_amap_credentials()
  end

  defp require_amap_credentials(changeset) do
    if get_field(changeset, :provider) == :amap do
      validate_required(changeset, [:amap_key, :amap_security_code], message: "启用高德地图前请填写此项")
    else
      changeset
    end
  end
end
