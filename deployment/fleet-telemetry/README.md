# Tesla Fleet integration

The official OAuth connection is independent of the existing collector token.
The existing collector continues recording trips and charging sessions. Fleet
Telemetry supplements the battery, driving and charging dashboards.

## Configuration and deployment

1. Register the Tesla application in the correct region with authorization-code
   and client-credentials grants. Request vehicle_device_data and vehicle_location.
   Register https://APP_HOST/auth/tesla/callback as the exact redirect URI.
2. Generate a prime256v1 app signing key on the server. Publish only its PEM public
   key at /.well-known/appspecific/com.tesla.3p.public-key.pem and register the
   partner account using the region's official API.
3. Provision an independent TLS CA and receiver certificate with a DNS SAN for
   the public, direct telemetry hostname. Include the trusted CA in vehicle
   configuration. Terminate vehicle mTLS in the official receiver; do not pass it
   through an HTTP reverse proxy or Cloudflare. Leave the receiver's Tesla client
   CA verification intact. Plan certificate renewal before expiration.
4. Provision a TLS certificate for the internal fleet-proxy hostname and trust
   its CA in the application. Keep the proxy and MQTT broker off public ports.
5. Create protected app-config/client.json, proxy/, receiver/, and mqtt/ under
   TESLA_FLEET_DIR. Never commit these files. The application/proxy/receiver run
   with different identities: the application uses uid 10000 / gid 10001, while
   the proxy and receiver use uid/gid 1000. Make each configuration directory
   readable only by root and its service group. MQTT must require authentication
   with separate publisher/subscriber ACLs and persistent storage.
6. Back up PostgreSQL and the existing encryption/session keys. Build and migrate
   with both Compose files, preserving the current .env and database volume.
   Pin TESLA_COMMAND_IMAGE to the verified deployed image digest.
7. Open System Management > Tesla connection > official integration. Complete
   OAuth, pair the data key in Tesla's mobile app, then enable battery telemetry.
   Check synced status and actual arrival of vehicle data.

app-config/client.json keys:

- client_id, client_secret, region (cn/na/eu), origin
- domain (registered public-key domain)
- public_key_file (container path to public PEM)
- proxy_url (https://fleet-proxy:4443), proxy_ca_file
- telemetry_host, telemetry_port, telemetry_ca (trusted PEM CA)
- mqtt_host, mqtt_port, mqtt_username, mqtt_password

The MQTT subscriber uses fleet/+/v/+. The pinned official receiver source is
adapted only at MQTT serialization to publish
{"value": FIELD_VALUE, "created_at": VEHICLE_RFC3339_TIME} for each retained field.
This preserves per-field timestamps through broker/application/VPS restarts.
QoS 1 and a persistent MQTT volume provide replay; database upserts reject old
or duplicate timestamps. Malformed, future-dated or unauthorized-VIN messages
are rejected. Missing and invalid values are never displayed as zero.

OAuth state is single-use, expires in 10 minutes and is bound to the initiating
admin session. A narrowly scoped encrypted SameSite=Lax callback cookie permits
Tesla's cross-site return without weakening the application's Strict session
cookie. After validating the administrator session, the callback returns a
200 confirmation document before navigating within this site. This breaks the
cross-site redirect chain so browsers send the Strict login cookie on the next
request. The callback uses no-store and no-referrer headers. Fleet tokens are
encrypted using the existing vault and serialized refresh writes preserve token
rotation. Credentials are never rendered to the browser.

## Updating

Update the pinned official receiver commit deliberately, inspect its MQTT
serialization and rerun the timestamp/replay/invalid-value tests. The adapter
fails closed if its source anchor changes. Retain signing keys, CA keys, MQTT
volume and database records during upgrades. Do not recreate private keys or
delete volumes to resolve a connection problem.

OAuth/telemetry registration alone does not grant new vehicle features or
camera video access. Hardware, firmware, region, vehicle pairing and Tesla
usage limits still apply. A missing vehicle signal is not an implementation
or sensor error by itself.

## Temperature readings

Battery, driving and charging pages have a dedicated temperature panel. Module
minimum/maximum temperatures and their matching module identifiers come from
thermal sensors; they are not a complete array of individual cell temperatures.
The cabin/outside difference is signed and requires the same source timestamp
and source type. Module differences also require matching sample times.

InsideTemp/OutsideTemp and HvacLeftTemperatureRequest/HvacRightTemperatureRequest
supplement the existing climate API. Driver/passenger setpoints from the legacy
API are labelled separately from left/right telemetry setpoints, so right-hand
drive cars are not silently mapped to the wrong side. Saved climate positions
provide a historical fallback after a collector restart.

DiStatorTempF/R/REL/RER, DiInverterTF/TR/TREL/TRER and
DiHeatsinkTF/TR/TREL/TRER add stator, inverter outlet and inverter heatsink
temperatures. Separate rear-left/right drive-unit readings appear when reported.
Temperatures are displayed in Celsius with a source timestamp; zero and negative
temperatures are valid. Unsupported or invalid signals stay unknown, and stale
readings retain their original time. No thermal warning threshold or estimated
battery temperature is invented.

Update the vehicle telemetry configuration after upgrading to request these
fields. A paired application key is required; changing the dashboard alone does
not activate the vehicle feed. Temperature fields are requested no more frequently
than every 10 seconds, even when the page refresh interval is shorter.

Field definitions: https://developer.tesla.com/docs/fleet-api/fleet-telemetry/available-data

## Energy history and page ownership

EnergyRemaining, Soc, NominalFullPackEnergyKwh and the AC/DC session energy counters are stored in the additive fleet_energy_samples table. Retained messages preserve vehicle timestamps, duplicates do not create new samples, and invalid values remain null. Existing drives, charges and user-entered prices are never overwritten.

Completed trips share one calculation in list, route detail, home, driving and analysis. Official battery energy differences take precedence only with valid samples inside both boundaries (at most 30 seconds from each boundary and at least 90% time coverage). Missing historical coverage uses the selected legacy range coefficient. A paired key alone does not make historical estimates official measurements. EnergyRemaining is a nominal battery estimate and can change with BMS recalibration; LifetimeEnergyUsed is not treated as net trip consumption.

DCChargingEnergyIn is battery-side energy for both AC and DC sessions. ACChargingEnergyIn is used only for confirmed AC sessions. Session counters must start near zero, cover both boundaries and never reset or become invalid. Input losses require both counters to describe the same interval, within one second at each boundary; missing or inconsistent measurements remain unknown. The AC input/battery difference includes conversion and auxiliary loads, and is not battery degradation or a complete wall-meter measurement.

Battery trends prefer reported nominal full-pack energy, then same-timestamp EnergyRemaining/Soc estimates at 20–95% SOC, then normalized rated range. Sources are never mixed in a curve or baseline. Seven distinct sample days are required to compare the early and recent periods; results are not factory-relative degradation or official SOH.

Battery diagnostics belong to the battery page, drivetrain and cabin readings to driving, and charging parameters/costs to charging. Valid ordinary readings remain visible. Diagnostics and unavailable optional readings are expandable with state retained across LiveView refreshes.
