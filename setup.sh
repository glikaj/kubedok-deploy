#!/usr/bin/env bash
#
# Kubedok installer.
#
# Idempotent and executable — run it, do not source it. Re-running against an
# existing install is safe: it never regenerates secrets, never touches the
# database volume, and never overwrites configuration you have edited.
#
#   git clone https://github.com/glikaj/kubedok-deploy.git kubedok
#   cd kubedok
#   sudo KUBEDOK_HOST=kubedok.example.com KUBEDOK_TLS=auto ./setup.sh
#
# Clone rather than download: this script sources scripts/common.sh and
# installs the compose/ files, so it cannot run as a standalone file.
#
# Configuration (environment variables):
#   KUBEDOK_HOST                 DNS name this install is served on. Required for TLS.
#   KUBEDOK_TLS                  off | on | auto          (default: auto)
#   KUBEDOK_LETSENCRYPT_EMAIL    Contact address for the ACME account.
#   KUBEDOK_ENABLE_AGENT         Install the agent on this host too. (default: false)
#   KUBEDOK_RELEASE              Channel name or exact version. (default: stable)
#   KUBEDOK_PUBLIC_POSTGRES      Publish 5432 for debugging. (default: false)
#   KUBEDOK_ROOT                 Install directory. (default: /opt/kubedok)
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Bootstrap: common.sh ships beside this script in the repo, and under
# scripts/ once installed.
if [ -f "${SCRIPT_DIR}/scripts/common.sh" ]; then
  # shellcheck source=scripts/common.sh
  . "${SCRIPT_DIR}/scripts/common.sh"
elif [ -f "${SCRIPT_DIR}/common.sh" ]; then
  # shellcheck source=scripts/common.sh
  . "${SCRIPT_DIR}/common.sh"
else
  # setup.sh cannot bootstrap itself: it needs scripts/ and compose/ from this
  # repository. Downloading this one file is the most likely way to get here,
  # so say exactly what to do instead of naming a missing path.
  cat >&2 <<'HINT'
setup.sh cannot run on its own — it needs the scripts/ and compose/
directories that live beside it in the repository.

Clone the repository and run it from there:

  git clone https://github.com/glikaj/kubedok-deploy.git kubedok
  cd kubedok
  sudo ./setup.sh

HINT
  exit 1
fi

KUBEDOK_TLS="${KUBEDOK_TLS:-auto}"
KUBEDOK_RELEASE="${KUBEDOK_RELEASE:-stable}"
KUBEDOK_ENABLE_AGENT="${KUBEDOK_ENABLE_AGENT:-false}"
KUBEDOK_PUBLIC_POSTGRES="${KUBEDOK_PUBLIC_POSTGRES:-false}"
KUBEDOK_SKIP_DEPS="${KUBEDOK_SKIP_DEPS:-false}"

# ── 1. Root ──────────────────────────────────────────────────────────────────
require_root "$@"

# ── 2. Supported platform ────────────────────────────────────────────────────
check_platform() {
  log "Checking platform"

  [ -r /etc/os-release ] || die "Cannot read /etc/os-release. Only Debian and Ubuntu are supported today."
  # shellcheck disable=SC1091
  . /etc/os-release

  case "${ID:-}:${ID_LIKE:-}" in
    debian:*|ubuntu:*|*:*debian*)
      ok "Detected ${PRETTY_NAME:-${ID}}"
      ;;
    *)
      die "Unsupported distribution: ${PRETTY_NAME:-${ID:-unknown}}. Only Debian and Ubuntu are supported today. Install Docker yourself and re-run with KUBEDOK_SKIP_DEPS=true to continue anyway."
      ;;
  esac
}

