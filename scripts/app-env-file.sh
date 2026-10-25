# Optional per-app environment on the data partition: /data/app-config/<app>/env (survives APP partition updates,
# cleared by a factory reset). Applied after the manifest env, so it can override it. Format: KEY=value lines;
# blank lines and lines starting with # are ignored; the value is taken literally (no quotes, no $ expansion, no
# shell): this file is never evaluated. Keys must be shell variable names.
# (scripts/app-env-file.sh, spliced into every generated startup script by build-app-partition.sh)
APP_ENV_FILE="${APP_CONFIG_DIR}/env"
if [ -f "$APP_ENV_FILE" ]; then
    while IFS= read -r env_line || [ -n "$env_line" ]; do
        case "$env_line" in ''|'#'*) continue ;; esac
        env_key="${env_line%%=*}"
        env_value="${env_line#*=}"
        if [ "$env_key" = "$env_line" ]; then
            echo "${APP_ENV_FILE}: skipping a line without '='" >&2
            continue
        fi
        case "$env_key" in
            ''|[0-9]*|*[!A-Za-z0-9_]*) echo "${APP_ENV_FILE}: skipping invalid name '${env_key}'" >&2; continue ;;
        esac
        export "${env_key}=${env_value}"
    done < "$APP_ENV_FILE"
    unset env_line env_key env_value
fi
