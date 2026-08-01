defmodule TeslaMateWeb.UserSessionController do
  use TeslaMateWeb, :controller

  alias TeslaMate.Accounts
  alias TeslaMate.Auth.LoginAudit
  alias TeslaMateWeb.Plugs.LoginRateLimit
  alias TeslaMateWeb.UserAuth

  def new(conn, _params) do
    render(conn, "new.html", page_title: "登录", error: nil, email: "")
  end

  def create(conn, %{"user" => %{"email" => email, "password" => password}}) do
    ip = conn.private[:client_ip] || "unknown"

    case LoginRateLimit.check(ip, email) do
      {:error, :rate_limited, retry_after} ->
        LoginAudit.record(%{
          ip: ip,
          email: email,
          outcome: :blocked,
          reason: "platform-rate-limit"
        })

        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> put_status(:too_many_requests)
        |> render("new.html",
          page_title: "登录",
          error: "尝试次数过多，请在 #{retry_after} 秒后重试",
          email: email
        )

      :ok ->
        authenticate(conn, ip, email, password)
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> render("new.html", page_title: "登录", error: "请输入邮箱和密码", email: "")
  end

  def delete(conn, _params), do: UserAuth.log_out_user(conn)

  defp authenticate(conn, ip, email, password) do
    case Accounts.authenticate_user(email, password) do
      {:ok, user} ->
        LoginRateLimit.record_success(ip, email)
        LoginAudit.record(%{ip: ip, email: email, outcome: :success, reason: "platform-login"})
        UserAuth.log_in_user(conn, user)

      {:error, :invalid_credentials} ->
        LoginRateLimit.record_failure(ip, email)
        LoginAudit.record(%{ip: ip, email: email, outcome: :failure, reason: "platform-login"})

        conn
        |> put_status(:unprocessable_entity)
        |> render("new.html",
          page_title: "登录",
          error: "邮箱、密码错误或账号已停用",
          email: email
        )
    end
  end
end
