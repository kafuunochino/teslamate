defmodule TeslaMateWeb.SignInLive.Index do
  use TeslaMateWeb, :live_view

  import Core.Dependency, only: [call: 3]
  alias TeslaMate.{Auth, Api}
  alias TeslaMate.Auth.LoginAudit
  alias TeslaMateWeb.Plugs.LoginRateLimit

  on_mount {TeslaMateWeb.InitAssigns, :locale}

  @impl true
  def mount(_params, %{"client_ip" => ip} = _session, socket) do
    assigns = %{
      api: get_api(socket),
      page_title: gettext("Sign in"),
      error: nil,
      task: nil,
      client_ip: ip,
      changeset: Auth.change_tokens(),
      token: System.get_env("TOKEN", ""),
      provider: System.get_env("TESLA_AUTH_HOST", "https://auth.tesla.com")
    }

    {:ok, assign(socket, assigns)}
  end

  def mount(_params, _session, socket) do
    assigns = %{
      api: get_api(socket),
      page_title: gettext("Sign in"),
      error: nil,
      task: nil,
      client_ip: "unknown",
      changeset: Auth.change_tokens(),
      token: System.get_env("TOKEN", ""),
      provider: System.get_env("TESLA_AUTH_HOST", "https://auth.tesla.com")
    }

    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("validate", %{"tokens" => tokens}, socket) do
    changeset =
      tokens
      |> Auth.change_tokens()
      |> Map.put(:action, :update)

    {:noreply, assign(socket, changeset: changeset, error: nil)}
  end

  def handle_event("sign_in", _, socket) do
    ip = socket.assigns.client_ip
    email = socket.assigns.changeset |> Ecto.Changeset.apply_changes() |> Map.get(:email)

    case LoginRateLimit.check(ip, email) do
      {:error, :rate_limited, retry_after} ->
        LoginAudit.record(%{ip: ip, email: email, outcome: :blocked, reason: "rate-limit"})

        {:noreply,
         assign(socket,
           error: gettext("Too many failed attempts. Try again in %{n}s.", n: retry_after),
           task: nil
         )}

      :ok ->
        tokens = Ecto.Changeset.apply_changes(socket.assigns.changeset)

        task =
          Task.async(fn ->
            call(socket.assigns.api, :sign_in, [tokens])
          end)

        audit_meta = %{ip: ip, email: email}

        {:noreply, assign(socket, task: task, audit_meta: audit_meta)}
    end
  end

  @impl true
  def handle_info({ref, result}, %{assigns: %{task: %Task{ref: ref}}} = socket) do
    Process.demonitor(ref, [:flush])

    case result do
      :ok ->
        meta = socket.assigns.audit_meta
        LoginAudit.record(Map.put(meta, :outcome, :success))
        # Reset the per-email bucket so a successful login is not penalised
        # by an earlier typo.
        LoginRateLimit.record_success(meta.ip, meta.email)
        Process.sleep(250)
        {:noreply, redirect_to_carlive(socket)}

      {:error, %TeslaApi.Error{} = e} ->
        meta = socket.assigns.audit_meta
        LoginAudit.record(Map.merge(meta, %{outcome: :failure, reason: e.reason}))

        # Increment the failure counter so brute-force is throttled.
        LoginRateLimit.record_failure(meta.ip, meta.email)

        message =
          case e.reason do
            :token_refresh ->
              gettext("Tokens are invalid")

            :account_locked ->
              gettext(
                "Your Tesla account is locked due to too many failed sign in attempts. " <>
                  "To unlock your account, reset your password"
              )

            _ ->
              Exception.message(e)
          end

        {:noreply, assign(socket, error: message, task: nil)}
    end
  end

  defp get_api(socket) do
    case get_connect_params(socket) do
      %{api: api} -> api
      _ -> Api
    end
  end

  defp redirect_to_carlive(socket) do
    socket
    |> put_flash(:success, gettext("Signed in successfully"))
    |> redirect(to: Routes.car_path(socket, :index))
  end
end
