defmodule TeslaMateWeb.UserSessionController do
  use TeslaMateWeb, :controller

  alias TeslaMate.Accounts
  alias TeslaMate.Accounts.Security
  alias TeslaMate.Auth.LoginAudit
  alias TeslaMateWeb.Plugs.LoginRateLimit
  alias TeslaMateWeb.UserAuth

  def new(conn, _params) do
    render(conn, "new.html", page_title: "登录", error: nil, email: "")
  end

  def create(conn, %{"user" => %{"email" => email, "password" => password}})
      when is_binary(email) and is_binary(password) do
    email = email |> String.trim() |> String.downcase()
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

  def verify(conn, _params) do
    if Security.challenge_user(get_session(conn, :login_challenge)) do
      render(conn, "verify.html", page_title: "两步验证", error: nil)
    else
      conn |> delete_session(:login_challenge) |> redirect(to: "/sign_in")
    end
  end

  def verify_code(conn, %{"verification" => %{"code" => code}}) when is_binary(code) do
    token = get_session(conn, :login_challenge)
    case Security.complete_challenge(token, String.trim(code), UserAuth.session_metadata(conn)) do
      {:ok, user, session} ->
        ip = conn.private[:client_ip] || "unknown"
        LoginRateLimit.record_success(ip, user.email)
        LoginAudit.record(%{ip: ip, email: user.email, outcome: :success, reason: "platform-2fa"})
        conn |> UserAuth.put_authenticated_session(session) |> redirect(to: "/")
      {:error, :invalid_challenge} ->
        conn |> delete_session(:login_challenge)
          |> put_flash(:error, "验证会话已过期或尝试次数已用完，请重新登录") |> redirect(to: "/sign_in")
      {:error, reason} ->
        status = if reason == :rate_limited, do: :too_many_requests, else: :unprocessable_entity
        message = if reason == :rate_limited, do: "尝试次数过多，请 10 分钟后重试",
          else: "验证码无效或已使用，请输入最新动态码或未使用的恢复码"
        conn |> put_status(status) |> render("verify.html", page_title: "两步验证", error: message)
    end
  end
  def verify_code(conn, _params), do: conn |> put_status(:unprocessable_entity) |> verify(%{})

  def delete(conn, _params), do: UserAuth.log_out_user(conn)

  defp authenticate(conn, ip, email, password) do
    case Accounts.authenticate_user(email, password) do
      {:ok, user} ->
        unless Security.enabled?(user) do
          LoginRateLimit.record_success(ip, email)
          LoginAudit.record(%{ip: ip, email: email, outcome: :success, reason: "platform-login"})
        end
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
