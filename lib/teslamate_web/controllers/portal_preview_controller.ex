defmodule TeslaMateWeb.PortalPreviewController do
  use TeslaMateWeb, :controller

  # This route has no session, database, or vehicle-data pipeline. It serves
  # only fixed fixtures through the same templates used by the private app.
  def show(conn, %{"page" => page}) when page in ["home", "trips", "charging"] do
    conn
    |> put_resp_header("content-security-policy", Enum.join([
      "default-src 'none'", "style-src 'self' 'unsafe-inline'", "font-src 'self' data:",
      "img-src 'self' data:", "script-src 'none'", "connect-src 'none'",
      "frame-ancestors 'self'", "form-action 'none'", "base-uri 'none'"
    ], "; "))
    |> put_resp_header("x-frame-options", "SAMEORIGIN")
    |> put_resp_header("x-robots-tag", "noindex, nofollow")
    |> put_resp_header("cache-control", "no-store")
    |> html(TeslaMateWeb.PortalPreview.document(page))
  end

  def show(conn, _params), do: send_resp(conn, 404, "Not found")
end
