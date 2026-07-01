#!/usr/bin/env sh

# Load a simple KEY=VALUE file without evaluating command substitutions or shell code.
load_native_env() {
	env_file=${1:-.env.native}

	if [ ! -f "$env_file" ]; then
		echo "Missing $env_file; copy .env.native.example and fill in the secrets." >&2
		return 1
	fi

	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
		'' | '#'*)
			continue
			;;
		esac
		case "$line" in
		*=*) ;;
		*)
			echo "Invalid environment entry in $env_file: $line" >&2
			return 1
			;;
		esac

		key=${line%%=*}
		value=${line#*=}

		case "$key" in
		'' | [0-9]* | *[!A-Za-z0-9_]*)
			echo "Invalid environment variable name in $env_file: $key" >&2
			return 1
			;;
		esac

		export "$key=$value"
	done <"$env_file"
}
