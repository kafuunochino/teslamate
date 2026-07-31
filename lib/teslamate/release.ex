defmodule TeslaMate.Release do
  @app :teslamate

  import Ecto.Query
  alias TeslaMate.Repo
  alias TeslaMate.Accounts

  def migrate do
    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    for r <- repos(), r == repo do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
    end
  end

  def create_admin_from_env do
    email = System.fetch_env!("TESLAMATE_ADMIN_EMAIL")
    password = System.fetch_env!("TESLAMATE_ADMIN_PASSWORD")
    name = System.get_env("TESLAMATE_ADMIN_NAME", "平台管理员")

    attrs = %{
      email: email,
      name: name,
      password: password,
      password_confirmation: password
    }

    for repo <- repos() do
      {:ok, result, _started_apps} =
        Ecto.Migrator.with_repo(repo, fn _repo ->
          case Accounts.bootstrap_admin(attrs) do
            {:ok, user} -> {:ok, %{id: user.id, email: user.email}}
            {:error, changeset} -> {:error, inspect(changeset.errors)}
          end
        end)

      case result do
        {:ok, admin} -> IO.puts("Administrator ready: #{admin.email} (id=#{admin.id})")
        {:error, reason} -> raise "Could not create administrator: #{reason}"
      end
    end

    :ok
  end

  def seconds_since_last_migration do
    Repo.one(
      from m in "schema_migrations",
        select: fragment("EXTRACT(EPOCH FROM age(NOW(), ?::timestamp))::BIGINT", m.inserted_at),
        order_by: [desc: m.inserted_at],
        limit: 1
    )
  end

  defp repos do
    Application.ensure_all_started(:ssl)
    Application.load(@app)
    Application.fetch_env!(@app, :ecto_repos)
  end
end