# ── 3. Dependencies ──────────────────────────────────────────────────────────
install_dependencies() {
  if [ "${KUBEDOK_SKIP_DEPS}" = "true" ]; then
    warn "KUBEDOK_SKIP_DEPS=true — not installing packages"
    require_cmd curl openssl jq flock docker
    return 0
  fi

  log "Installing dependencies"

  local wanted=(ca-certificates curl openssl jq util-linux)
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends "${wanted[@]}" >/dev/null
  ok "Base packages present"

  if docker version >/dev/null 2>&1; then
    ok "Docker Engine already installed ($(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 'version unknown'))"
  else
    log "Installing Docker Engine from the official repository"
    install -m 0755 -d /etc/apt/keyrings
    local codename
    codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
    local distro_id
    distro_id="$(. /etc/os-release && echo "${ID}")"

    curl -fsSL "https://download.docker.com/linux/${distro_id}/gpg" \
      -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
      "$(dpkg --print-architecture)" "${distro_id}" "${codename}" \
      > /etc/apt/sources.list.d/docker.list

    apt-get update -qq
    apt-get install -y -qq --no-install-recommends \
      docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
    systemctl enable --now docker >/dev/null 2>&1 || true
    ok "Docker Engine installed"
  fi

  if ! docker compose version >/dev/null 2>&1; then
    log "Installing the Docker Compose plugin"
    apt-get install -y -qq --no-install-recommends docker-compose-plugin >/dev/null \
      || die "Could not install the Docker Compose plugin. Install it manually and re-run."
  fi
  ok "Docker Compose available ($(docker compose version --short 2>/dev/null || echo 'version unknown'))"

  require_cmd curl openssl jq flock docker
}

# ── 4. Architecture and Docker capability ────────────────────────────────────
check_capabilities() {
  log "Checking architecture and Docker"

  local arch
  arch="$(uname -m)"
  case "${arch}" in
    x86_64|amd64|aarch64|arm64) ok "Architecture ${arch} is supported" ;;
    *) die "Unsupported CPU architecture: ${arch}. Kubedok images are published for amd64 and arm64." ;;
  esac

  docker info >/dev/null 2>&1 \
    || die "Cannot talk to the Docker daemon. Is it running? Try: systemctl status docker"

  # A control plane that cannot pull images is not going to get far.
  docker run --rm hello-world >/dev/null 2>&1 \
    || warn "Could not run a test container. Image pulls may fail — check outbound network and registry access."

  ok "Docker is usable"
}

# ── TLS decision ─────────────────────────────────────────────────────────────
# Resolved before anything is started, because it changes how nginx is
# configured and whether the ACME client runs at all.
resolve_tls() {
  log "Resolving TLS mode (KUBEDOK_TLS=${KUBEDOK_TLS})"

  case "${KUBEDOK_TLS}" in
    off)
      KUBEDOK_TLS_ENABLED=false
      warn "TLS is disabled. Kubedok will be served over plain HTTP."
      ;;
    on)
      [ -n "${KUBEDOK_HOST:-}" ] \
        || die "KUBEDOK_TLS=on requires KUBEDOK_HOST to be a DNS name you control."
      [ -n "${KUBEDOK_LETSENCRYPT_EMAIL:-}" ] \
        || die "KUBEDOK_TLS=on requires KUBEDOK_LETSENCRYPT_EMAIL for the ACME account."
      dns_points_here "${KUBEDOK_HOST}" \
        || die "KUBEDOK_HOST=${KUBEDOK_HOST} does not resolve to this server. Point the DNS A/AAAA record here and re-run. Set KUBEDOK_TLS=off to continue without HTTPS."
      KUBEDOK_TLS_ENABLED=true
      ok "TLS enabled for ${KUBEDOK_HOST}"
      ;;
    auto)
      if [ -z "${KUBEDOK_HOST:-}" ]; then
        KUBEDOK_TLS_ENABLED=false
        warn "No KUBEDOK_HOST set — serving HTTP only. No self-signed certificate is created."
      elif ! dns_points_here "${KUBEDOK_HOST}"; then
        # A hostname was supplied, so silently downgrading would hide a DNS
        # mistake behind an insecure install.
        die "KUBEDOK_HOST=${KUBEDOK_HOST} does not resolve to this server.
    Point its DNS A/AAAA record at this host and re-run, or
    set KUBEDOK_TLS=off to install without HTTPS on purpose."
      elif [ -z "${KUBEDOK_LETSENCRYPT_EMAIL:-}" ]; then
        die "KUBEDOK_HOST resolves here but KUBEDOK_LETSENCRYPT_EMAIL is not set. Set it, or use KUBEDOK_TLS=off."
      else
        KUBEDOK_TLS_ENABLED=true
        ok "TLS enabled for ${KUBEDOK_HOST}"
      fi
      ;;
    *)
      die "KUBEDOK_TLS must be one of: off, on, auto (got: ${KUBEDOK_TLS})"
      ;;
  esac

  export KUBEDOK_TLS_ENABLED
}

