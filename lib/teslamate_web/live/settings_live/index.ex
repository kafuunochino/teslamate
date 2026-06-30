defmodule TeslaMateWeb.SettingsLive.Index do
  use TeslaMateWeb, :live_view

  require Logger

  alias TeslaMate.Settings.{GlobalSettings, CarSettings}
  alias TeslaMate.{Settings, Updater, Api}

  on_mount {TeslaMateWeb.InitAssigns, :locale}

  @impl true
  def mount(_params, %{"settings" => settings}, socket) do
    assigns = %{
      addresses_migrated?: addresses_migrated?(),
      car_settings: Settings.get_car_settings() |> prepare(),
      car: nil,
      global_settings: settings |> prepare(),
      update: Updater.get_update(),
      repository_check: :idle,
      refreshing_addresses?: nil,
      refresh_error: nil,
      page_title: gettext("Settings")
    }

    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    %{car_settings: settings, car: car} = socket.assigns

    car =
      with id when not is_nil(id) <- Map.get(params, "car"),
           {id, ""} <- Integer.parse(id),
           true <- Map.has_key?(settings, id) do
        id
      else
        _ -> car || settings |> Map.keys() |> List.first()
      end

    {:noreply, assign(socket, car: car)}
  end

  @impl true
  def handle_event("car", %{"id" => id}, socket) do
    {:noreply, add_params(socket, car: id)}
  end

  def handle_event("change", %{"global_settings" => %{"ui" => ui}}, %{assigns: %{locale: lo}} = s)
      when ui != lo do
    {:noreply, redirect(s, to: Routes.live_path(s, __MODULE__, locale: ui))}
  end

  def handle_event("change", %{"global_settings" => params}, %{assigns: assigns} = socket) do
    settings = fn ->
      case Settings.update_global_settings(assigns.global_settings.original, params) do
        {:error, %Ecto.Changeset{} = changeset} ->
          %{global_settings: Map.put(assigns.global_settings, :changeset, changeset)}

        {:error, reason} ->
          Logger.warning("Updating settings failed: #{inspect(reason, pretty: true)}")

          %{
            refresh_error:
              gettext(
                "There was a problem retrieving data from OpenStreetMap. Please try again later."
              )
          }

        {:ok, settings} ->
          %{global_settings: prepare(settings)}
      end
    end

    socket =
      if params["language"] != nil and params["language"] != assigns.global_settings.original do
        me = self()
        spawn_link(fn -> send(me, {:assigns, settings.()}) end)
        assign(socket, refreshing_addresses?: true)
      else
        assign(socket, settings.())
      end

    {:noreply, socket}
  end

  def handle_event("change", params, %{assigns: %{car_settings: settings, car: id}} = socket) do
    params = params["car_settings_#{id}"]

    settings =
      get_in(settings, [id, :original])
      |> Settings.update_car_settings(params)
      |> case do
        {:error, changeset} ->
          Logger.warning(inspect(changeset))
          put_in(settings, [id, :changeset], changeset)

        {:ok, car_settings} ->
          settings
          |> put_in([id, :original], car_settings)
          |> put_in([id, :changeset], Settings.change_car_settings(car_settings))
      end

    {:noreply, assign(socket, :car_settings, settings)}
  end

  def handle_event("sign_out", _params, socket) do
    :ok = Api.sign_out()
    {:noreply, redirect(socket, to: Routes.car_path(socket, :index))}
  end

  def handle_event("check_repository_update", _params, socket) do
    :ok = Updater.check_repository(self())

    {:noreply, assign(socket, repository_check: :checking)}
  end

  @impl true
  def handle_info({:assigns, assigns}, socket) do
    socket =
      socket
      |> assign(refreshing_addresses?: false)
      |> assign(assigns)

    {:noreply, socket}
  end

  def handle_info({:repository_update_check, result}, socket) do
    {:noreply, assign(socket, repository_check: result)}
  end

  def handle_info(msg, socket) do
    Logger.debug("Unexpected message: #{inspect(msg, pretty: true)}")
    {:noreply, socket}
  end

  # Private

  @language_tags (GlobalSettings.supported_languages() ++
                    [
                      {"Norwegian", "nb"},
                      {"Chinese (simplified)", "zh_Hans"},
                      {"Chinese (traditional)", "zh_Hant"}
                    ])
                 |> Enum.map(fn {key, val} -> {val, key} end)
                 |> Enum.into(%{})

  @supported_ui_languages TeslaMateWeb.Cldr.known_locale_names()
                          |> Enum.reject(&(&1 in [:zh]))
                          |> Enum.map(&String.replace(to_string(&1), "-", "_"))
                          |> Enum.map(&{Map.get(@language_tags, &1, &1), &1})
                          |> Enum.sort_by(&elem(&1, 0))

  @language_names_zh_hans %{
    "Albanian" => "阿尔巴尼亚语",
    "Arabic" => "阿拉伯语",
    "Armenian" => "亚美尼亚语",
    "Azerbaijani" => "阿塞拜疆语",
    "Belarusian" => "白俄罗斯语",
    "Bosnian" => "波斯尼亚语",
    "Breton" => "布列塔尼语",
    "Bulgarian" => "保加利亚语",
    "Catalan" => "加泰罗尼亚语",
    "Chinese" => "中文",
    "Chinese (simplified)" => "简体中文",
    "Chinese (traditional)" => "繁体中文",
    "Croatian" => "克罗地亚语",
    "Czech" => "捷克语",
    "Danish" => "丹麦语",
    "Dutch" => "荷兰语",
    "English" => "英语",
    "Estonian" => "爱沙尼亚语",
    "Finnish" => "芬兰语",
    "French" => "法语",
    "Georgian" => "格鲁吉亚语",
    "German" => "德语",
    "Greek" => "希腊语",
    "Hebrew" => "希伯来语",
    "Hungarian" => "匈牙利语",
    "Icelandic" => "冰岛语",
    "Irish" => "爱尔兰语",
    "Italian" => "意大利语",
    "Japanese" => "日语",
    "Japanese (Kana)" => "日语（假名）",
    "Japanese (Latin)" => "日语（拉丁字母）",
    "Kannada" => "卡纳达语",
    "Kazakh" => "哈萨克语",
    "Korean" => "韩语",
    "Korean (Latin)" => "韩语（拉丁字母）",
    "Latin" => "拉丁语",
    "Latvian" => "拉脱维亚语",
    "Lithuanian" => "立陶宛语",
    "Luxembourgish" => "卢森堡语",
    "Macedonian" => "马其顿语",
    "Maltese" => "马耳他语",
    "Norwegian" => "挪威语",
    "Polish" => "波兰语",
    "Portuguese" => "葡萄牙语",
    "Romania" => "罗马尼亚语",
    "Romansh" => "罗曼什语",
    "Russian" => "俄语",
    "Scottish Gaelic" => "苏格兰盖尔语",
    "Serbian (Cyrillic)" => "塞尔维亚语（西里尔字母）",
    "Serbian (Latin)" => "塞尔维亚语（拉丁字母）",
    "Slovak" => "斯洛伐克语",
    "Slovene" => "斯洛文尼亚语",
    "Spanish" => "西班牙语",
    "Swedish" => "瑞典语",
    "Thai" => "泰语",
    "Turkish" => "土耳其语",
    "Ukrainian" => "乌克兰语",
    "Welsh" => "威尔士语",
    "Western Frisian" => "西弗里西亚语"
  }

  defp supported_ui_languages, do: localize_language_options(@supported_ui_languages)

  defp supported_address_languages do
    GlobalSettings.supported_languages()
    |> localize_language_options()
  end

  defp localize_language_options(options) do
    if Gettext.get_locale() == "zh_Hans" do
      Enum.map(options, fn {name, locale} ->
        {Map.get(@language_names_zh_hans, name, name), locale}
      end)
    else
      options
    end
  end

  defp addresses_migrated? do
    alias TeslaMate.Log.{Drive, ChargingProcess}
    alias TeslaMate.Repo

    import Ecto.Query

    count_drives =
      from(d in Drive,
        select: count(),
        where:
          (is_nil(d.start_address_id) or is_nil(d.end_address_id)) and
            (not is_nil(d.start_position_id) and not is_nil(d.end_position_id))
      )

    count_charges =
      from(c in ChargingProcess,
        select: count(),
        where: is_nil(c.address_id) and not is_nil(c.position_id)
      )

    [d, c] =
      count_drives
      |> union_all(^count_charges)
      |> Repo.all()

    d + c == 0
  end

  defp add_params(socket, params) do
    push_navigate(socket, to: Routes.live_path(socket, __MODULE__, params), replace: true)
  end

  defp prepare(%GlobalSettings{} = settings) do
    %{original: settings, changeset: Settings.change_global_settings(settings)}
  end

  defp prepare(settings) do
    Enum.reduce(settings, %{}, fn %CarSettings{car: car} = s, acc ->
      Map.put(acc, car.id, %{original: s, changeset: Settings.change_car_settings(s)})
    end)
  end
end
