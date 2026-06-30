defmodule TeslaMate.UpdaterTest do
  use TeslaMate.DataCase, async: true

  alias TeslaMate.Updater
  import Mock

  defmodule HTTPMocck do
    def vsn(tag) do
      json(%{"tag_name" => tag, "prerelease" => false, "draft" => false})
    end

    def json(data) do
      response({:ok, %Tesla.Env{status: 200, body: data}})
    end

    def response(resp) do
      [
        {Tesla.Adapter.Finch, [],
         call: fn %Tesla.Env{} = env, _opts ->
           assert env.url ==
                    "https://api.github.com/repos/teslamate-org/teslamate/releases/latest"

           resp
         end}
      ]
    end
  end

  defp start_updater(name, version, opts \\ []) do
    id = Keyword.get(opts, :id, 0)

    start_supervised(
      {Updater, [name: :"updater#{id}_#{name}}", version: version, check_after: 0]},
      id: id
    )
  end

  test "informs if an update is available", %{test: name} do
    with_mocks HTTPMocck.vsn("v5.1.2") do
      ## current_version > new_version
      {:ok, pid} = start_updater(name, "5.1.3-dev", id: 0)
      Process.sleep(100)
      assert nil == Updater.get_update(pid)

      ## current_version == new_version
      {:ok, pid} = start_updater(name, "5.1.2", id: 1)
      Process.sleep(100)
      assert nil == Updater.get_update(pid)

      ## current_version < new_version
      {:ok, pid} = start_updater(name, "4.99.0", id: 2)
      Process.sleep(100)
      assert "5.1.2" == Updater.get_update(pid)
    end
  end

  test "returns early even though update check is still in progress", %{test: name} do
    with_mocks [{Tesla.Adapter.Finch, [], call: fn _, _ -> Process.sleep(1_000_000) end}] do
      {:ok, pid} = start_updater(name, "1.0.0")
      assert nil == Updater.get_update(pid)
    end
  end

  @tag :capture_log
  test "handles invalid tags", %{test: name} do
    with_mocks HTTPMocck.vsn("2.0.0") do
      {:ok, pid} = start_updater(name, "1.0.0")
      assert nil == Updater.get_update(pid)
    end
  end

  @tag :capture_log
  test "handles invalid json", %{test: name} do
    with_mocks HTTPMocck.json(%{"foo" => "bar"}) do
      {:ok, pid} = start_updater(name, "1.0.0")
      assert nil == Updater.get_update(pid)
    end
  end

  @tag :capture_log
  test "handles HTTP errors", %{test: name} do
    with_mocks HTTPMocck.response({:ok, %Tesla.Env{status: 404}}) do
      {:ok, pid} = start_updater(name, "1.0.0", id: 0)
      assert nil == Updater.get_update(pid)
    end

    with_mocks HTTPMocck.response({:error, :timeout}) do
      {:ok, pid} = start_updater(name, "1.0.0", id: 1)
      assert nil == Updater.get_update(pid)
    end
  end

  test "handles prereleases and drafts", %{test: name} do
    with_mocks HTTPMocck.json(%{"tag_name" => "v99.0.0", "prerelease" => true, "draft" => false}) do
      {:ok, pid} = start_updater(name, "1.0.0", id: 0)
      assert nil == Updater.get_update(pid)
    end

    with_mocks HTTPMocck.json(%{"tag_name" => "v99.0.0", "prerelease" => false, "draft" => true}) do
      {:ok, pid} = start_updater(name, "1.0.0", id: 1)
      assert nil == Updater.get_update(pid)
    end
  end

  test "manually checks the configured repository for source changes", %{test: name} do
    current = String.duplicate("a", 40)
    remote = String.duplicate("b", 40)
    process_name = :"repository_updater_#{name}"
    updater_opts = [
      name: process_name,
      version: "1.0.0",
      revision: current,
      check_after: :timer.hours(1)
    ]

    with_mocks [
      {Tesla.Adapter.Finch, [],
       call: fn %Tesla.Env{} = env, _opts ->
         assert env.url == "https://api.github.com/repos/kafuunochino/teslamate/commits/main"
         {:ok, %Tesla.Env{status: 200, body: %{"sha" => remote}}}
       end}
    ] do
      pid = start_supervised!({Updater, updater_opts})

      assert :ok = Updater.check_repository(self(), pid)

      assert_receive {:repository_update_check,
                      {:ok,
                       %Updater.RepositoryCheck{
                         status: :update_available,
                         current_revision: ^current,
                         remote_revision: ^remote,
                         compare_url: compare_url
                       }}}

      assert compare_url ==
               "https://github.com/kafuunochino/teslamate/compare/#{current}...#{remote}"
    end
  end
end
