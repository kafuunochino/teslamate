# TeslaMate CN unified vehicle platform

[简体中文主说明](README.md) · [Lossless 1Panel upgrade guide (Chinese)](UPGRADE.zh-CN.md) · [Security model (Chinese)](PLATFORM_SECURITY.zh-CN.md)

This community fork keeps TeslaMate's proven collector, MQTT integration, and PostgreSQL telemetry schema, while providing a new multi-user Phoenix LiveView application. The home dashboard, trips, battery, charging, analytics, accounts, and per-vehicle authorization are served by one application on `127.0.0.1:3000`. Port 4000 and a public Grafana service are no longer part of the default deployment.

This is not the official `teslamate-org/teslamate` distribution. Review the changes and deployment documentation before giving it Tesla credentials or vehicle location data. The official upstream project and documentation remain available at [github.com/teslamate-org/teslamate](https://github.com/teslamate-org/teslamate) and [docs.teslamate.org](https://docs.teslamate.org/).

## What is included

- A responsive, categorized UI for current vehicle data, location, trips, routes, battery trends, charging, cost, and explainable usage analytics.
- Platform registration and password login. Registration can be disabled at runtime.
- An administrator role that can see all collected vehicles and manage users.
- Member accounts that can only query explicitly assigned vehicles.
- One-time, expiring vehicle claim codes. The raw code is shown once and only a SHA-256 hash is stored.
- Authorization-aware trip and GPX queries to prevent cross-tenant IDOR access.
- Additive migrations in the existing `private` PostgreSQL schema; existing cars, positions, drives, charges, geofences, addresses, and encrypted Tesla tokens are retained.
- A disabled `legacy-grafana` Compose profile that preserves the existing `teslamate-grafana-data` volume without publishing a host port.

## Runtime architecture

| Component   | Default deployment                                                 |
| ----------- | ------------------------------------------------------------------ |
| `teslamate` | Collector plus unified web application on container/host port 3000 |
| PostgreSQL  | Existing external `postgres:5432` for the 1Panel Compose file      |
| Mosquitto   | Internal Docker network only; no host port                         |
| Grafana     | Disabled compatibility profile; no host port                       |

The 1Panel Compose file never creates or replaces PostgreSQL. It joins `${PANEL_NETWORK:-1panel-network}` so that the existing `postgres` hostname remains resolvable.

## Required configuration

Copy `.env.example` to `.env` and preserve it with mode 600. Production requires stable, independent values for:

```text
DATABASE_PASS
ENCRYPTION_KEY
SECRET_KEY_BASE
SIGNING_SALT
```

Never commit `.env`. Do not change `ENCRYPTION_KEY` on an existing deployment, because it protects the stored Tesla access and refresh tokens.

For an HTTPS reverse proxy, configure the real host/origin and trusted proxy network:

```dotenv
VIRTUAL_HOST=car.example.com
CHECK_ORIGIN=https://car.example.com
TESLAMATE_TRUSTED_PROXIES=the proxy IP or CIDR
TESLAMATE_API_ORIGIN_CHECK=true
```

The only published port is:

```yaml
ports:
  - "127.0.0.1:3000:3000"
```

## First administrator

After the container has migrated the database, create or reset the first administrator without putting a plaintext password in shell history:

```bash
read -r -p 'Administrator email: ' ADMIN_EMAIL
read -r -s -p 'New password (12+ characters): ' ADMIN_PASSWORD
printf '\n'

docker compose -f docker-compose.1panel.yml exec \
  -e TESLAMATE_ADMIN_EMAIL="$ADMIN_EMAIL" \
  -e TESLAMATE_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
  -e TESLAMATE_ADMIN_NAME="Platform administrator" \
  teslamate bin/teslamate eval 'TeslaMate.Release.create_admin_from_env()'

unset ADMIN_PASSWORD
```

Sign in at `/sign_in`. Tesla collector credentials are managed separately on the administrator-only Tesla connection page.

## Safety rules

Do not run any of the following during an upgrade:

```bash
docker compose down -v
docker volume rm teslamate-grafana-data
rm -rf /var/lib/grafana
```

Back up the external PostgreSQL database before pulling or rebuilding. The complete port handover, database verification, account bootstrap, authorization acceptance test, and non-destructive rollback procedure are documented in [UPGRADE.zh-CN.md](UPGRADE.zh-CN.md).

## License and attribution

TeslaMate and this fork are licensed under the [GNU Affero General Public License v3.0](LICENSE). Original copyright, license, and trademark notices remain in the repository. The TeslaMate name and logo are subject to the upstream [Trademark Policy](TRADEMARK.md).
