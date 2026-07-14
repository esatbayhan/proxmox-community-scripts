# Firecrawl community-scripts LXC — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a community-scripts-style Firecrawl LXC install (`ct/firecrawl.sh` + `install/firecrawl-install.sh` + `ct/headers/firecrawl`) that runs official Firecrawl via `docker compose` inside one Debian 13 LXC.

**Architecture:** `ct/firecrawl.sh` creates an unprivileged Debian 13 LXC via `build.func`. `install/firecrawl-install.sh` installs Docker via `setup_docker`, clones the official `firecrawl/firecrawl` repo to `/opt/firecrawl`, flips the compose from local `build:` to prebuilt GHCR `image:`, generates `.env` with auto-generated secrets and an interactive (optional) OpenAI-compatible AI config, adds a minimal restart-policy override, and starts only the 5 core services. No custom systemd service.

**Tech Stack:** Bash, community-scripts `build.func`/`core.func`/`tools.func`, Docker + docker compose, official Firecrawl compose (`docker-compose.yaml`).

**Reference spec:** `docs/superpowers/specs/2026-07-14-firecrawl-community-script-design.md`

## Global Constraints

- Shebang `#!/usr/bin/env bash`; quote all variables; pass `shellcheck` against repo `.shellcheckrc`.
- Copyright header block on both scripts: `Copyright (c) 2021-2026 community-scripts ORG`, `License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE`, `Source: https://firecrawl.dev | Github: https://github.com/firecrawl/firecrawl`.
- App display name: `APP="Firecrawl"`. Lowercase script/file base name: `firecrawl`.
- LXC defaults: `var_cpu=4`, `var_ram=8192`, `var_disk=60`, `var_os=debian`, `var_version=13`, `var_unprivileged=1`, `var_tags="scraping;ai;crawler"`. All via `${var_x:-default}`.
- Install dir: `/opt/firecrawl`. API host port: `3002`. Credentials file: `~/firecrawl.creds`.
- Firecrawl source: `https://github.com/firecrawl/firecrawl.git` (branch `main`, shallow clone).
- Env baseline (SELF_HOST.md): `PORT=3002`, `HOST=0.0.0.0`, `USE_DB_AUTHENTICATION=false`.
- Core services to run explicitly (FoundationDB must NOT start): `api playwright-service redis rabbitmq nuq-postgres`.
- Never set `NUQ_BACKEND=fdb`.
- Prebuilt images: `ghcr.io/firecrawl/firecrawl` (api), `ghcr.io/firecrawl/playwright-service:latest`, `ghcr.io/firecrawl/nuq-postgres:latest`; `redis:alpine` and `rabbitmq:3-management` are already images.
- Install-script skeleton order: `source $FUNCTIONS_FILE_PATH` → `color` → `verb_ip6` → `catch_errors` → `setting_up_container` → `network_check` → `update_os` → app steps → `motd_ssh` → `customize` → `cleanup_lxc`.
- Use `msg_info`/`msg_ok`/`msg_error`/`msg_warn`; wrap noisy commands in `$STD`.

**Testing note:** There is no unit-test framework for these shell scripts. "Verification" per task means static checks: `bash -n` (syntax) and `shellcheck`. Full runtime verification requires a Proxmox host and is a dedicated final task (Task 6) intended to run in the Proxmox VE test-VM session. Do not claim runtime success without it.

---

### Task 1: ASCII header `ct/headers/firecrawl`

**Files:**
- Create: `ct/headers/firecrawl`

**Interfaces:**
- Produces: header art loaded by `header_info "$APP"` in `ct/firecrawl.sh`. Filename must be exactly `firecrawl` (lowercase, matches `NSAPP`).

- [ ] **Step 1: Generate the header art**

The repo headers use the figlet **Slant** font (see `ct/headers/homeassistant`). Generate:

```bash
# Preferred (if figlet available):
figlet -f slant "Firecrawl" > ct/headers/firecrawl
# Fallback: use https://patorjk.com/software/taag/ font "Slant", text "Firecrawl",
# and paste the result into ct/headers/firecrawl (trailing spaces preserved).
```

If `figlet` is not installed and no font available, write this exact content to `ct/headers/firecrawl`:

