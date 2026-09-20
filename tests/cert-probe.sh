#!/usr/bin/env bash
#
# Regression test for the ACME pre-flight in scripts/cert-renew.sh.
#
#   tests/cert-probe.sh
#
# integration.sh runs with KUBEDOK_TLS=off, so nothing there exercises the
# probe that gates certificate issuance. That gap let release 1.4.0 ship a
# probe that wrote its marker one directory too high: nginx answered 404 and
# every correctly configured install was told its port 80 was firewalled.
#
# How it works
# ------------
# The real nginx image starts in TLS-requested mode with no certificate,
# exactly the pre-issuance state setup.sh puts it in. cert-renew.sh --issue
# then runs from this working tree inside a throwaway Linux runner on the same
# Docker network, where a stub `docker` binary stands in for the certbot
# container. Let's Encrypt is never contacted; the test ends where certbot
# would begin.
set -Eeuo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORK="${KUBEDOK_TEST_WORK:-/private/tmp/kubedok-cert-probe}"
NGINX_IMAGE="${KUBEDOK_TEST_NGINX_IMAGE:-kubedok-nginx:dev}"
NET="kubedok-cert-probe"
NGINX="kubedok-cert-probe-nginx"
RUNNER="kubedok-cert-probe-runner"
HOST="acme.test"

PASS=0
FAIL=0

c_green=$'\033[32m'; c_red=$'\033[31m'; c_blue=$'\033[34m'; c_dim=$'\033[2m'; c_off=$'\033[0m'

step()  { printf '\n%s▸ %s%s\n' "${c_blue}" "$*" "${c_off}"; }
pass()  { printf '  %s✓%s %s\n' "${c_green}" "${c_off}" "$*"; PASS=$((PASS+1)); }
fails() { printf '  %s✗%s %s\n' "${c_red}" "${c_off}" "$*"; FAIL=$((FAIL+1)); }
info()  { printf '  %s%s%s\n' "${c_dim}" "$*" "${c_off}"; }
abort() { printf '\n%sABORT:%s %s\n\n' "${c_red}" "${c_off}" "$*"; exit 1; }

cleanup() {
  docker rm -f "${NGINX}" "${RUNNER}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  rm -rf "${WORK}" 2>/dev/null || true
}
trap cleanup EXIT

# ── Preflight ────────────────────────────────────────────────────────────────
step 'Preflight'
command -v docker >/dev/null || abort 'docker is required'
docker info >/dev/null 2>&1 || abort 'the Docker daemon is not reachable'
docker image inspect "${NGINX_IMAGE}" >/dev/null 2>&1 \
  || abort "Missing image ${NGINX_IMAGE}.
    Build it from the application repository, github.com/glikaj/kubedok:
      docker build -f infra/docker/nginx.Dockerfile -t kubedok-nginx:dev .
    or point KUBEDOK_TEST_NGINX_IMAGE at a released image."
info "nginx image ${NGINX_IMAGE}"

cleanup
INSTALL_ROOT="${WORK}/opt-kubedok"
mkdir -p "${INSTALL_ROOT}/config" "${INSTALL_ROOT}/tls/letsencrypt" "${INSTALL_ROOT}/tls/webroot" \
         "${WORK}/scripts" "${WORK}/bin"
