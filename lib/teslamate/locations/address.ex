defmodule TeslaMate.Locations.Address do
  use Ecto.Schema
  import Ecto.Changeset

  schema "addresses" do
    field :city, :string
    field :county, :string
    field :country, :string
    field :display_name, :string
    field :house_number, :string
    field :latitude, :decimal, read_after_writes: true
    field :longitude, :decimal, read_after_writes: true
    field :name, :string
    field :neighbourhood, :string
    field :osm_id, :integer
    field :osm_type, :string
    field :postcode, :string
    field :raw, :map
    field :road, :string
    field :state, :string
    field :state_district, :string

    timestamps()
  end

  @china_names ["中国", "中國", "中华人民共和国", "China"]

  @doc "Formats the saved address without discarding street or neighbourhood detail."
  def display_label(%__MODULE__{} = address) do
    case clean_part(address.display_name) do
      nil ->
        [
          address.name,
          join_parts([address.road, address.house_number], " "),
          address.neighbourhood,
          address.city,
          address.county,
          address.state_district,
          address.state,
          address.country
        ]
        |> join_parts(", ")
        |> format_display_name()

      display_name ->
        format_display_name(display_name)
    end
  end

  def format_display_name(value) when is_binary(value) do
    parts =
      value
      |> String.split(~r/[,，]/u)
      |> Enum.map(&clean_part/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    parts =
      if Enum.any?(parts, &(&1 in @china_names)) do
        parts
        |> Enum.reject(&(&1 in @china_names or Regex.match?(~r/^\d{6}$/, &1)))
        |> Enum.reverse()
      else
        parts
      end

    case parts do
      [] -> "未知位置"
      _ -> Enum.join(parts, " · ")
    end
  end

  def format_display_name(_), do: "未知位置"

  defp join_parts(parts, separator) do
    parts
    |> Enum.map(&clean_part/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.join(separator)
  end

  defp clean_part(value) when is_binary(value) do
    case String.trim(value) do
      value when value in ["", "Unknown", "unknown"] -> nil
      value -> value
    end
  end

  defp clean_part(_), do: nil

  @doc false
  def changeset(address, attrs) do
    address
    |> cast(attrs, [
      :display_name,
      :osm_id,
      :osm_type,
      :latitude,
      :longitude,
      :name,
      :house_number,
      :road,
      :neighbourhood,
      :city,
      :county,
      :postcode,
      :state,
      :state_district,
      :country,
      :raw
    ])
    |> validate_required([
      :display_name,
      :osm_id,
      :osm_type,
      :latitude,
      :longitude,
      :raw
    ])
    |> unique_constraint(:osm_id, name: :addresses_osm_id_osm_type_index)
  end
end
