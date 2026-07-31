defmodule TeslaMateWeb.DriveController do
  use TeslaMateWeb, :controller

  require Logger
  alias TeslaMate.Fleet

  def gpx(conn, %{"id" => id}) do
    case Fleet.trip(conn.assigns.current_user, id) do
      nil ->
        conn |> send_resp(404, gettext("Drive not found"))

      %{drive: drive, positions: positions} ->
        send_gpx_file(conn, %{drive | positions: positions})
    end
  end

  defp send_gpx_file(conn, drive) do
    filename = "#{drive.start_date}.gpx"

    conn
    |> put_resp_content_type("application/xml")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
    |> render("gpx.xml", drive: drive)
  end
end
