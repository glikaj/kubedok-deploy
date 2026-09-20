# kubedok-deploy

Install, update, and operate [Kubedok](https://github.com/glikaj/kubedok) on
a server.

Production hosts clone or download only this repository. The application
source lives separately, so a server never needs the full source tree to run
or update Kubedok.

## Install

On a fresh Debian or Ubuntu server:

```bash
git clone https://github.com/glikaj/kubedok-deploy.git kubedok
cd kubedok
sudo KUBEDOK_HOST=kubedok.example.com \
     KUBEDOK_LETSENCRYPT_EMAIL=admin@example.com \
     ./setup.sh
```

Clone rather than download a single file: `setup.sh` sources `scripts/common.sh`
and installs the `compose/` files, so it cannot run on its own. The clone is a
one-time bootstrap — everything afterwards runs from `/opt/kubedok`, and
`update.sh` fetches new releases over HTTPS without needing git. You can delete
the clone once the install finishes.

Without a domain, omit both variables: it serves HTTP only, with a warning
rather than a self-signed certificate.

`setup.sh` installs Docker if needed, generates secrets, pulls the release
images by digest, brings up PostgreSQL, the server, and nginx on private
networks, and obtains a Let's Encrypt certificate. It is idempotent — running
it again never regenerates a secret, touches the database, or overwrites
settings you have edited.

## Operate

Everything installs under `/opt/kubedok`.

```bash
sudo /opt/kubedok/update.sh --check                  # is there an update?
sudo /opt/kubedok/update.sh                          # apply it
sudo /opt/kubedok/current/scripts/status.sh          # what is running
sudo /opt/kubedok/current/scripts/doctor.sh          # diagnose a problem
sudo /opt/kubedok/current/scripts/logs.sh server     # logs
sudo /opt/kubedok/current/scripts/backup.sh          # back up
sudo /opt/kubedok/current/scripts/rollback.sh        # undo an update
```

## Install an agent

Generate a registration token in the Kubedok UI, then on each Docker host you
want to manage:

```bash
git clone https://github.com/glikaj/kubedok-deploy.git kubedok
cd kubedok
sudo ./scripts/agent-install.sh --token <token> --api-url https://kubedok.example.com
```

On the control-plane host the agent is already installed alongside everything
else, so use `/opt/kubedok/current/scripts/agent-install.sh` there instead.

Agents update independently of the control plane, so updating Kubedok does
not restart workloads everywhere at once.

## Layout

```text
setup.sh                    Installer. Idempotent, executable, not sourced.
update.sh                   Updater. Backs up, updates, smoke-tests, commits.
compose/                    One Compose project per component.
  postgres.yml              PostgreSQL. Publishes nothing.
  postgres.public.yml       Overlay that publishes 5432 for debugging.
  server.yml                NestJS API. Publishes nothing.
  nginx.yml                 UI and reverse proxy. The only published ports.
  agent.yml                 Host agent. Host network.
scripts/
  common.sh                 Shared library. Sourced by everything else.
  status.sh                 Containers, health, release, database.
  logs.sh                   Logs, one component or all.
  restart.sh                Restart, in dependency order.
  doctor.sh                 Docker, DNS, ports, disk, memory, TLS, isolation.
  backup.sh                 Database dump plus secrets and configuration.
  restore.sh                Guarded restore. Takes a safety backup first.
  rollback.sh               Return to the previous release.
  cert-renew.sh             Issue and renew certificates; install the timer.
  agent-install.sh          Install the agent on any Docker host.
  agent-update.sh           Update one agent, independently.
  uninstall.sh              Remove containers. Keeps data unless --purge-data.
releases/
  release.schema.json       The manifest contract.
  example.json              Documented example. Not a real release.
  <version>.json            Published by CI, one per release.
channels/
  stable.json               Points at the current stable release.
tests/
  integration.sh            End-to-end test of all of the above.
```

## Architecture

```text
Internet :80/:443
        │
        ▼
   kubedok-nginx ──────┐
                       │  kubedok-proxy network
                       ▼
                 kubedok-server ──────┐
                                      │  kubedok-postgres network
                                      ▼
                               kubedok-postgres
```

Only nginx publishes ports. The server and PostgreSQL are reachable
exclusively over private Docker networks; nginx has no route to the database,
and `doctor.sh` asserts that rather than assuming it.

## Design notes

**Digests, not tags.** Every image reference in a release manifest is
`repo@sha256:…`. A tag can be repointed after publication; a digest cannot.
Two servers installing "1.2.3" a month apart get identical bytes.

**The manifest is a promise.** CI publishes it only after all four images
have been pushed and each digest has been verified pullable.

**`current` is the commit point.** `update.sh` stages the new release tree,
updates the server, waits for health, updates nginx, and smoke-tests through
the proxy. Only then does the `current` symlink move. Any failure before that
restores the previous containers.

**Secrets are generated once, on the host.** Containers never generate one.
Losing `jwt-secret` logs everyone out; losing `registry-encryption-key` makes
stored registry credentials and certificates permanently undecryptable, so
`backup.sh` includes them and `restore.sh` puts them back.

**Rollback is not a database rollback.** Rolling an image back does not revert
a migration. Migrations are expand/contract, and a destructive change never
ships in the same release as the code that needs it. If a schema is genuinely
incompatible, restore a backup instead.

**No outbound calls from a request path.** The application never asks Docker
Hub or GitHub about updates. `update.sh` owns update discovery, so an
air-gapped control plane still works.

## Releases

Releases are cut in the application repository. A `vX.Y.Z` tag there builds
all four images and commits a manifest to this repository's `releases/`,
pointing `channels/stable.json` at it. This repository is never tagged.

`KUBEDOK_RELEASE` accepts a channel name (`stable`) or an exact version
(`1.2.3`).

See [the release process](https://github.com/glikaj/kubedok/blob/main/docs/release-process.md)
for the manifest contract.

## Testing

```bash
./tests/integration.sh
```

Exercises install, backup, update, rollback, restore, and uninstall against a
real Docker daemon, including the guards that must refuse unsafe operations —
a PostgreSQL major-version change, a tag-pinned manifest, a too-large version
jump.

Two synthetic releases are pushed to a throwaway local registry so the
manifests carry genuine digests, exactly like production, and they are served
over `file://` so the test needs no network. It requires the four `:dev`
images, which are built from the application repository.

## Documentation

- [Infrastructure](https://github.com/glikaj/kubedok/blob/main/docs/infrastructure.md)
  — topology, environment variables, operations
- [Release process](https://github.com/glikaj/kubedok/blob/main/docs/release-process.md)
  — versioning and the manifest contract

## License

[MIT](LICENSE). The deployment tooling in this repository is MIT-licensed;
the Kubedok application it installs is distributed as container images under
its own terms.
