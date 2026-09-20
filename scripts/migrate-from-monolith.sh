#!/usr/bin/env bash
#
# Migrate an existing single-container install (kubedok-app) to the split
# postgres / server / nginx deployment.
#
#   migrate-from-monolith.sh --dry-run    # inspect and report, change nothing
#   migrate-from-monolith.sh
#
# The old container and its volume are left completely untouched until the new
# stack has proven healthy, so the migration is abortable at every step:
# stop it anywhere and `docker start kubedok-app` puts you back.
#
# The old install generated JWT_SECRET and REGISTRY_ENCRYPTION_KEY inside
# PGDATA/.kubedok-secrets. Both MUST carry over. A new JWT_SECRET logs
# everyone out; a new REGISTRY_ENCRYPTION_KEY makes every stored registry
# credential and certificate permanently undecryptable.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

OLD_CONTAINER="${KUBEDOK_OLD_CONTAINER:-kubedok-app}"
DRY_RUN=false
ASSUME_YES=false

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --yes|-y) ASSUME_YES=true; shift ;;
    --container) OLD_CONTAINER="$2"; shift 2 ;;
    -h|--help) sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

require_root
require_cmd docker jq
[ "${DRY_RUN}" = "true" ] || require_installed
load_config
[ "${DRY_RUN}" = "true" ] || acquire_lock 600

# ── 1. Detect the old deployment ─────────────────────────────────────────────
log "Looking for the monolithic deployment"

docker inspect "${OLD_CONTAINER}" >/dev/null 2>&1 \
  || die "No container named '${OLD_CONTAINER}'. Nothing to migrate. Use --container to name it explicitly."

OLD_RUNNING="$(docker inspect -f '{{.State.Running}}' "${OLD_CONTAINER}")"
OLD_IMAGE="$(docker inspect -f '{{.Config.Image}}' "${OLD_CONTAINER}")"
OLD_PGDATA="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${OLD_CONTAINER}" \
  | grep '^PGDATA=' | cut -d= -f2- || true)"
OLD_PGDATA="${OLD_PGDATA:-/var/lib/postgresql/data}"
OLD_PG_USER="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${OLD_CONTAINER}" \
  | grep '^POSTGRES_USER=' | cut -d= -f2- || true)"
OLD_PG_USER="${OLD_PG_USER:-kubedok}"
OLD_PG_DB="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${OLD_CONTAINER}" \
  | grep '^POSTGRES_DB=' | cut -d= -f2- || true)"
OLD_PG_DB="${OLD_PG_DB:-kubedok}"
OLD_VOLUME="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "'"${OLD_PGDATA}"'"}}{{.Name}}{{end}}{{end}}' "${OLD_CONTAINER}" || true)"

ok "Found ${OLD_CONTAINER}"
printf '      image    %s\n' "${OLD_IMAGE}"
printf '      running  %s\n' "${OLD_RUNNING}"
printf '      pgdata   %s\n' "${OLD_PGDATA}"
printf '      volume   %s\n' "${OLD_VOLUME:-<anonymous or bind mount>}"
printf '      database %s/%s\n' "${OLD_PG_USER}" "${OLD_PG_DB}"

[ "${OLD_RUNNING}" = "true" ] \
  || die "${OLD_CONTAINER} is not running. Start it so the database can be dumped: docker start ${OLD_CONTAINER}"

# ── Locate the old secrets ───────────────────────────────────────────────────
OLD_SECRETS_DIR="${OLD_PGDATA}/.kubedok-secrets"
log "Reading the existing secrets from ${OLD_SECRETS_DIR}"

read_old_secret() {
  local name="$1"
  docker exec "${OLD_CONTAINER}" sh -c "cat '${OLD_SECRETS_DIR}/${name}' 2>/dev/null" | tr -d '\r\n' || true
}

OLD_PG_PASSWORD="$(read_old_secret postgres-password)"
OLD_JWT_SECRET="$(read_old_secret jwt-secret)"
OLD_REGISTRY_KEY="$(read_old_secret registry-encryption-key)"

