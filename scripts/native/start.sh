#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)

# shellcheck source=load-env.sh
. "$SCRIPT_DIR/load-env.sh"
cd "$PROJECT_DIR"
load_native_env "${1:-.env.native}"

: "${ENCRYPTION_KEY:?ENCRYPTION_KEY is required}"
: "${DATABASE_PASS:?DATABASE_PASS is required}"
: "${SECRET_KEY_BASE:?SECRET_KEY_BASE is required}"
: "${SIGNING_SALT:?SIGNING_SALT is required}"
case "$ENCRYPTION_KEY$DATABASE_PASS$SECRET_KEY_BASE$SIGNING_SALT" in
*CHANGE_ME*)
	echo "Replace every CHANGE_ME value in .env.native first." >&2
	exit 1
	;;
esac

export MIX_ENV=prod
exec mix phx.server
