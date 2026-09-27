defmodule TeslaMate.Repo.Migrations.CreateCaptchaSettings do
  use Ecto.Migration

  def change do
    create table(:captcha_settings, primary_key: false, prefix: "private") do
      add :id, :integer, primary_key: true
      add :provider, :string
      add :profiles, :binary
      add :revision, :integer, null: false, default: 0
      timestamps()
    end

    create constraint(:captcha_settings, :captcha_settings_singleton,
             check: "id = 1",
             prefix: "private"
           )

    create constraint(:captcha_settings, :captcha_settings_provider,
             check: "provider IS NULL OR provider IN ('cloudflare', 'aliyun', 'tencent')",
             prefix: "private"
           )

    # NULL preserves the existing environment-based Turnstile policy on upgrade.
    execute(
      "INSERT INTO private.captcha_settings (id, revision, inserted_at, updated_at) VALUES (1, 0, NOW(), NOW())",
      "DELETE FROM private.captcha_settings WHERE id = 1"
    )
  end
end
