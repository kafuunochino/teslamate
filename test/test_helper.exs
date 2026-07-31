# FIXME Workaround to apply the logger config when running the tests with
# "--no-start". This looks like a bug in Elixir v1.11.0
Application.stop(:logger)
Application.start(:logger)

# Most controller tests exercise the API action itself and do not construct
# browser Origin/Referer headers. The origin plug has dedicated tests.
System.put_env("TESLAMATE_API_ORIGIN_CHECK", "false")

Application.load(:teslamate)

for app <- Application.spec(:teslamate, :applications) do
  {:ok, _} = Application.ensure_all_started(app)
end

TeslaMate.Repo.start_link()
Phoenix.PubSub.Supervisor.start_link(name: TeslaMate.PubSub)

assert_timeout = String.to_integer(System.get_env("ELIXIR_ASSERT_TIMEOUT") || "300")
ExUnit.start(assert_receive_timeout: assert_timeout)
