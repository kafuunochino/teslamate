defmodule TeslaMate.Updater do
  use GenServer
  use Tesla, only: [:get]

  require Logger

  @version Mix.Project.config()[:version]
  @name __MODULE__
  @repository "kafuunochino/teslamate"
  @revision (case System.get_env("TESLAMATE_REVISION") do
               revision when is_binary(revision) ->
                 revision

               _ ->
                 case System.find_executable("git") do
                   nil ->
                     nil

                   git ->
                     case System.cmd(git, ["rev-parse", "HEAD"], stderr_to_stdout: true) do
                       {revision, 0} -> String.trim(revision)
                       _ -> nil
                     end
                 end
             end)

  adapter Tesla.Adapter.Finch, name: TeslaMate.HTTP, receive_timeout: 30_000

  plug Tesla.Middleware.BaseUrl, "https://api.github.com"
  plug Tesla.Middleware.Headers, [{"user-agent", "TeslaMate/#{@version}"}]
  plug Tesla.Middleware.JSON
  plug Tesla.Middleware.Logger, debug: true, log_level: &log_level/1

  defmodule State, do: defstruct([:update, :version, :revision, :repository])
  defmodule Release, do: defstruct([:version, :prerelease])

  defmodule RepositoryCheck do
    @enforce_keys [:status, :current_revision, :remote_revision, :compare_url]
    defstruct [:status, :current_revision, :remote_revision, :compare_url]
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  def get_update(name \\ @name) do
    GenServer.call(name, :get_update, 50)
  catch
    :exit, {:timeout, _} -> nil
    :exit, {:noproc, _} -> nil
  end

  def current_revision, do: normalize_revision(@revision)

  def check_repository(receiver \\ self(), name \\ @name) when is_pid(receiver) do
    GenServer.cast(name, {:check_repository, receiver})
  end

  @impl GenServer
  def init(opts) do
    check_after = opts[:check_after] || :timer.minutes(5)
    interval = opts[:interval] || :timer.hours(72)
    version = opts[:version] || @version
    revision = normalize_revision(opts[:revision] || current_revision())
    repository = opts[:repository] || @repository
    state = %State{version: version, revision: revision, repository: repository}

    {:ok, _} = :timer.send_interval(interval, :check_for_updates)

    case check_after do
      0 ->
        {:ok, state, {:continue, :check_for_updates}}

      t when is_number(t) and 0 < t ->
        Process.send_after(self(), :check_for_updates, t)
        {:ok, state}
    end
  end

  @impl GenServer
  def handle_continue(:check_for_updates, %State{version: current_vsv} = state) do
    Logger.debug("Checking for updates …")

    case fetch_release() do
      {:ok, %Release{version: version, prerelease: false}} ->
        case Version.compare(current_vsv, version) do
          :lt ->
            Logger.info("Update available: #{current_vsv} -> #{version}")
            {:noreply, %State{state | update: version}}

          _ ->
            Logger.debug("No update available")
            {:noreply, state}
        end

      {:ok, %Release{version: version, prerelease: true}} ->
        Logger.debug("Prerelease available: #{version}")
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("Update check failed: #{inspect(reason, pretty: true)}")
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info(:check_for_updates, state) do
    {:noreply, state, {:continue, :check_for_updates}}
  end

  @impl GenServer
  def handle_call(:get_update, _from, %State{update: update} = state) do
    {:reply, update, state}
  end

  @impl GenServer
  def handle_cast(
        {:check_repository, receiver},
        %State{revision: current, repository: repository} = state
      ) do
    result = check_repository_revision(repository, current)
    send(receiver, {:repository_update_check, result})

    {:noreply, state}
  end

  ## Private

  defp fetch_release do
    case get("/repos/teslamate-org/teslamate/releases/latest") do
      {:ok, %Tesla.Env{status: 200, body: body}} ->
        parse_release(body)

      {:ok, %Tesla.Env{} = env} ->
        {:error, reason: "Unexpected response", env: env}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp check_repository_revision(_repository, nil), do: {:error, :unknown_current_revision}

  defp check_repository_revision(repository, current) do
    case fetch_repository_revision(repository) do
      {:ok, remote} ->
        status = if current == remote, do: :current, else: :update_available

        {:ok,
         %RepositoryCheck{
           status: status,
           current_revision: current,
           remote_revision: remote,
           compare_url: "https://github.com/#{repository}/compare/#{current}...#{remote}"
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_repository_revision(repository) do
    case get("/repos/#{repository}/commits/main") do
      {:ok, %Tesla.Env{status: 200, body: %{"sha" => revision}}} ->
        case normalize_revision(revision) do
          nil -> {:error, :invalid_revision}
          revision -> {:ok, revision}
        end

      {:ok, %Tesla.Env{} = env} ->
        {:error, reason: "Unexpected response", env: env}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_release(release) do
    case release do
      %{"tag_name" => "v" <> tag, "prerelease" => prerelease?, "draft" => draft?} ->
        case Version.parse(tag) do
          {:ok, version} ->
            {:ok, %Release{version: to_string(version), prerelease: prerelease? or draft?}}

          :error ->
            {:error, :invalid_release_tag}
        end

      %{} ->
        {:error, :invalid_response}
    end
  end

  defp normalize_revision(revision) when is_binary(revision) do
    revision = String.trim(revision)

    if Regex.match?(~r/\A[0-9a-f]{40}\z/i, revision) do
      String.downcase(revision)
    end
  end

  defp normalize_revision(_revision), do: nil

  defp log_level(%Tesla.Env{} = env) when env.status >= 400, do: :warning
  defp log_level(%Tesla.Env{}), do: :debug
end
