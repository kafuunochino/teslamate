defmodule TeslaMate.Repo.Migrations.AccountLifecycle do
  use Ecto.Migration

  def up do
    alter table(:users, prefix: "private") do
      add :is_system_admin, :boolean, null: false, default: false
      add :deletion_requested_at, :utc_datetime_usec
      add :deletion_scheduled_at, :utc_datetime_usec
    end

    alter table(:cars) do
      add :account_archived_at, :utc_datetime_usec
    end

    flush()

    execute("""
    DO $$
    DECLARE first_id bigint;
    BEGIN
      SELECT id INTO first_id FROM private.users ORDER BY inserted_at, id LIMIT 1;
      DELETE FROM private.user_sessions WHERE user_id IN (
        SELECT id FROM private.users WHERE
          (id = first_id AND (role <> 'admin' OR status <> 'active')) OR
          (id <> first_id AND role = 'admin')
      );
      UPDATE private.users
      SET auth_version = auth_version + 1
      WHERE (id = first_id AND (role <> 'admin' OR status <> 'active')) OR
            (id <> first_id AND role = 'admin');
      UPDATE private.users SET role = 'member' WHERE id <> first_id AND role = 'admin';
      UPDATE private.users SET is_system_admin = true, role = 'admin', status = 'active'
      WHERE id = first_id;
    END $$;
    """)

    create unique_index(:users, [:is_system_admin],
             prefix: "private",
             where: "is_system_admin",
             name: :users_single_system_admin
           )

    create constraint(:users, :users_system_admin_role,
             prefix: "private",
             check: """
             (is_system_admin AND role = 'admin' AND status = 'active'
               AND deletion_requested_at IS NULL AND deletion_scheduled_at IS NULL)
             OR (NOT is_system_admin AND role = 'member')
             """
           )

    create constraint(:users, :users_deletion_window,
             prefix: "private",
             check: """
             (deletion_requested_at IS NULL AND deletion_scheduled_at IS NULL) OR
             (deletion_requested_at IS NOT NULL AND deletion_scheduled_at IS NOT NULL
               AND deletion_scheduled_at > deletion_requested_at)
             """
           )

    create index(:users, [:deletion_scheduled_at],
             prefix: "private",
             where: "deletion_scheduled_at IS NOT NULL"
           )

    execute("""
    CREATE FUNCTION private.protect_system_administrator() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'INSERT' THEN
        PERFORM pg_advisory_xact_lock(847300001);
        IF NOT EXISTS (SELECT 1 FROM private.users) THEN
          NEW.is_system_admin := true;
          NEW.role := 'admin';
          NEW.status := 'active';
        ELSIF NEW.is_system_admin OR NEW.role <> 'member' THEN
          RAISE EXCEPTION 'Only the first account is the system administrator'
            USING ERRCODE = '23514', CONSTRAINT = 'users_single_system_admin';
        END IF;
        RETURN NEW;
      ELSIF TG_OP = 'DELETE' THEN
        IF OLD.is_system_admin THEN
          RAISE EXCEPTION 'The system administrator cannot be deleted'
            USING ERRCODE = '23514', CONSTRAINT = 'users_system_admin_protected';
        END IF;
        RETURN OLD;
      ELSE
        IF NEW.id IS DISTINCT FROM OLD.id OR
           NEW.is_system_admin IS DISTINCT FROM OLD.is_system_admin THEN
          RAISE EXCEPTION 'The system administrator identity is permanent'
            USING ERRCODE = '23514', CONSTRAINT = 'users_system_admin_protected';
        END IF;
        RETURN NEW;
      END IF;
    END $$;
    """)

    execute("""
    CREATE TRIGGER users_protect_system_administrator
    BEFORE INSERT OR UPDATE OR DELETE ON private.users
    FOR EACH ROW EXECUTE FUNCTION private.protect_system_administrator()
    """)
  end

  def down do
    raise "Account lifecycle and administrator identity must be restored from a verified backup."
  end
end