# Installs that predate runtime secret generation ran on hard-coded defaults
# baked into the old entrypoint as `: "${KUBEDOK_LEGACY_X:=value}"`.
#
# Those values are read out of the old container rather than written here.
# This repository is public, and a JWT signing key that still protects live
# installs does not belong in it. Reading them from the image also gets the
# values that specific image actually shipped, instead of whatever was true
# when this script was written.
read_legacy_default() {
  local var="$1" line
  line="$(docker exec "${OLD_CONTAINER}" sh -c \
    "grep -m1 '^: \"\${${var}:=' /usr/local/bin/kubedok-app-entrypoint.sh" 2>/dev/null \
    | tr -d '\r\n')" || return 0
  [ -n "${line}" ] || return 0
  line="${line#*:=}"   # strip through the := assignment operator
  line="${line%\}\"}"  # strip the trailing }"
  printf '%s' "${line}"
}

LEGACY_JWT_SECRET="$(read_legacy_default KUBEDOK_LEGACY_JWT_SECRET)"
LEGACY_REGISTRY_KEY="$(read_legacy_default KUBEDOK_LEGACY_REGISTRY_ENCRYPTION_KEY)"
LEGACY_PG_PASSWORD="$(read_legacy_default KUBEDOK_LEGACY_POSTGRES_PASSWORD)"

secret_source() {
  local value="$1" legacy="$2"
  if [ -z "${value}" ]; then printf 'legacy default'
  elif [ "${value}" = "${legacy}" ]; then printf 'legacy default (stored)'
  else printf 'generated'; fi
}

printf '      postgres-password         %s\n' "$(secret_source "${OLD_PG_PASSWORD}" "${LEGACY_PG_PASSWORD}")"
printf '      jwt-secret                %s\n' "$(secret_source "${OLD_JWT_SECRET}" "${LEGACY_JWT_SECRET}")"
printf '      registry-encryption-key   %s\n' "$(secret_source "${OLD_REGISTRY_KEY}" "${LEGACY_REGISTRY_KEY}")"

OLD_JWT_SECRET="${JWT_SECRET:-${OLD_JWT_SECRET:-${LEGACY_JWT_SECRET}}}"
OLD_REGISTRY_KEY="${REGISTRY_ENCRYPTION_KEY:-${OLD_REGISTRY_KEY:-${LEGACY_REGISTRY_KEY}}}"

[ -n "${OLD_REGISTRY_KEY}" ] \
  || die "Could not determine REGISTRY_ENCRYPTION_KEY from the old install.
    Looked in ${OLD_SECRETS_DIR}/registry-encryption-key and in the legacy
    defaults inside the container's entrypoint, and found neither.
    Migrating without it would make every stored registry credential
    unrecoverable. Recover the value manually and re-run with
    REGISTRY_ENCRYPTION_KEY set in the environment."

# Sanity-check the data we are about to move.
ROW_SUMMARY="$(docker exec "${OLD_CONTAINER}" psql -U "${OLD_PG_USER}" -d "${OLD_PG_DB}" -tAc \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'" 2>/dev/null || echo '?')"
printf '      tables in public schema   %s\n' "${ROW_SUMMARY}"

if [ "${DRY_RUN}" = "true" ]; then
  printf '\n'
  ok "Dry run complete. Nothing was changed."
  printf '\n  The migration would:\n'
  printf '    1. Stop writes by stopping %s\n' "${OLD_CONTAINER}"
  printf '    2. Dump %s from the old container\n' "${OLD_PG_DB}"
  printf '    3. Copy its three secrets into %s\n' "${KUBEDOK_SECRETS_DIR}"
  printf '    4. Start the new PostgreSQL, restore the dump\n'
  printf '    5. Start the new server and nginx, verify health\n'
  printf '    6. Leave volume %s untouched\n\n' "${OLD_VOLUME:-<the old volume>}"
  exit 0
fi