chmod 755 "${INSTALL_ROOT}/tls" "${INSTALL_ROOT}/tls/webroot"
cp "${DEPLOY_DIR}"/scripts/cert-renew.sh "${DEPLOY_DIR}"/scripts/common.sh "${WORK}/scripts/"
chmod +x "${WORK}"/scripts/*.sh

# Stands in for the docker CLI inside the runner: satisfies require_cmd and
# records the certbot invocation instead of running it.
cat > "${WORK}/bin/docker" <<'SH'
#!/bin/sh
echo "stub-docker: $*"
exit 0
SH
chmod +x "${WORK}/bin/docker"

# ── nginx in its pre-issuance state, plus a runner beside it ─────────────────
step 'Starting nginx (TLS requested, no certificate yet) and the runner'

docker network create "${NET}" >/dev/null
docker run -d --name "${NGINX}" --network "${NET}" --network-alias "${HOST}" \
  -e KUBEDOK_TLS_ENABLED=true \
  -e "KUBEDOK_SERVER_NAME=${HOST}" \
  -e KUBEDOK_SERVER_HOST=127.0.0.1 \
  -v "${INSTALL_ROOT}/tls/letsencrypt:/etc/letsencrypt:ro" \
  -v "${INSTALL_ROOT}/tls/webroot:/var/www/certbot" \
  "${NGINX_IMAGE}" >/dev/null

# The install root is mounted at the SAME absolute path inside the runner, so
# the paths cert-renew.sh prints are the ones on disk.
docker run -d --name "${RUNNER}" --network "${NET}" \
  -e "KUBEDOK_ROOT=${INSTALL_ROOT}" -e NO_COLOR=1 \
  -v "${INSTALL_ROOT}:${INSTALL_ROOT}" \
  -v "${WORK}/scripts:/deploy/scripts:ro" \
  -v "${WORK}/bin:/stub:ro" \
  alpine:3.20 sleep infinity >/dev/null
docker exec "${RUNNER}" sh -c 'apk add --no-cache bash curl >/dev/null 2>&1 && cp /stub/docker /usr/local/bin/docker' \
  || abort 'could not prepare the runner'

for _ in $(seq 1 30); do
  docker exec "${RUNNER}" curl -fsS -o /dev/null "http://${HOST}/" 2>/dev/null && break
  sleep 1
done
docker exec "${RUNNER}" curl -fsS -o /dev/null "http://${HOST}/" 2>/dev/null || abort 'nginx did not come up'
info "nginx: $(docker logs "${NGINX}" 2>&1 | grep -o 'TLS requested.*complete' || echo 'up')"

# ── Helpers ──────────────────────────────────────────────────────────────────
# Loopback inside the runner is not nginx, hence KUBEDOK_LOCAL_BASE_URL.
write_config() {
  printf 'KUBEDOK_HOST=%s\nKUBEDOK_LETSENCRYPT_EMAIL=test@example.com\nKUBEDOK_LOCAL_BASE_URL=%s\n' \
    "$1" "$2" > "${INSTALL_ROOT}/config/kubedok.env"
}

OUT=""
RC=0
run_issue() {
  RC=0
  OUT="$(docker exec "${RUNNER}" /deploy/scripts/cert-renew.sh --issue --dry-run 2>&1)" || RC=$?
}

expect_line() {
  local what="$1" needle="$2"
  if grep -qF -- "${needle}" <<<"${OUT}"; then pass "${what}"; else fails "${what} — missing '${needle}'"; fi
}

reject_line() {
  local what="$1" needle="$2"
  if grep -qF -- "${needle}" <<<"${OUT}"; then fails "${what} — found '${needle}'"; else pass "${what}"; fi
}

probe_files() { find "${INSTALL_ROOT}/tls/webroot" -type f | wc -l | tr -d ' '; }

dump() { printf '%s\n' "${OUT}" | sed 's/^/      /'; }

# ═══════════════════════════════════════════════════════════════════════════
step 'TEST 1 — a correctly wired install passes the probe and reaches certbot'

write_config "${HOST}" "http://${HOST}"
run_issue
if [ "${RC}" -eq 0 ]; then pass 'cert-renew.sh --issue --dry-run exits 0'; else fails "exit ${RC}"; dump; fi
expect_line 'nginx serves the webroot locally'     'nginx serves the challenge webroot'
expect_line 'the public probe succeeds'            'Challenge path reachable from the internet'
expect_line 'certbot is invoked with the webroot'  "certonly --webroot -w /var/www/certbot -d ${HOST}"
expect_line 'the dry run is passed through'        '--dry-run'
if [ "$(probe_files)" = "0" ]; then pass 'the probe file is cleaned up'; else fails "$(probe_files) probe file(s) left in the webroot"; fi

# ═══════════════════════════════════════════════════════════════════════════
step 'TEST 2 — nginx fine, public route broken: the message blames the route'

write_config 'blackhole.invalid' "http://${HOST}"
run_issue
if [ "${RC}" -ne 0 ]; then pass 'issuance is refused'; else fails 'issuance went ahead'; dump; fi
expect_line 'the local probe still passes'         'nginx serves the challenge webroot'
expect_line 'the failure names the internet route' 'not reachable from the internet'
expect_line 'the real curl error is shown'         'Could not resolve host'
reject_line 'certbot is not called'                'stub-docker: run'

# ═══════════════════════════════════════════════════════════════════════════
step 'TEST 3 — nginx not serving the webroot: the message blames this host'

write_config "${HOST}" "http://${HOST}:81"
run_issue
if [ "${RC}" -ne 0 ]; then pass 'issuance is refused'; else fails 'issuance went ahead'; dump; fi
expect_line 'the failure names nginx on this host' 'nginx on this host is not serving the ACME challenge webroot'
reject_line 'the internet is not blamed'           'not reachable from the internet'
reject_line 'certbot is not called'                'stub-docker: run'
if [ "$(probe_files)" = "0" ]; then pass 'the probe file is cleaned up on failure'; else fails "$(probe_files) probe file(s) left in the webroot"; fi

# ═══════════════════════════════════════════════════════════════════════════
printf '\n%s────────────────────────────────────────%s\n' "${c_blue}" "${c_off}"
printf '  %s%d passed%s' "${c_green}" "${PASS}" "${c_off}"
[ "${FAIL}" -gt 0 ] && printf ', %s%d failed%s' "${c_red}" "${FAIL}" "${c_off}"
printf '\n%s────────────────────────────────────────%s\n\n' "${c_blue}" "${c_off}"

[ "${FAIL}" -eq 0 ]
