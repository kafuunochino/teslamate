defmodule TeslaMateWeb.PortalController do
  use TeslaMateWeb, :controller

  def index(conn, _params) do
    conn
    |> assign(:public_portal, true)
    |> render("index.html", page_title: "读懂每一次出发", registration_policy: TeslaMate.Accounts.registration_policy())
  end
end
