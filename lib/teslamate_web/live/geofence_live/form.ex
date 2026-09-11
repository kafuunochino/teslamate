defmodule TeslaMateWeb.GeoFenceLive.Form do
  use TeslaMateWeb, :live_view

  alias TeslaMateWeb.GeoFenceLive

  alias TeslaMate.Locations
  alias TeslaMate.Settings.GlobalSettings
  alias TeslaMate.Locations.GeoFence
  alias TeslaMate.Log.Position

  on_mount {TeslaMateWeb.InitAssigns, :locale}

  @impl true
  def mount(%{"id" => id}, %{"settings" => settings}, socket) do
    case Locations.get_geofence(socket.assigns.current_user, id) do
      nil -> {:ok, socket |> put_flash(:error, "围栏不存在或无权访问") |> redirect(to: "/geo-fences")}
      geofence -> {:ok, base_assigns(socket, geofence, settings, :edit)}
    end
  end

  def mount(%{"lat" => lat, "lng" => lng}, %{"settings" => settings}, socket) do
    geofence = %GeoFence{
      user_id: socket.assigns.current_user.id,
      radius: 20,
      latitude: lat,
      longitude: lng
    }

    {:ok, base_assigns(socket, geofence, settings, :new)}
  end

  def mount(_params, %{"settings" => settings}, socket) do
    %{latitude: lat, longitude: lng} =
      case Locations.latest_owned_position(socket.assigns.current_user) do
        %Position{latitude: lat, longitude: lng} -> %{latitude: lat, longitude: lng}
        nil -> %{latitude: 0.0, longitude: 0.0}
      end

    geofence = %GeoFence{
      user_id: socket.assigns.current_user.id,
      radius: 20,
      latitude: lat,
      longitude: lng
    }

    {:ok, base_assigns(socket, geofence, settings, :new)}
  end

  @impl true
  def handle_event("validate", %{"geo_fence" => params}, socket) do
    changeset =
      socket.assigns.geofence
      |> Locations.change_geofence(params)
      |> Map.put(:action, :update)

    {:noreply, assign(socket, changeset: changeset, show_errors: false)}
  end

  def handle_event("save", %{"geo_fence" => params}, socket) do
    with {:ok, geofence, changeset} <- validate(params, socket),
         {:ok, socket} <- show_modal_or_save(geofence, changeset, socket) do
      {:noreply, socket}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, changeset: changeset, show_errors: true)}
      {:error, :forbidden} -> {:noreply, redirect(socket, to: "/geo-fences")}
    end
  end

  def handle_event("calc-costs", %{"result" => result}, socket) do
    case save(socket) do
      {:error, :forbidden} -> {:noreply, redirect(socket, to: "/geo-fences")}
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, changeset: changeset, show_modal: false, show_errors: true)}

      {:ok, socket} ->
        if result == "yes" do
          :ok = Locations.calculate_charge_costs(socket.assigns.current_user, socket.assigns.geofence)
        end

        {:noreply, socket}
    end
  end

  def handle_event("close-modal", _, socket) do
    {:noreply, assign(socket, show_modal: false)}
  end

  def handle_event("keyup", %{"code" => "Escape"}, socket) do
    {:noreply, assign(socket, show_modal: false)}
  end

  def handle_event("keyup", _, socket) do
    {:noreply, socket}
  end

  # Private

  defp base_assigns(socket, %GeoFence{} = geofence, %GlobalSettings{} = settings, action)
       when action in [:new, :edit] do
    assigns = %{
      settings: settings,
      geofence: geofence,
      changeset: Locations.change_geofence(geofence),
      charges_without_costs: 0,
      show_errors: false,
      show_modal: false,
      action: action,
      connected?: connected?(socket),
      page_title: geofence.name || gettext("Geo-Fences")
    }

    assign(socket, assigns)
  end

  defp validate(params, %{assigns: assigns}) do
    changeset = Locations.change_geofence(assigns.geofence, params)

    with {:ok, geofence} <- Ecto.Changeset.apply_action(changeset, :update) do
      {:ok, geofence, changeset}
    end
  end

  defp show_modal_or_save(%GeoFence{} = geofence, changeset, socket) do
    has_cost = geofence.session_fee != nil or geofence.cost_per_unit != nil

    position_or_cost_changed =
      has_changed?(changeset, [
        :cost_per_unit,
        :session_fee,
        :billing_type,
        :latitude,
        :longitude,
        :radius
      ])

    with true <- has_cost and position_or_cost_changed,
         n when n > 0 <- Locations.count_charging_processes_without_costs(geofence) do
      socket =
        assign(socket,
          show_modal: true,
          changeset: changeset,
          charges_without_costs: n
        )

      {:ok, socket}
    else
      _ -> socket |> assign(changeset: changeset) |> save()
    end
  end

  defp save(%{assigns: assigns} = socket) do
    %{changeset: %{params: params}, action: action, geofence: geofence} = assigns

    with {:ok, %GeoFence{name: name} = geofence} <-
           (case action do
              :new -> Locations.create_geofence(assigns.current_user, params)
              :edit -> Locations.update_geofence(assigns.current_user, geofence, params)
            end) do
      socket =
        socket
        |> assign(geofence: geofence)
        |> put_flash(:success, flash_msg(action, name))
        |> push_navigate(to: Routes.live_path(socket, GeoFenceLive.Index))

      {:ok, socket}
    end
  end

  defp has_changed?(%Ecto.Changeset{changes: changes}, keys) do
    length(keys -- Map.keys(changes)) < length(keys)
  end

  defp flash_msg(:new, name), do: gettext("Geo-fence \"%{name}\" created", name: name)
  defp flash_msg(:edit, name), do: gettext("Geo-fence \"%{name}\" updated", name: name)
end