# True when the hostname resolves to an address this machine holds.
dns_points_here() {
  local host="$1"
  local resolved local_addrs addr

  resolved="$(getent ahosts "${host}" 2>/dev/null | awk '{print $1}' | sort -u || true)"
  [ -n "${resolved}" ] || { debug "${host} does not resolve at all"; return 1; }

  local_addrs="$(ip -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | sort -u || true)"
  # Behind NAT the public address is not on any local interface, so fall back
  # to whatever the host believes its public address is.
  local public_addr
  public_addr="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [ -n "${public_addr}" ] && local_addrs="${local_addrs}"$'\n'"${public_addr}"

  for addr in ${resolved}; do
    if printf '%s\n' "${local_addrs}" | grep -qx "${addr}"; then
      debug "${host} resolves to ${addr}, which is local"
      return 0
    fi
  done

  debug "${host} resolves to [${resolved//$'\n'/ }] but none are local [${local_addrs//$'\n'/ }]"
  return 1
}

# ── 5. Install directory ─────────────────────────────────────────────────────
create_layout() {
  log "Creating ${KUBEDOK_ROOT}"

  mkdir -p \
    "${KUBEDOK_RELEASES_DIR}" \
    "${KUBEDOK_CONFIG_DIR}" \
    "${KUBEDOK_SECRETS_DIR}" \
    "${KUBEDOK_BACKUPS_DIR}" \
    "${KUBEDOK_TLS_DIR}/letsencrypt" \
    "${KUBEDOK_TLS_DIR}/webroot"

  chmod 755 "${KUBEDOK_ROOT}"
  chmod 700 "${KUBEDOK_SECRETS_DIR}" "${KUBEDOK_BACKUPS_DIR}"
  chmod 755 "${KUBEDOK_TLS_DIR}" "${KUBEDOK_TLS_DIR}/webroot"
  ok "Install layout ready"
}

# ── 6. Release manifest ──────────────────────────────────────────────────────
install_release() {
  log "Resolving release '${KUBEDOK_RELEASE}'"

  local tmp_manifest
  tmp_manifest="$(mktemp)"
  resolve_manifest "${KUBEDOK_RELEASE}" "${tmp_manifest}" >/dev/null

  RELEASE_VERSION="$(manifest_field release "${tmp_manifest}")"
  ok "Release ${RELEASE_VERSION}"

  RELEASE_DIR="${KUBEDOK_RELEASES_DIR}/${RELEASE_VERSION}"
  mkdir -p "${RELEASE_DIR}/compose" "${RELEASE_DIR}/scripts"
  mv "${tmp_manifest}" "${RELEASE_DIR}/release.json"
  chmod 644 "${RELEASE_DIR}/release.json"

  # Ship the compose files and scripts that belong to this release, so a
  # rollback restores the tooling as well as the images.
  local file
  for file in postgres.yml postgres.public.yml server.yml nginx.yml agent.yml; do
    if [ -f "${SCRIPT_DIR}/compose/${file}" ]; then
      install -m 644 "${SCRIPT_DIR}/compose/${file}" "${RELEASE_DIR}/compose/${file}"
    else
      fetch_url "${KUBEDOK_RELEASE_BASE_URL}/compose/${file}" "${RELEASE_DIR}/compose/${file}"
    fi
  done

  for file in common.sh doctor.sh backup.sh restore.sh status.sh logs.sh \
              restart.sh rollback.sh agent-install.sh agent-update.sh \
              cert-renew.sh uninstall.sh migrate-from-monolith.sh; do
    if [ -f "${SCRIPT_DIR}/scripts/${file}" ]; then
      install -m 755 "${SCRIPT_DIR}/scripts/${file}" "${RELEASE_DIR}/scripts/${file}"
    else
      fetch_url "${KUBEDOK_RELEASE_BASE_URL}/scripts/${file}" "${RELEASE_DIR}/scripts/${file}" || true
      [ -f "${RELEASE_DIR}/scripts/${file}" ] && chmod 755 "${RELEASE_DIR}/scripts/${file}"
    fi
  done

  set_current_release "${RELEASE_VERSION}"
  ok "Installed release tree at ${RELEASE_DIR}"
}

