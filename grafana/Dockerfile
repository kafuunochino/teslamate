# Ensure selecting a tag that is available for arm64 and amd64
# https://hub.docker.com/r/grafana/grafana/tags
FROM grafana/grafana:13.0.1-security-01

# When GF_DEFAULT_APP_MODE is "production" Grafana hides the top nav and the "Sign out"
# menu so that it blends nicely when embedded as an iframe under TeslaMate's reverse
# proxy at /dashboards. The TeslaMate Plug forces a signed-in user via the auth
# proxy headers (GF_AUTH_PROXY_*) so we keep login form disabled locally.
ENV GF_ANALYTICS_REPORTING_ENABLED=false \
    GF_ANALYTICS_CHECK_FOR_UPDATES=false \
    GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES=false \
    GF_ANALYTICS_FEEDBACK_LINKS_ENABLED=false \
    GF_AUTH_ANONYMOUS_ENABLED=true \
    GF_AUTH_ANONYMOUS_ORG_NAME="TeslaMate" \
    GF_AUTH_ANONYMOUS_ORG_ROLE=Editor \
    GF_AUTH_BASIC_ENABLED=false \
    GF_AUTH_PROXY_ENABLED=true \
    GF_AUTH_PROXY_HEADER_NAME=X-Teslamate-User \
    GF_AUTH_PROXY_HEADER_PROPERTY=username \
    GF_AUTH_PROXY_AUTO_SIGN_UP=true \
    GF_AUTH_PROXY_ENABLE_LOGIN_TOKEN=false \
    GF_AUTH_PROXY_SYNC_ATTRIBUTES=false \
    GF_AUTH_DISABLE_LOGIN_FORM=true \
    GF_AUTH_DISABLE_SIGNOUT_MENU=true \
    GF_DEFAULT_APP_MODE=production \
    GF_SECURITY_ADMIN_PASSWORD=admin \
    GF_SECURITY_ADMIN_USER=admin \
    GF_SECURITY_ALLOW_EMBEDDING=true \
    GF_SECURITY_COOKIE_SAMESITE=strict \
    GF_SECURITY_DISABLE_GRAVATAR=true \
    GF_SECURITY_XSS_PROTECTION_HEADER=true \
    GF_DATABASE_HIGH_AVAILABILITY=false \
    GF_USERS_ALLOW_SIGN_UP=false \
    GF_USERS_DEFAULT_LANGUAGE=zh-Hans \
    GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/dashboards/internal/home.json \
    GF_DATE_FORMATS_USE_BROWSER_LOCALE=true \
    GF_PLUGINS_PREINSTALL_DISABLED=true \
    GF_UNIFIED_ALERTING_ENABLED=false \
    GF_METRICS_ENABLED=false \
    GF_RECORDING_RULES_ENABLED=false \
    GF_CLOUD_MIGRATION_ENABLED=false \
    GF_FEATURE_TOGGLES_splashScreen=false \
    DATABASE_PORT=5432 \
    DATABASE_SSL_MODE=disable

USER grafana

COPY logo.svg /usr/share/grafana/public/build/img/grafana_icon.svg

RUN LOGO_PATH=$(find /usr/share/grafana/public/build/static/img/ -type f -name 'grafana_icon.*.svg') && \
    cp /usr/share/grafana/public/build/img/grafana_icon.svg "$LOGO_PATH" || true

COPY favicon.png /usr/share/grafana/public/build/img/fav32.png
COPY apple-touch-icon.png /usr/share/grafana/public/build/img/apple-touch-icon.png

COPY datasource.yml /etc/grafana/provisioning/datasources/
COPY dashboards.yml /etc/grafana/provisioning/dashboards/
COPY dashboards/ /dashboards/

EXPOSE 3000
