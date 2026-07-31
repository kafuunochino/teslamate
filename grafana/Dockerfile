# Ensure selecting a tag that is available for arm64 and amd64
# https://hub.docker.com/r/grafana/grafana/tags
FROM grafana/grafana:13.0.1-security-01

# The optional legacy container keeps its own direct login and cannot be
# embedded into the unified platform.
ENV GF_ANALYTICS_REPORTING_ENABLED=false \
    GF_ANALYTICS_CHECK_FOR_UPDATES=false \
    GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES=false \
    GF_ANALYTICS_FEEDBACK_LINKS_ENABLED=false \
    GF_AUTH_ANONYMOUS_ENABLED=false \
    GF_AUTH_BASIC_ENABLED=true \
    GF_AUTH_PROXY_ENABLED=false \
    GF_AUTH_DISABLE_LOGIN_FORM=false \
    GF_AUTH_DISABLE_SIGNOUT_MENU=false \
    GF_SECURITY_ALLOW_EMBEDDING=false \
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