# ── 7. Secrets ───────────────────────────────────────────────────────────────
# Never regenerated: a new registry-encryption-key would make every stored
# registry credential and certificate in the database undecryptable.
generate_secrets() {
  log "Ensuring secrets"
  ensure_all_secrets
}

write_configuration() {
  log "Writing configuration"

  # Only seed values that are not already present, so re-running setup.sh
  # never clobbers hand-edited settings.
  local key
  for key in KUBEDOK_HOST KUBEDOK_TLS KUBEDOK_TLS_ENABLED KUBEDOK_LETSENCRYPT_EMAIL \
             KUBEDOK_RELEASE KUBEDOK_PUBLIC_POSTGRES KUBEDOK_HTTP_PORT KUBEDOK_HTTPS_PORT; do
    if ! grep -q "^${key}=" "${KUBEDOK_CONFIG_FILE}" 2>/dev/null; then
      set_config "${key}" "${!key:-}"
    fi
  done

  # These two always follow the current run: they are decisions, not defaults.
  set_config KUBEDOK_TLS "${KUBEDOK_TLS}"
  set_config KUBEDOK_TLS_ENABLED "${KUBEDOK_TLS_ENABLED}"
  [ -n "${KUBEDOK_HOST:-}" ] && set_config KUBEDOK_HOST "${KUBEDOK_HOST}"

  chmod 600 "${KUBEDOK_CONFIG_FILE}"
  ok "Configuration at ${KUBEDOK_CONFIG_FILE}"
}

# ── 8. Networks ──────────────────────────────────────────────────────────────
create_networks() {
  log "Creating private networks"
  ensure_networks
}

pull_images() {
  log "Pulling release images"
  local manifest="${KUBEDOK_CURRENT_LINK}/release.json"
  local component ref
  for component in postgres server nginx; do
    ref="$(manifest_image "${component}" "${manifest}")"
    docker pull -q "${ref}" >/dev/null || die "Could not pull ${component} image: ${ref}"
    ok "Pulled ${component}"
  done
  if [ "${KUBEDOK_ENABLE_AGENT}" = "true" ]; then
    ref="$(manifest_image agent "${manifest}")"
    docker pull -q "${ref}" >/dev/null || die "Could not pull agent image: ${ref}"
    ok "Pulled agent"
  fi
}

# ── 9 + 10. PostgreSQL ───────────────────────────────────────────────────────
start_postgres() {
  log "Starting PostgreSQL"
  compose postgres up -d
  wait_for_container_health kubedok-postgres 180 \
    || die "PostgreSQL did not become healthy. Check: docker logs kubedok-postgres"
  ok "PostgreSQL is healthy"
}

# ── 11. Server ───────────────────────────────────────────────────────────────
start_server() {
  log "Starting the server (migrations run on startup)"
  compose server up -d
  wait_for_container_health kubedok-server 300 \
    || die "The server did not become healthy. Check: docker logs kubedok-server"
  ok "Server is healthy"
}

# ── 12. nginx ────────────────────────────────────────────────────────────────
start_nginx() {
  log "Starting nginx"
  compose nginx up -d
  wait_for_container_health kubedok-nginx 120 \
    || die "nginx did not become healthy. Check: docker logs kubedok-nginx"

  if wait_for_http "$(local_base_url)/api/health" 60; then
    ok "Serving on port ${KUBEDOK_HTTP_PORT:-80}"
  else
    die "nginx is up but $(local_base_url)/api/health is not responding."
  fi
}

# ── 14. TLS ──────────────────────────────────────────────────────────────────
issue_certificate() {
  [ "${KUBEDOK_TLS_ENABLED}" = "true" ] || return 0

  log "Obtaining a TLS certificate for ${KUBEDOK_HOST}"
  "${KUBEDOK_CURRENT_LINK}/scripts/cert-renew.sh" --issue \
    || die "Certificate issuance failed. Kubedok is still serving HTTP on port ${KUBEDOK_HTTP_PORT:-80}. Fix the cause and run: ${KUBEDOK_CURRENT_LINK}/scripts/cert-renew.sh --issue"

  log "Restarting nginx with TLS"
  compose nginx up -d --force-recreate
  wait_for_container_health kubedok-nginx 120 || die "nginx did not come back up with TLS."
  ok "HTTPS enabled"
}

