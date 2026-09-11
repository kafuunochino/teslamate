defmodule TeslaMateWeb.GeoFenceLive.Index do
  use TeslaMateWeb, :live_view

  alias TeslaMate.{Locations, Settings}
  alias Settings.GlobalSettings

  alias TeslaMate.Convert

  on_mount {TeslaMateWeb.InitAssigns, :locale}

  @impl true
  def mount(_params, %{"settings" => settings}, socket) do
    unit_of_length =
      case settings do
        %GlobalSettings{unit_of_length: :km} -> :m
        %GlobalSettings{unit_of_length: :mi} -> :ft
      end

    assigns = %{
      geofences: Locations.list_geofences(socket.assigns.current_user),
      unit_of_length: unit_of_length,
      page_title: gettext("Geo-Fences")
    }

    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    case Locations.delete_geofence(socket.assigns.current_user, id) do
      {:ok, _} -> {:noreply, assign(socket, :geofences, Locations.list_geofences(socket.assigns.current_user))}
      {:error, _} -> {:noreply, put_flash(socket, :error, "围栏不存在或无权操作")}
    end
  end
end