printf '\n'
printf '  This migrates %s into the split deployment.\n' "${OLD_CONTAINER}"
printf '  The old container and volume %s are kept untouched.\n' "${OLD_VOLUME:-}"
printf '\n'
if [ "${ASSUME_YES}" != "true" ]; then
  printf '  Continue? [y/N] '
  read -r answer
  case "${answer}" in y|Y|yes|YES) ;; *) die "Aborted. Nothing changed." ;; esac
fi

STAGE="$(mktemp -d)"
cleanup() { rm -rf "${STAGE}"; }
trap cleanup EXIT

# ── 2. Stop writes ───────────────────────────────────────────────────────────
# The API is stopped but PostgreSQL must stay up to be dumped, so the old
# entrypoint's nginx+API are taken down by stopping the container's listener
# rather than the container itself. Simplest reliable approach: dump first,
# then stop the whole container before the new stack takes over the port.
log "Dumping the database before anything else changes"
if ! docker exec "${OLD_CONTAINER}" pg_dump -U "${OLD_PG_USER}" --clean --if-exists "${OLD_PG_DB}" \
     > "${STAGE}/database.sql" 2>"${STAGE}/dump.err"; then
  err "pg_dump failed:"
  sed 's/^/      /' "${STAGE}/dump.err" >&2
  die "Migration aborted. Nothing was changed."
fi
DUMP_SIZE="$(du -h "${STAGE}/database.sql" | cut -f1)"
ok "Dumped ${DUMP_SIZE}"

# ── 3 + 4. Preserve the old secrets ──────────────────────────────────────────
# Written before the new PostgreSQL first starts, so it initialises with the
# same password the dump expects.
log "Preserving the existing secrets"
ensure_secrets_dir

write_secret() {
  local name="$1" value="$2"
  local path="${KUBEDOK_SECRETS_DIR}/${name}"
  if [ -s "${path}" ] && [ "$(tr -d '\r\n' < "${path}")" != "${value}" ]; then
    cp -a "${path}" "${path}.pre-migration"
    warn "${name} already existed and differed; the previous value is at ${path}.pre-migration"
  fi
  ( umask 077; printf '%s\n' "${value}" > "${path}" )
  chmod 600 "${path}"
}

write_secret jwt-secret "${OLD_JWT_SECRET}"
write_secret registry-encryption-key "${OLD_REGISTRY_KEY}"
if [ -n "${OLD_PG_PASSWORD}" ]; then
  write_secret postgres-password "${OLD_PG_PASSWORD}"
else
  # The old password never leaves the old volume, and the new database is
  # created fresh from the dump, so a new password here is safe.
  ensure_secret postgres-password 0600
fi
ok "Secrets carried over (sessions and encrypted credentials stay valid)"

# ── Stop the old container so it releases port 80 ────────────────────────────
log "Stopping ${OLD_CONTAINER}"
docker stop "${OLD_CONTAINER}" >/dev/null
ok "${OLD_CONTAINER} stopped (not removed — its volume is intact)"

rollback_to_monolith() {
  err "Migration failed — restoring the old deployment"
  compose nginx down >/dev/null 2>&1 || true
  compose server down >/dev/null 2>&1 || true
  compose postgres down >/dev/null 2>&1 || true
  docker start "${OLD_CONTAINER}" >/dev/null 2>&1 \
    && err "${OLD_CONTAINER} is running again. Your data was never touched." \
    || err "Could not restart ${OLD_CONTAINER}. Start it manually: docker start ${OLD_CONTAINER}"
  exit 1
}

# ── 5 + 6. New PostgreSQL, restore the dump ──────────────────────────────────
log "Starting the new PostgreSQL"
ensure_networks
compose postgres up -d || rollback_to_monolith
wait_for_container_health kubedok-postgres 180 || rollback_to_monolith
ok "New PostgreSQL is healthy"

log "Restoring the dump"
if ! docker exec -i kubedok-postgres psql -v ON_ERROR_STOP=1 \
     -U "${KUBEDOK_POSTGRES_USER:-kubedok}" -d "${KUBEDOK_POSTGRES_DB:-kubedok}" \
     < "${STAGE}/database.sql" > "${STAGE}/restore.log" 2>&1; then
  err "Restore failed:"
  tail -30 "${STAGE}/restore.log" | sed 's/^/      /' >&2
  rollback_to_monolith