# ── 13. Restart on boot ──────────────────────────────────────────────────────
# Every compose project already uses `restart: unless-stopped`, so the Docker
# daemon brings containers back. All that is needed is for Docker itself to
# start at boot.
configure_boot() {
  log "Configuring restart-on-boot"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable docker >/dev/null 2>&1 \
      && ok "Docker starts at boot; containers use restart=unless-stopped" \
      || warn "Could not enable the docker service. Enable it manually: systemctl enable docker"
  else
    warn "systemd not found — make sure Docker starts at boot on this system."
  fi
}

install_agent() {
  [ "${KUBEDOK_ENABLE_AGENT}" = "true" ] || return 0
  log "Installing the local agent"
  warn "The agent needs a registration token from the Kubedok UI."
  warn "Run: ${KUBEDOK_CURRENT_LINK}/scripts/agent-install.sh --token <token>"
}

# ── 15. Summary ──────────────────────────────────────────────────────────────
print_summary() {
  local scheme="http" port="${KUBEDOK_HTTP_PORT:-80}" hostname="${KUBEDOK_HOST:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
  local url

  if [ "${KUBEDOK_TLS_ENABLED}" = "true" ]; then
    scheme="https"; port="${KUBEDOK_HTTPS_PORT:-443}"
  fi

  if { [ "${scheme}" = "http" ] && [ "${port}" = "80" ]; } \
    || { [ "${scheme}" = "https" ] && [ "${port}" = "443" ]; }; then
    url="${scheme}://${hostname}"
  else
    url="${scheme}://${hostname}:${port}"
  fi

  local s="${KUBEDOK_CURRENT_LINK}/scripts"

  printf '\n'
  printf '%s────────────────────────────────────────────────────────%s\n' "${_c_green}" "${_c_reset}"
  printf '  Kubedok %s is running\n' "${RELEASE_VERSION}"
  printf '%s────────────────────────────────────────────────────────%s\n' "${_c_green}" "${_c_reset}"
  printf '\n'
  printf '  URL              %s\n' "${url}"
  printf '  Install          %s\n' "${KUBEDOK_ROOT}"
  printf '  Configuration    %s\n' "${KUBEDOK_CONFIG_FILE}"
  printf '  Secrets          %s\n' "${KUBEDOK_SECRETS_DIR}"
  printf '\n'
  printf '  Status           %s/status.sh\n' "${s}"
  printf '  Logs             %s/logs.sh [postgres|server|nginx|agent]\n' "${s}"
  printf '  Restart          %s/restart.sh [component|all]\n' "${s}"
  printf '  Health check     %s/doctor.sh\n' "${s}"
  printf '  Backup           %s/backup.sh\n' "${s}"
  printf '  Update           %s/update.sh\n' "${KUBEDOK_ROOT}"
  printf '\n'

  if [ "${KUBEDOK_TLS_ENABLED}" != "true" ]; then
    printf '  %s!%s HTTPS is disabled. Traffic, including the login password, is\n' "${_c_yellow}" "${_c_reset}"
    printf '    sent in the clear. Set KUBEDOK_HOST to a DNS name pointing here\n'
    printf '    and re-run with KUBEDOK_TLS=on to enable it.\n\n'
  fi

  printf '  %sBack up %s — losing registry-encryption-key\n' "${_c_yellow}" "${KUBEDOK_SECRETS_DIR}${_c_reset}"
  printf '  makes stored registry credentials permanently unrecoverable.\n\n'
}

main() {
  printf '\n%sKubedok installer%s\n\n' "${_c_blue}" "${_c_reset}"

  check_platform
  install_dependencies
  check_capabilities

  mkdir -p "${KUBEDOK_ROOT}"
  acquire_lock 300

  resolve_tls
  create_layout
  install_release
  generate_secrets
  write_configuration
  create_networks

  # Re-read config so compose.env is built from the merged result.
  load_config
  write_compose_env "${KUBEDOK_CURRENT_LINK}/release.json" >/dev/null

  pull_images
  start_postgres
  start_server
  start_nginx
  issue_certificate
  configure_boot
  install_agent

  print_summary
}

main "$@"