```
    ______ _                                  __
   / ____/(_)_____ ___   _____ _____ ____ _ _      __ / /
  / /_   / // ___// _ \ / ___// ___// __ `/| | /| / // /
 / __/  / // /   /  __// /__ / /   / /_/ / | |/ |/ // /
/_/    /_//_/    \___/ \___//_/    \__,_/  |__/|__//_/
```

- [ ] **Step 2: Verify the file exists and is non-empty**

Run: `test -s ct/headers/firecrawl && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add ct/headers/firecrawl
git commit -m "feat(firecrawl): add ct header art"
```

---

### Task 2: `ct/firecrawl.sh` (LXC creation + update path)

**Files:**
- Create: `ct/firecrawl.sh`

**Interfaces:**
- Consumes: `misc/build.func` functions (`header_info`, `variables`, `color`, `catch_errors`, `start`, `build_container`, `description`, `check_container_storage`, `check_container_resources`, color vars `GN/YW/BGN/CL`, `$IP`, `$STD`).
- Produces: an LXC with `/opt/firecrawl` (created by Task 3-5 install script) and an `update_script()` that upgrades it.

- [ ] **Step 1: Write the full script**

Create `ct/firecrawl.sh` with exactly:

```bash
#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2021-2026 community-scripts ORG
# Author: esatbayhan
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://firecrawl.dev | Github: https://github.com/firecrawl/firecrawl