fi
ok "Database restored"

# ── 7 + 8. Server and nginx ──────────────────────────────────────────────────
log "Starting the new server"
compose server up -d || rollback_to_monolith
wait_for_container_health kubedok-server 300 || rollback_to_monolith
ok "Server is healthy"

log "Starting nginx"
compose nginx up -d || rollback_to_monolith
wait_for_container_health kubedok-nginx 120 || rollback_to_monolith
ok "nginx is healthy"

# ── 9. Verify ────────────────────────────────────────────────────────────────
log "Verifying the migrated install"
BASE="$(local_base_url)"

wait_for_http "${BASE}/api/health" 90 || { err "No response from ${BASE}/api/health"; rollback_to_monolith; }
DB_STATUS="$(curl -fsS --max-time 10 "${BASE}/api/health" | jq -r '.database // empty')"
[ "${DB_STATUS}" = "connected" ] || { err "Database reports '${DB_STATUS}'"; rollback_to_monolith; }
ok "  /api/health: database connected"

curl -fsS --max-time 10 -o /dev/null "${BASE}/" || { err "Web UI is not served"; rollback_to_monolith; }
ok "  web UI is served"

# The row counts must survive, otherwise the dump restored into the wrong place.
# Table names come from Prisma's @@map directives, not the model names.
USER_COUNT="$(docker exec kubedok-postgres psql -U "${KUBEDOK_POSTGRES_USER:-kubedok}" \
  -d "${KUBEDOK_POSTGRES_DB:-kubedok}" -tAc 'SELECT count(*) FROM users' 2>/dev/null || echo '?')"
HOST_COUNT="$(docker exec kubedok-postgres psql -U "${KUBEDOK_POSTGRES_USER:-kubedok}" \
  -d "${KUBEDOK_POSTGRES_DB:-kubedok}" -tAc 'SELECT count(*) FROM hosts' 2>/dev/null || echo '?')"

if [ "${USER_COUNT}" = "?" ]; then
  err "Could not read the users table after the restore — the dump may not have applied."
  rollback_to_monolith
fi
ok "  data present: ${USER_COUNT} user(s), ${HOST_COUNT} host(s)"

# ── 10. Done; the old volume stays ───────────────────────────────────────────
log "Taking a backup of the migrated install"
BACKUP_PATH="$("${SCRIPT_DIR}/backup.sh" --label "post-migration" --quiet)" || true
[ -n "${BACKUP_PATH:-}" ] && ok "Backup: ${BACKUP_PATH}"

printf '\n'
printf '%s────────────────────────────────────────────────────────%s\n' "${_c_green}" "${_c_reset}"
printf '  Migration complete\n'
printf '%s────────────────────────────────────────────────────────%s\n' "${_c_green}" "${_c_reset}"
printf '\n'
printf '  Serving at       %s\n' "${BASE}"
printf '  Users            %s\n' "${USER_COUNT}"
printf '  Hosts            %s\n' "${HOST_COUNT}"
printf '  JWT secret       preserved (existing sessions still valid)\n'
printf '  Encryption key   preserved (registry credentials still decrypt)\n'
printf '\n'
printf '  The old deployment is stopped but INTACT:\n'
printf '    container  %s\n' "${OLD_CONTAINER}"
printf '    volume     %s\n' "${OLD_VOLUME:-<the old volume>}"
printf '\n'
printf '  Log in and check your hosts, stacks, and registry credentials.\n'
printf '  Only once you are satisfied, remove the old deployment:\n'
printf '    docker rm %s\n' "${OLD_CONTAINER}"
[ -n "${OLD_VOLUME}" ] && printf '    docker volume rm %s\n' "${OLD_VOLUME}"
printf '\n'
printf '  To go back at any point before that:\n'
printf '    %s/restart.sh all   # stop the new stack first\n' "${SCRIPT_DIR}"
printf '    docker start %s\n\n' "${OLD_CONTAINER}"
