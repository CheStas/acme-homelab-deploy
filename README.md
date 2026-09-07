# acme-homelab-deploy

Deploys wildcard TLS certificates from [acme.sh](https://github.com/acmesh-official/acme.sh) to homelab services. Used as `--reloadcmd` during certificate install/renew.

## Services

| Deploy | Target | Method |
|--------|--------|--------|
| `ha` | Home Assistant | SSH/SCP + `ha core restart` |
| `truenas` | TrueNAS | JSON-RPC over WebSocket (certificate import + UI binding) |
| `npm` | Nginx Proxy Manager | REST API (upload, update proxies, cleanup old certs) |
| `wikihome` | Wikihome / Node-RED | SSH/SCP + `systemctl restart nodered` |

## TrueNAS deploy: JSON-RPC over WebSocket

The `truenas` deploy previously used the REST API (`/api/v2.0`), which TrueNAS
deprecated and **removes in 26.04** (it logs *"The deprecated REST API was used
to authenticate"*). It now uses the supported **JSON-RPC 2.0 over WebSocket** API
at `wss://<host>/api/current`, authenticating with `auth.login_with_api_key`
using your existing API key (only the HTTP transport changed — the key still
works). Plain API-key auth is still accepted by TrueNAS 26.x.

The WebSocket is driven by [`websocat`](https://github.com/vi/websocat) from a
bash coproc in `lib/jsonrpc.sh`. **No binary is committed to the repo.** On the
Pi, the script downloads the static musl `websocat` binary from GitHub on first
run and caches it at `~/.cache/acme-deploy/websocat` (reused afterward).

```bash
# Update to the latest websocat release:
WEBSOCAT_FORCE_DOWNLOAD=1 ./deploy-all.sh truenas

# Pin a specific release:
WEBSOCAT_VERSION=v1.14.1 ./deploy-all.sh truenas

# Or supply your own websocat (e.g. installed system-wide):
WEBSOCAT=/usr/local/bin/websocat ./deploy-all.sh truenas
```

Supported architectures: `aarch64` and `x86_64` (static musl builds with TLS).
The 32-bit `armv7l` musl build has no TLS and cannot do `wss://`.

For development, use the nix dev shell (provides bash 5, websocat, jq, bats,
shellcheck, GNU coreutils — the Pi itself has no nix):

```bash
nix develop          # then: bats tests/   |   shellcheck -x lib/jsonrpc.sh
```

## Setup

1. Clone this repo
2. Copy secrets template and fill in values:
   ```bash
   cp .env.secret.example .env.secret
   vim .env.secret
   ```
3. Review `.env` and adjust hosts/paths if needed
4. Test a single deploy:
   ```bash
   ./deploys/ha.sh
   ```

## Usage

```bash
# Run all deploys
./deploy-all.sh

# Run specific deploys only
./deploy-all.sh ha truenas

# Skip a deploy
./deploy-all.sh --skip npm

# List available deploys
./deploy-all.sh --list

# Preview what would run
./deploy-all.sh --dry-run
```

### Running as acme.sh reloadcmd
same command is used as the most reliable option to update the reloadcmd script path
```bash
acme.sh --install-cert -d "*.internal.domain.net" \
  --cert-file      "$HOME/certs/internal.domain.net/cert.pem" \
  --key-file       "$HOME/certs/internal.domain.net/privkey.pem" \
  --fullchain-file "$HOME/certs/internal.domain.net/fullchain.pem" \
  --reloadcmd      "/home/admin/projects/acme-homelab-deploy/deploy-all.sh"
```

## Logs

All output is logged to `deploy.log` in the project root.

```bash
# Follow logs in real time
tail -f deploy.log

# View last deployment run
grep -A 1000 "DEPLOYMENT RUN STARTED" deploy.log | tail -100
```

Log format:
```
[2026-04-13T14:30:00+00:00] [truenas] [INFO] Importing certificate: wildcard_internal_2026-04-13_14:30
```

Each field: `[timestamp] [script] [level] message`

Each `deploy-all.sh` run is separated by `====` lines with STARTED/FINISHED markers.

## Environment Variables

### Non-secret (.env)

| Variable | Description |
|----------|-------------|
| `CERT_DIR` | Local directory containing certificates |
| `CERT_FILE` | Certificate filename (default: `fullchain.pem`) |
| `KEY_FILE` | Private key filename (default: `privkey.pem`) |
| `SSH_KEY` | SSH private key for SCP/SSH deploys |
| `HA_HOST` | Home Assistant hostname |
| `HA_USER` | Home Assistant SSH user |
| `HA_CERT_DIR` | Remote cert directory on HA |
| `TRUENAS_URL` | TrueNAS base URL (`https://host` or `https://host:port`; converted to `wss://` for the WebSocket API) |
| `TRUENAS_CERT_PREFIX` | Prefix for imported certificate names |
| `WEBSOCAT` | Optional explicit path to a `websocat` binary (skips cache/download) |
| `WEBSOCAT_VERSION` | websocat release to download/cache: `latest` (default) or a pinned tag like `v1.14.1` |
| `WEBSOCAT_FORCE_DOWNLOAD` | Set to `1` to re-download websocat even if a cached copy exists |
| `JSONRPC_READ_TIMEOUT` | Per JSON-RPC reply read timeout in seconds (default `30`) |
| `NPM_URL` | Nginx Proxy Manager API URL |
| `NPM_EMAIL` | NPM admin email |
| `NPM_DOMAINS` | Space-separated list of domains to update |
| `WIKIHOME_HOST` | Wikihome/Node-RED host IP |
| `WIKIHOME_USER` | SSH user for Wikihome |
| `WIKIHOME_CERT_DIR` | Remote cert directory on Wikihome |
| `WIKIHOME_RESTART_CMD` | Command to restart Node-RED |
| `CURL_TIMEOUT` | Connection timeout in seconds |
| `CURL_MAX_TIME` | Maximum request time in seconds |

### Secrets (.env.secret) -- gitignored

| Variable | Description |
|----------|-------------|
| `TRUENAS_API_KEY` | TrueNAS API key (generate in UI > API Keys) |
| `NPM_PASSWORD` | Nginx Proxy Manager admin password |

## Adding a New Deploy Target

1. Create `deploys/myservice.sh`:
   ```bash
   #!/bin/bash
   SCRIPT_NAME="myservice"
   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
   PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

   source "$PROJECT_ROOT/lib/common.sh"
   source "$PROJECT_ROOT/lib/http.sh"
   load_env
   setup_error_handling
   require_vars CERT KEY  # add your required vars

   # Your deploy logic here
   log INFO "Deploying to myservice"
   ```
2. Make it executable: `chmod +x deploys/myservice.sh`
3. Add any new env variables to `.env` or `.env.secret`
4. It will be automatically discovered by `deploy-all.sh`

## acme.sh Reference

```bash
# View certificate status
acme.sh --list

# Force renew certificate
acme.sh --renew -d "*.internal.domain.net" --force

# View acme.sh logs
acme.sh --log  # or check ~/.acme.sh/acme.sh.log

# View scheduled cron job
crontab -l | grep acme

# Moving to a new domain
# 1. Issue new cert:
acme.sh --issue -d "*.newdomain.net" --dns dns_provider
# 2. Update CERT_DIR in .env to point to new cert directory
# 3. Update service-specific configs (domain names, hostnames)
# 4. Install cert with reloadcmd (see Usage above)
```

## Deploy to Remote

Copy project files to a remote machine (excludes `.git`, `tests`, `.claude`):

```bash
scp -r $(find . -maxdepth 1 ! -name '.git' ! -name 'tests' ! -name '.claude' ! -name '.' -printf '%p ') \
  user@remote-host:/home/admin/projects/acme-homelab-deploy/
```

## Testing

Tests use [bats-core](https://github.com/bats-core/bats-core) (vendored as a
submodule) and need bash 4+ with GNU coreutils. On the dev machine use the nix
shell; on Linux (e.g. the Pi) the system tools suffice.

```bash
git submodule update --init   # first checkout only

# Dev machine (macOS) — provides bash 5, bats, jq, shellcheck, GNU coreutils:
nix develop --command bash -c 'bats tests/'
nix develop --command bash -c 'shellcheck -x deploys/*.sh lib/*.sh'

# Linux:
./tests/bats/bin/bats tests/
```

## Project Structure

```
.env                  # Non-secret config
.env.secret           # Secrets (gitignored)
.env.secret.example   # Secrets template
deploy-all.sh         # Orchestrator
flake.nix             # Dev shell (dev machine only; the Pi has no nix)
lib/
  common.sh           # Shared: logging, env, error handling
  http.sh             # Shared: curl/scp/ssh wrappers
  jsonrpc.sh          # Shared: JSON-RPC 2.0 over WebSocket client (websocat)
deploys/
  ha.sh               # Home Assistant
  truenas.sh          # TrueNAS
  npm.sh              # Nginx Proxy Manager
  wikihome.sh         # Wikihome / Node-RED
tests/                # bats-core tests
```