APP="Firecrawl"
var_tags="${var_tags:-scraping;ai;crawler}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-8192}"
var_disk="${var_disk:-60}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources
  if [[ ! -d /opt/firecrawl ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi
  msg_info "Updating ${APP}"
  cd /opt/firecrawl || exit
  $STD git pull --ff-only
  $STD docker compose pull api playwright-service redis rabbitmq nuq-postgres
  $STD docker compose up -d api playwright-service redis rabbitmq nuq-postgres
  msg_ok "Updated ${APP}"
  exit
}

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:3002${CL}"
echo -e "${TAB}${GATEWAY}${BGN}Queue Admin: http://${IP}:3002/admin/<BULL_AUTH_KEY>/queues${CL}"
```

- [ ] **Step 2: Syntax check**

Run: `bash -n ct/firecrawl.sh && echo OK`
Expected: `OK` (note: `source <(curl ...)` at runtime is not fetched by `-n`).

- [ ] **Step 3: shellcheck**

Run: `shellcheck -x ct/firecrawl.sh || true`
Expected: no errors other than SC1090/SC1091 (dynamic source) which the repo ignores; compare against `shellcheck -x ct/homeassistant.sh` output for parity.

- [ ] **Step 4: Commit**

```bash
git add ct/firecrawl.sh
git commit -m "feat(firecrawl): add ct LXC creation script"
```

---

### Task 3: `install/firecrawl-install.sh` — skeleton, deps, Docker, clone

**Files:**
- Create: `install/firecrawl-install.sh`

**Interfaces:**
- Consumes: `$FUNCTIONS_FILE_PATH` (provides `color`, `verb_ip6`, `catch_errors`, `setting_up_container`, `network_check`, `update_os`, `setup_docker`, `msg_*`, `$STD`, `motd_ssh`, `customize`, `cleanup_lxc`).
- Produces: `/opt/firecrawl` containing a fresh clone of the official repo. Later tasks (4, 5) append `.env` generation, compose patching, and startup before the `motd_ssh`/`customize`/`cleanup_lxc` tail.

- [ ] **Step 1: Write skeleton through clone**

Create `install/firecrawl-install.sh`:

```bash
#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: esatbayhan
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://firecrawl.dev | Github: https://github.com/firecrawl/firecrawl

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt-get install -y \
  git \
  jq \
  openssl \
  ca-certificates
msg_ok "Installed Dependencies"

setup_docker

msg_info "Cloning Firecrawl"
$STD git clone --depth 1 https://github.com/firecrawl/firecrawl.git /opt/firecrawl
msg_ok "Cloned Firecrawl"

motd_ssh
customize
cleanup_lxc
```

- [ ] **Step 2: Syntax check**

Run: `bash -n install/firecrawl-install.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: shellcheck**

Run: `shellcheck -x install/firecrawl-install.sh || true`
Expected: parity with `shellcheck -x install/homeassistant-install.sh` (ignore SC1090/SC1091).

- [ ] **Step 4: Commit**

```bash
git add install/firecrawl-install.sh
git commit -m "feat(firecrawl): add install skeleton with docker + repo clone"
```

---

### Task 4: `.env` generation + interactive AI prompt + compose patch + override

**Files:**
- Modify: `install/firecrawl-install.sh` (insert between the "Cloned Firecrawl" block and `motd_ssh`)

**Interfaces:**
- Consumes: `/opt/firecrawl` from Task 3.
- Produces: `/opt/firecrawl/.env`, patched `/opt/firecrawl/docker-compose.yaml` (no `build:` remaining), `/opt/firecrawl/docker-compose.override.yaml` (restart policy), `~/firecrawl.creds`. Consumed by Task 5 startup.

- [ ] **Step 1: Insert secret generation + `.env`**

Insert after the `msg_ok "Cloned Firecrawl"` line:

```bash
msg_info "Generating Configuration"
POSTGRES_PASSWORD="$(openssl rand -hex 24)"
BULL_AUTH_KEY="$(openssl rand -hex 24)"
cat <<EOF >/opt/firecrawl/.env
PORT=3002
HOST=0.0.0.0
USE_DB_AUTHENTICATION=false

POSTGRES_USER=firecrawl
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=firecrawl
POSTGRES_HOST=nuq-postgres
POSTGRES_PORT=5432

BULL_AUTH_KEY=${BULL_AUTH_KEY}

OPENAI_API_KEY=
OPENAI_BASE_URL=
MODEL_NAME=
EOF
msg_ok "Generated Configuration"
```

- [ ] **Step 2: Insert interactive AI prompt**

Insert after the "Generated Configuration" block. Uses `whiptail` (available in the container) and only prompts in interactive mode:

```bash
if [[ -t 0 ]] && whiptail --backtitle "Firecrawl" --title "AI Provider (optional)" \
  --yesno "Configure an AI provider now?\n\nFirecrawl only needs it for /extract and JSON output.\nScrape/crawl work without it. You can add it later in\n/opt/firecrawl/.env" 14 68; then
  FC_KEY="$(whiptail --backtitle "Firecrawl" --title "API Key" --inputbox "Enter the API key (OpenAI-compatible):" 10 68 3>&1 1>&2 2>&3)"
  FC_URL="$(whiptail --backtitle "Firecrawl" --title "Base URL (optional)" --inputbox "OpenAI-compatible base URL.\nEmpty = OpenAI default.\nDeepSeek: https://api.deepseek.com/v1\nOllama: http://host.docker.internal:11434/api" 12 68 3>&1 1>&2 2>&3)"
  FC_MODEL="$(whiptail --backtitle "Firecrawl" --title "Model (optional)" --inputbox "Model name. Empty = Firecrawl default (gpt-4o-mini)." 10 68 3>&1 1>&2 2>&3)"
  if [[ -n "$FC_KEY" ]]; then
    sed -i "s|^OPENAI_API_KEY=.*|OPENAI_API_KEY=${FC_KEY}|" /opt/firecrawl/.env
    [[ -n "$FC_URL" ]] && sed -i "s|^OPENAI_BASE_URL=.*|OPENAI_BASE_URL=${FC_URL}|" /opt/firecrawl/.env
    [[ -n "$FC_MODEL" ]] && sed -i "s|^MODEL_NAME=.*|MODEL_NAME=${FC_MODEL}|" /opt/firecrawl/.env
    msg_ok "AI provider configured"
  else
    msg_warn "No API key entered; AI features disabled (add later in /opt/firecrawl/.env)"
  fi
else
  msg_warn "AI provider not configured; add later in /opt/firecrawl/.env then 'docker compose up -d'"
fi
```

- [ ] **Step 3: Insert compose `build:` → `image:` patch**

Insert after the AI block. Edits the three services and asserts no `build:` remains:

```bash
msg_info "Configuring Docker images"
COMPOSE=/opt/firecrawl/docker-compose.yaml
# api (via x-common-service anchor)
sed -i 's|^  # image: ghcr.io/firecrawl/firecrawl$|  image: ghcr.io/firecrawl/firecrawl|' "$COMPOSE"
sed -i 's|^  build: apps/api$|  # build: apps/api|' "$COMPOSE"
# playwright-service
sed -i 's|^    # image: ghcr.io/firecrawl/playwright-service:latest$|    image: ghcr.io/firecrawl/playwright-service:latest|' "$COMPOSE"
sed -i 's|^    build: apps/playwright-service-ts$|    # build: apps/playwright-service-ts|' "$COMPOSE"
# nuq-postgres
sed -i 's|^    # image: ghcr.io/firecrawl/nuq-postgres:latest$|    image: ghcr.io/firecrawl/nuq-postgres:latest|' "$COMPOSE"
sed -i 's|^    build: apps/nuq-postgres$|    # build: apps/nuq-postgres|' "$COMPOSE"
if grep -qE '^\s*build:' "$COMPOSE"; then
  msg_error "Compose still contains an active build: directive — upstream layout changed. Aborting."
  grep -nE '^\s*build:' "$COMPOSE"
  exit 1
fi
msg_ok "Configured Docker images"
```

- [ ] **Step 4: Insert restart-policy override**

Insert after the image patch:

```bash
msg_info "Writing compose override"
cat <<'EOF' >/opt/firecrawl/docker-compose.override.yaml
services:
  api:
    restart: unless-stopped
  playwright-service:
    restart: unless-stopped
  redis:
    restart: unless-stopped
  rabbitmq:
    restart: unless-stopped
  nuq-postgres:
    restart: unless-stopped
EOF
msg_ok "Wrote compose override"
```

- [ ] **Step 5: Insert credentials file**

Insert after the override block:

```bash
{
  echo "Firecrawl credentials"
  echo "API URL: http://<LXC-IP>:3002"
  echo "POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}"
  echo "BULL_AUTH_KEY: ${BULL_AUTH_KEY}"
  echo "Queue Admin: http://<LXC-IP>:3002/admin/${BULL_AUTH_KEY}/queues"
} >~/firecrawl.creds
```

- [ ] **Step 6: Syntax + shellcheck**

Run: `bash -n install/firecrawl-install.sh && shellcheck -x install/firecrawl-install.sh || true`
Expected: no new errors beyond ignored SC1090/SC1091.

- [ ] **Step 7: Verify sed targets against current upstream compose (static)**

Run against the local official checkout to confirm the exact lines the `sed` patterns target still exist:

```bash
grep -nE '^\s*(# )?image: ghcr.io/firecrawl|^\s*build: apps/' /home/arch/projects/meta/firecrawl/docker-compose.yaml
```
Expected: shows the `# image:` comment lines and `build:` lines matching the patterns in Step 3. If they differ, update the `sed` patterns before committing.

- [ ] **Step 8: Commit**

```bash
git add install/firecrawl-install.sh
git commit -m "feat(firecrawl): env, AI prompt, compose image patch, override, creds"
```

---

### Task 5: Startup + health wait

**Files:**
- Modify: `install/firecrawl-install.sh` (insert before `motd_ssh`)

**Interfaces:**
- Consumes: patched compose + `.env` + override from Task 4.
- Produces: running containers; `motd_ssh`/`customize`/`cleanup_lxc` remain the final lines.

- [ ] **Step 1: Insert start + health wait**

Insert immediately before the `motd_ssh` line:

```bash
msg_info "Starting Firecrawl (pulling images, patience)"
cd /opt/firecrawl || exit
$STD docker compose up -d api playwright-service redis rabbitmq nuq-postgres
for i in {1..60}; do
  if curl -fsS "http://localhost:3002/v1/health" >/dev/null 2>&1; then
    msg_ok "Firecrawl is up"
    break
  fi
  sleep 3
  if [[ $i -eq 60 ]]; then
    msg_warn "Firecrawl did not answer /v1/health within 180s; check 'docker compose logs'"
  fi
done
```

- [ ] **Step 2: Syntax + shellcheck**

Run: `bash -n install/firecrawl-install.sh && shellcheck -x install/firecrawl-install.sh || true`
Expected: no new errors.

- [ ] **Step 3: Confirm final structure order**

Run: `grep -nE 'setup_docker|docker compose up|motd_ssh|customize|cleanup_lxc' install/firecrawl-install.sh`
Expected order: `setup_docker` < `docker compose up` < `motd_ssh` < `customize` < `cleanup_lxc`.

- [ ] **Step 4: Commit**

```bash
git add install/firecrawl-install.sh
git commit -m "feat(firecrawl): start core services with health wait"
```

---

### Task 6: Runtime verification on Proxmox VE test VM

> Runs in the Proxmox VE test-VM session (nested PVE), NOT on the Arch host. This is the only task that proves real correctness.

**Files:** none (may produce fixes back into Tasks 1-5 files).

- [ ] **Step 1: Serve the branch to the PVE host**

Push the `firecrawl-script` branch (or copy the repo into the VM). On the PVE host run the ct script pointing at your fork/branch raw URLs (edit the `build.func` source line temporarily to your fork if testing pre-merge), or run locally per community-scripts dev docs.

- [ ] **Step 2: Create the container**

Run `bash ct/firecrawl.sh`, accept defaults (4C/8G/60G, Debian 13, unprivileged). Expected: LXC created, Docker installed, repo cloned, images pulled.

- [ ] **Step 3: Verify containers**

Inside the LXC: `cd /opt/firecrawl && docker compose ps`
Expected: `api`, `playwright-service`, `redis`, `rabbitmq`, `nuq-postgres` all Up. `foundationdb*` must be ABSENT.

- [ ] **Step 4: Verify API health + scrape**

```bash
curl -fsS http://localhost:3002/v1/health
curl -fsS -X POST http://localhost:3002/v1/scrape -H 'Content-Type: application/json' \
  -d '{"url":"https://example.com"}'
```
Expected: health OK; scrape returns JSON with page content.

- [ ] **Step 5: Verify autostart**

Reboot the LXC (`reboot`); after boot `docker compose ps` shows all 5 services Up again (restart policy works).

- [ ] **Step 6: Verify memory behaviour**

Under an example crawl, watch `docker stats`. If `api`/`playwright` OOM at 8 GB RAM, record it and raise `var_ram` default (e.g. to 12288) or lower `mem_limit`; apply the fix to `ct/firecrawl.sh` / compose patch and re-test.

- [ ] **Step 7: Verify update path**

Run `update` (the community-scripts update entrypoint) or re-run `ct/firecrawl.sh` and choose update. Expected: `git pull` + `docker compose pull/up` succeed, image patch still valid, services healthy.

- [ ] **Step 8: Commit any fixes**

```bash
git add -A && git commit -m "fix(firecrawl): adjustments from Proxmox runtime testing"
```

---

## Self-Review

**Spec coverage:**
- Spec §4.1 ct script → Task 2. ✓
- Spec §4.2 install flow → Tasks 3–5. ✓
- Spec §4.3 `.env` → Task 4 Step 1. ✓
- Spec §4.4 compose patch + explicit services + override → Task 4 Steps 3–4, Task 5 Step 1. ✓
- Spec §4.5 AI prompt → Task 4 Step 2. ✓
- Spec §4.6 header → Task 1. ✓
- Spec §5 known risks (memory, docker-in-lxc, GHCR, patch drift, health, FDB) → Task 6 Steps 3–7 + Task 4 Step 7 assertion. ✓
- Spec §6 verification (shellcheck + runtime) → per-task static checks + Task 6. ✓
- `~/firecrawl.creds` → Task 4 Step 5. ✓

**Placeholder scan:** No TBD/TODO left; all code blocks concrete. The `<BULL_AUTH_KEY>` literal in the ct final echo is intentional (the ct host script has no access to the generated key; the real key is in `~/firecrawl.creds` and the queue URL there is fully expanded).

**Type/name consistency:** Install dir `/opt/firecrawl`, service list `api playwright-service redis rabbitmq nuq-postgres`, port `3002`, env var names, and secret var names (`POSTGRES_PASSWORD`, `BULL_AUTH_KEY`) are consistent across Tasks 2, 4, and 5.
