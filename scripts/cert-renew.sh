#!/usr/bin/env bash
#
# Obtain and renew the TLS certificate, then reload nginx.
#
#   cert-renew.sh --issue          # first issuance
#   cert-renew.sh                  # renew if due (safe to run daily)
#   cert-renew.sh --force          # renew even if not due
#   cert-renew.sh --dry-run        # exercise the flow against the ACME staging path
#   cert-renew.sh --install-timer  # install the systemd renewal timer
#
# nginx serves TLS but never issues anything. Certbot runs as a one-shot
# container against the webroot nginx already exposes at
# /.well-known/acme-challenge/, so there is no host-level certbot install and
# no need to stop nginx to renew.
#
# HTTP-01 validation requires port 80 to be reachable from the public
# internet: https://letsencrypt.org/docs/allow-port-80/
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

CERTBOT_IMAGE="${KUBEDOK_CERTBOT_IMAGE:-certbot/certbot:latest}"

MODE="renew"
FORCE=false
DRY_RUN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --issue) MODE="issue"; shift ;;
    --force) FORCE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --install-timer) MODE="install-timer"; shift ;;
    -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

require_root
require_installed
require_cmd docker
load_config

LE_DIR="${KUBEDOK_TLS_DIR}/letsencrypt"
WEBROOT="${KUBEDOK_TLS_DIR}/webroot"

install_timer() {
  command -v systemctl >/dev/null 2>&1 \
    || die "systemd is not available. Schedule ${SCRIPT_DIR}/cert-renew.sh twice daily by another means."

  cat > /etc/systemd/system/kubedok-cert-renew.service <<UNIT
[Unit]
Description=Renew the Kubedok TLS certificate
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=${KUBEDOK_ROOT}/current/scripts/cert-renew.sh
UNIT

  # Twice daily is the Let's Encrypt recommendation; the random delay keeps
  # every Kubedok install in the world from hitting the ACME API at once.
  cat > /etc/systemd/system/kubedok-cert-renew.timer <<UNIT
[Unit]
Description=Renew the Kubedok TLS certificate twice daily

[Timer]
OnCalendar=*-*-* 03,15:00:00
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
UNIT

  systemctl daemon-reload
  systemctl enable --now kubedok-cert-renew.timer >/dev/null
  ok "Renewal timer installed (next: $(systemctl show kubedok-cert-renew.timer -p NextElapseUSecRealtime --value 2>/dev/null || echo 'see systemctl list-timers'))"
}

if [ "${MODE}" = "install-timer" ]; then
  install_timer
  exit 0
fi

[ -n "${KUBEDOK_HOST:-}" ] \
  || die "KUBEDOK_HOST is not set in ${KUBEDOK_CONFIG_FILE}. TLS needs a DNS name."
[ -n "${KUBEDOK_LETSENCRYPT_EMAIL:-}" ] \
  || die "KUBEDOK_LETSENCRYPT_EMAIL is not set in ${KUBEDOK_CONFIG_FILE}."

mkdir -p "${LE_DIR}" "${WEBROOT}"
chmod 755 "${WEBROOT}"

certbot_run() {
  docker run --rm \
    -v "${LE_DIR}:/etc/letsencrypt" \
    -v "${WEBROOT}:/var/www/certbot" \
    "${CERTBOT_IMAGE}" "$@"
}

reload_nginx() {
  if docker inspect kubedok-nginx >/dev/null 2>&1 \
    && [ "$(docker inspect -f '{{.State.Running}}' kubedok-nginx)" = "true" ]; then
    # A reload picks up the renewed files without dropping connections.
    if docker exec kubedok-nginx nginx -s reload >/dev/null 2>&1; then
      ok "nginx reloaded"
    else
      warn "Could not reload nginx. Restart it: ${SCRIPT_DIR}/restart.sh nginx"
    fi
  fi
}

case "${MODE}" in
  issue)
    log "Requesting a certificate for ${KUBEDOK_HOST}"

    if [ -f "${LE_DIR}/live/${KUBEDOK_HOST}/fullchain.pem" ] && [ "${FORCE}" != "true" ]; then
      ok "A certificate for ${KUBEDOK_HOST} already exists. Use --force to replace it."
      exit 0
    fi

    # The challenge path has to work before certbot is asked to use it,
    # otherwise the failure surfaces as an opaque ACME error.
    probe="kubedok-acme-probe-$$"
    printf 'ok' > "${WEBROOT}/${probe}"
    probe_url="http://${KUBEDOK_HOST}/.well-known/acme-challenge/${probe}"
    if ! curl -fsS --max-time 15 "${probe_url}" >/dev/null 2>&1; then
      rm -f "${WEBROOT:?}/${probe}"
      die "The ACME challenge path is not reachable from the internet.
    Tried: ${probe_url}
    Check that port 80 is open in the firewall and any cloud security group,
    that ${KUBEDOK_HOST} resolves to this server, and that nginx is running.
    Let's Encrypt requires port 80: https://letsencrypt.org/docs/allow-port-80/"
    fi
    rm -f "${WEBROOT:?}/${probe}"
    ok "Challenge path reachable"

    args=(certonly --webroot -w /var/www/certbot
          -d "${KUBEDOK_HOST}"
          --email "${KUBEDOK_LETSENCRYPT_EMAIL}"
          --agree-tos --no-eff-email --non-interactive
          --keep-until-expiring)
    [ "${DRY_RUN}" = "true" ] && args+=(--dry-run)
    [ "${FORCE}" = "true" ] && args+=(--force-renewal)

    certbot_run "${args[@]}" || die "Certificate issuance failed. See the certbot output above."

    if [ "${DRY_RUN}" = "true" ]; then
      ok "Dry run succeeded — the real issuance should work."
      exit 0
    fi

    ok "Certificate issued for ${KUBEDOK_HOST}"
    install_timer
    ;;

  renew)
    log "Renewing certificates if due"
    args=(renew --webroot -w /var/www/certbot --non-interactive)
    [ "${DRY_RUN}" = "true" ] && args+=(--dry-run)
    [ "${FORCE}" = "true" ] && args+=(--force-renewal)

    if certbot_run "${args[@]}"; then
      [ "${DRY_RUN}" = "true" ] && { ok "Dry-run renewal succeeded."; exit 0; }
      ok "Renewal check complete"
      reload_nginx
    else
      die "Renewal failed. Certificates already on disk are untouched; investigate before they expire."
    fi
    ;;
esac
