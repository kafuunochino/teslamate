defmodule TeslaMateWeb.UserRegistrationController do
  use TeslaMateWeb, :controller

  alias TeslaMate.Accounts
  alias TeslaMateWeb.Plugs.LoginRateLimit
  alias TeslaMateWeb.UserAuth

  def new(conn, _params) do
    if Accounts.sign_up_allowed?() do
      render(conn, "new.html",
        page_title: "注册",
        changeset: Accounts.change_registration()
      )
    else
      conn |> put_status(:not_found) |> put_view(TeslaMateWeb.ErrorView) |> render("404.html")
    end
  end

  def create(conn, %{"user" => user_params}) do
    if Accounts.sign_up_allowed?() do
      ip = conn.private[:client_ip] || "unknown"
      email_key = registration_key(Map.get(user_params, "email", ""))

      case LoginRateLimit.check(ip, email_key) do
        :ok ->
          # Count every registration attempt before running the deliberately
          # expensive password hash. This bounds public CPU and database spam.
          LoginRateLimit.record_failure(ip, email_key)
          register(conn, user_params)

        {:error, :rate_limited, retry_after} ->
          conn
          |> put_resp_header("retry-after", Integer.to_string(retry_after))
          |> put_flash(:error, "注册尝试过多，请在 #{retry_after} 秒后重试")
          |> put_status(:too_many_requests)
          |> render("new.html", page_title: "注册", changeset: Accounts.change_registration())
      end
    else
      conn |> put_status(:not_found) |> put_view(TeslaMateWeb.ErrorView) |> render("404.html")
    end
  end

  defp register(conn, user_params) do
    case Accounts.register_user(user_params) do
      {:ok, user} ->
        conn
        |> put_flash(:success, "账号创建成功。请使用管理员提供的车辆认领码绑定车辆。")
        |> UserAuth.log_in_user(user)

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render("new.html", page_title: "注册", changeset: changeset)
    end
  end

  defp registration_key(email) do
    normalized = email |> to_string() |> String.trim() |> String.downcase() |> String.slice(0, 254)
    "registration:" <> normalized
  end
end
