defmodule TeslaMate.Maps do
  @moduledoc "Saved map configuration, separate from session-backed global settings."

  import Ecto.Query
  alias TeslaMate.{Accounts, Repo}
  alias TeslaMate.Accounts.User
  alias TeslaMate.Maps.Settings

  def get_settings!, do: Repo.get!(Settings, 1)

  def preferences do
    settings = get_settings!()

    %{
      provider: settings.provider,
      has_amap_key: is_binary(settings.amap_key),
      has_amap_security_code: is_binary(settings.amap_security_code)
    }
  end

  def browser_config do
    case get_settings!() do
      %Settings{provider: :amap, amap_key: key} ->
        %{provider: "amap", key: key, service_host: "/_AMapService"}

      _ ->
        %{provider: "openstreetmap"}
    end
  end

  def update_settings(%User{id: id}, attrs) do
    if Accounts.admin?(Repo.get(User, id)) do
      Repo.transaction(fn ->
        current = from(s in Settings, where: s.id == 1, lock: "FOR UPDATE") |> Repo.one!()

        case current |> Settings.changeset(attrs) |> Repo.update() do
          {:ok, settings} -> settings
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    else
      {:error, :forbidden}
    end
  end

  def update_settings(_, _attrs), do: {:error, :forbidden}
end
