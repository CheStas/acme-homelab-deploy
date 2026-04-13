# acme-homelab-deploy

Deploys wildcard TLS certificates from [acme.sh](https://github.com/acmesh-official/acme.sh) to homelab services. Used as `--reloadcmd` during certificate install/renew.

## Services

| Deploy | Target | Method |
|--------|--------|--------|
| `ha` | Home Assistant | SSH/SCP + `ha core restart` |
| `truenas` | TrueNAS | REST API (certificate import + UI binding) |
| `npm` | Nginx Proxy Manager | REST API (upload, update proxies, cleanup old certs) |
| `wikihome` | Wikihome / Node-RED | SSH/SCP + `systemctl restart nodered` |

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
| `TRUENAS_URL` | TrueNAS API base URL |
| `TRUENAS_CERT_PREFIX` | Prefix for imported certificate names |
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

## Testing

```bash
# Run all tests
./tests/bats/bin/bats tests/

# Run specific test file
./tests/bats/bin/bats tests/test_common.bats
```

## Project Structure

```
.env                  # Non-secret config
.env.secret           # Secrets (gitignored)
.env.secret.example   # Secrets template
deploy-all.sh         # Orchestrator
lib/
  common.sh           # Shared: logging, env, error handling
  http.sh             # Shared: curl/scp/ssh wrappers
deploys/
  ha.sh               # Home Assistant
  truenas.sh          # TrueNAS
  npm.sh              # Nginx Proxy Manager
  wikihome.sh         # Wikihome / Node-RED
tests/                # bats-core tests
```
