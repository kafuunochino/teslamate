defmodule TeslaMateWeb.CaptchaSettingsController do
  use TeslaMateWeb, :controller
  alias TeslaMate.Auth.{Captcha, CaptchaSettings}

  plug :private_response

  def create(conn, %{"captcha_settings" => attrs}) do
    case CaptchaSettings.prepare(conn.assigns.current_user, attrs) do
      {:ok, :saved} -> saved(conn)
      {:verify, token} -> verification(conn, token)
      {:error, reason} -> failed(conn, reason)
    end
  end

  def create(conn, _), do: failed(conn, :configuration)

  def verify(conn, %{"captcha_setup_token" => token} = params) do
    ip = conn.private[:client_ip] || "unknown"

    case CaptchaSettings.verify_and_save(conn.assigns.current_user, token, params, ip) do
      {:ok, :saved} ->
        saved(conn)

      {:error, :expired} ->
        failed(conn, :expired)

      {:error, reason} ->
        verification(put_status(conn, :unprocessable_entity), token, Captcha.message(reason))
    end
  end

  def verify(conn, _), do: failed(conn, :expired)

  defp verification(conn, token, error \\ nil) do
    case CaptchaSettings.draft(conn.assigns.current_user, token) do
      {:ok, draft} ->
        conn
        |> TeslaMateWeb.Plugs.SecurityHeaders.for_captcha(draft.provider)
        |> render("verify.html",
          page_title: "验证人机验证配置",
          error: error,
          setup_token: token,
          settings: CaptchaSettings.public_config(draft)
        )

      {:error, reason} ->
        failed(conn, reason)
    end
  end

  defp saved(conn),
    do:
      conn
      |> put_flash(:success, "人机验证配置已保存并应用。其他厂商已保存的配置仍然保留。")
      |> redirect(to: "/admin/settings#captcha-settings")

  defp failed(conn, reason),
    do:
      conn
      |> put_flash(:error, Captcha.message(reason))
      |> redirect(to: "/admin/settings#captcha-settings")

  defp private_response(conn, _), do: put_resp_header(conn, "cache-control", "no-store")
end
