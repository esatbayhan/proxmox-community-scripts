# Firecrawl community-scripts LXC — Design Spec

Date: 2026-07-14
Status: Approved (design), pending implementation + real-world test on Proxmox
Target repo: `esatbayhan/proxmox-community-scripts` (fork of community-scripts/ProxmoxVE)
Branch: `firecrawl-script`

## 1. Goal

Provide a Firecrawl install that follows the community-scripts standard: a single
Debian LXC that runs the **official** Firecrawl (`firecrawl/firecrawl`) via
`docker compose`, so it can be consumed as a service by other tools on the same
Proxmox host (concretely: a self-hosted Hermes agent calling the Firecrawl API).

Long-term this *may* become a ProxmoxVED PR, but that is explicitly **not** a goal
right now. The immediate goal is a clean, maintainable script for personal use.

## 2. Context & key findings

Two reference repos were explored:

- `pve-firecrawl` — a **community fork** (esatbayhan/pve-firecrawl). Used **only as
  inspiration**, NOT authoritative. It targets DeepSeek by default, ships a custom
  systemd service, an override compose, and a `check.sh`. We deliberately do **not**
  mirror it.
- `firecrawl` — the **official upstream** (`firecrawl/firecrawl`). This is the
  authoritative source. It ships `SELF_HOST.md` and a single dual-mode
  `docker-compose.yaml`.

Decision: **base the script on the official repo**, deviate as little as possible
from official defaults to minimize maintenance.

### Official Firecrawl facts (verified in the repo)

- Self-hosting docs: `SELF_HOST.md`. Single compose file `docker-compose.yaml` at repo root.
- Services in `docker-compose.yaml`:
  - `playwright-service` — `build: apps/playwright-service-ts` (image comment:
    `ghcr.io/firecrawl/playwright-service:latest`). Limits: 2 CPU / 4G.
  - `api` — uses `x-common-service` anchor with `build: apps/api` (image comment:
    `ghcr.io/firecrawl/firecrawl`). Limits: 4 CPU / 8G. Exposes `${PORT:-3002}`.
  - `redis` — `image: redis:alpine` (already prebuilt).
  - `rabbitmq` — `image: rabbitmq:3-management` (already prebuilt, has healthcheck).
  - `nuq-postgres` — `build: apps/nuq-postgres` (image comment:
    `ghcr.io/firecrawl/nuq-postgres:latest`). Default queue backend.
  - `foundationdb` + `foundationdb-init` — **experimental**, only used when
    `NUQ_BACKEND=fdb`. These are defined WITHOUT a compose profile, so a bare
    `docker compose up -d` would start them too. We must avoid running them (see 4.4).
- `build:` directives to flip to prebuilt GHCR images live at:
  - line 6/7 (image comment / build) inside `x-common-service` → used by `api`
  - line 66/67 → `playwright-service`
  - line 159/160 → `nuq-postgres`
- Default port: **3002** (host). Playwright 3000, postgres 5432, redis 6379,
  rabbitmq 5672 are internal only.
- **Auth**: with `USE_DB_AUTHENTICATION=false` (self-hosted default) the API
  **bypasses authentication entirely** — no Firecrawl API key needed. Callers
  (Hermes) hit `http://<IP>:3002` with no Bearer token.
- **AI provider default**: `OPENAI_API_KEY`, `OPENAI_BASE_URL`, `MODEL_NAME` are all
  optional with **no default**. The effective default provider is OpenAI; code uses
  hardcoded `gpt-4o-mini` (retry `gpt-4.1`) when `MODEL_NAME` is empty. AI is only
  needed for `/extract` and JSON output; scrape/crawl work without it.
- `BULL_AUTH_KEY` only protects the Bull queue admin UI at
  `/admin/<BULL_AUTH_KEY>/queues`. Default in SELF_HOST.md is `CHANGEME`.

### community-scripts standard facts (verified)

- Two files per app: `ct/<app>.sh` (creates LXC via `build.func`) and
  `install/<app>-install.sh` (runs inside the container). Plus an ASCII header at
  `ct/headers/<app>`.
- `build.func` defaults: `var_nesting=1` (already enabled → Docker works),
  `var_keyctl=0`. Home Assistant (a Docker app) runs with just nesting, so **no
  special feature flags are needed** in `ct/firecrawl.sh`.
- First-class helper `setup_docker` in `misc/tools.func` installs Docker + the
  compose plugin (Debian: `docker.io` by default, or `USE_DOCKER_REPO="true"
  setup_docker` for docker-ce). Compose is invoked as `docker compose`.
- Install-script skeleton: `source $FUNCTIONS_FILE_PATH` → `color` → `verb_ip6` →
  `catch_errors` → `setting_up_container` → `network_check` → `update_os` → app
  steps → `motd_ssh` → `customize` → `cleanup_lxc`.
- Message helpers: `msg_info` / `msg_ok` / `msg_error` / `msg_warn`; wrap noisy
  commands with `$STD`.
- Secrets convention: write app config to a `.env`, and echo human-relevant
  credentials to `~/<app>.creds`.
- No JSON/metadata files in the repo; website metadata is handled separately
  (PocketBase / ProxmoxVED process). Out of scope here.
- Repo lint: `.shellcheckrc` present — scripts should pass `shellcheck`.

## 3. Decisions (from brainstorming)

| Topic | Decision |
|---|---|
| Base source | Official `firecrawl/firecrawl` (not the fork) |
| Runtime | `docker compose` inside one Debian 13 LXC |
| Images | Prebuilt GHCR images (flip `build:` → `image:`), no local build |
| Resources | `var_cpu=4`, `var_ram=8192`, `var_disk=60` (user can override in dialog) |
| Autostart | compose `restart: unless-stopped` (no custom systemd service) |
| AI setup | Interactive, OpenAI-compatible, **no provider forced**. Prompt for API key (empty = skip); optionally Base-URL + model for DeepSeek/Ollama/etc. Empty = Firecrawl default (OpenAI) |
| Secrets | Auto-generate `POSTGRES_PASSWORD` + `BULL_AUTH_KEY` (≥32 chars). Also written to `~/firecrawl.creds` |
| Firecrawl API auth | None (self-hosted bypass); callers use no token |
| Files | Only the 3 standard files: `ct/firecrawl.sh`, `install/firecrawl-install.sh`, `ct/headers/firecrawl` |
| Not included | fork's systemd service, fork's **hardening** override (healthchecks/log-rotation), `check.sh`; JSON/PocketBase metadata. (A minimal, generated restart-only override IS allowed — see 4.4) |

## 4. Architecture

### 4.1 `ct/firecrawl.sh`

Standard boilerplate:

```
source <(curl -fsSL .../misc/build.func)
# Copyright (c) 2021-2026 community-scripts ORG
# Author: <handle>
# License: MIT
# Source: https://firecrawl.dev | Github: https://github.com/firecrawl/firecrawl

APP="Firecrawl"
var_tags="${var_tags:-scraping;ai;crawler}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-8192}"
var_disk="${var_disk:-60}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"; variables; color; catch_errors

update_script():
  - check_container_storage; check_container_resources
  - if [ ! -d /opt/firecrawl ]: msg_error "No Firecrawl Installation Found!"; exit
  - cd /opt/firecrawl
  - git pull (fast-forward; upstream main)
  - docker compose pull   (for the pinned service list)
  - docker compose up -d  (same explicit service list as install)
  - msg_ok "Updated successfully!"

start; build_container; description
final echo: URL http://<IP>:3002  and Bull queue admin URL
```

### 4.2 `install/firecrawl-install.sh` — flow

1. Standard header (`setting_up_container`, `network_check`, `update_os`).
2. `msg_info` "Installing Dependencies": `git`, `ca-certificates`, `openssl`,
   `curl`, `jq` (via `$STD apt install`).
3. `setup_docker` (installs Docker + compose plugin).
4. Clone official repo: `git clone --depth 1 https://github.com/firecrawl/firecrawl.git /opt/firecrawl`.
5. **Patch compose** `/opt/firecrawl/docker-compose.yaml` (see 4.4).
6. **Generate `.env`** at `/opt/firecrawl/.env` (see 4.3).
7. **Interactive AI prompt** (see 4.5) — writes OPENAI_* vars into `.env`.
8. Write `~/firecrawl.creds` with the generated secrets + URLs.
9. Start: `docker compose up -d <explicit service list>`; then health-wait loop on
   `http://localhost:3002/v1/health` (bounded, ~120s, with `msg_warn` on timeout
   rather than hard fail).
10. `motd_ssh`; `customize`; `cleanup_lxc`.

### 4.3 `.env` contents (mirrors SELF_HOST.md)

```
PORT=3002
HOST=0.0.0.0
USE_DB_AUTHENTICATION=false

POSTGRES_USER=firecrawl
POSTGRES_PASSWORD=<openssl rand -base64 32, sanitized>
POSTGRES_DB=firecrawl
POSTGRES_HOST=nuq-postgres
POSTGRES_PORT=5432

BULL_AUTH_KEY=<openssl rand -hex 32>

# AI (optional; filled by interactive prompt, else left blank = OpenAI default)
OPENAI_API_KEY=
OPENAI_BASE_URL=
MODEL_NAME=
```

Note: the compose reads these via `${POSTGRES_PASSWORD:-postgres}` etc., so setting
non-default POSTGRES_* is consistent across `api` and `nuq-postgres` (both read the
same env from `.env`).

### 4.4 Compose patch strategy

Goal: use prebuilt GHCR images and avoid the experimental FoundationDB services.

- Flip `build:` → `image:` for the three build services by uncommenting the
  `# image: ghcr.io/...` lines and commenting the matching `build:` lines. Because
  `api` uses the `x-common-service` anchor, editing the anchor (lines 6/7) switches
  `api`. `playwright-service` (66/67) and `nuq-postgres` (159/160) are edited in
  place. Implementation: prefer a small, targeted `sed`/`python` transform keyed on
  the exact known comment/`build:` lines; assert afterwards that no `build:` remains.
- Ensure `restart: unless-stopped` for the 5 core services. Because compose anchors
  make blanket in-place restart injection fiddly and upgrade-unsafe, the chosen
  approach is: **start only the required services explicitly** AND ship restart
  policy via a **minimal generated `docker-compose.override.yaml`** that sets
  `restart: unless-stopped` on `api`, `playwright-service`, `redis`, `rabbitmq`,
  `nuq-postgres`. This does not touch the upstream file and survives `git pull`.
- Avoid FoundationDB: never pass `NUQ_BACKEND=fdb`, and start services explicitly:
  `docker compose up -d api playwright-service redis rabbitmq nuq-postgres`. This
  keeps `foundationdb`/`foundationdb-init` from starting.

Rationale for a generated `override` for restart policy: it does not touch the
upstream file, survives `git pull` on update, and is idiomatic docker-compose. The
`build→image` flip, however, must edit the upstream file (an override cannot remove
a `build:` from a service). We accept that one in-place edit and re-apply it on
update if needed (update step re-runs the patch idempotently).

### 4.5 Interactive AI prompt

- Ask: "Configure an AI provider now? Firecrawl only needs it for /extract and JSON
  output; scrape/crawl work without it. [y/N]".
- If yes:
  - Prompt API key (required if proceeding).
  - Prompt Base-URL (default empty → OpenAI). Show hints: OpenAI
    `https://api.openai.com/v1`, DeepSeek `https://api.deepseek.com/v1`, Ollama
    `http://host.docker.internal:11434/api`.
  - Prompt model name (default empty → Firecrawl's built-in `gpt-4o-mini`).
- Write provided values into `.env`. Empty answers stay empty (= official default).
- Non-interactive/unattended installs: skip cleanly (no AI configured), leaving
  blank vars. A `msg_warn` notes AI can be added later by editing
  `/opt/firecrawl/.env` and running `docker compose up -d`.

### 4.6 `ct/headers/firecrawl`

ASCII-art "Firecrawl" in the standard figlet font used by the repo's other headers.

## 5. Known risks / things to verify on the Proxmox test VM

- **Memory**: `api` has `mem_limit: 8G` and `playwright-service` `4G`. In an 8 GB
  LXC these are limits (not reservations), but under load OOM is possible. Verify;
  if problematic, either raise LXC RAM to 12–16 GB by default or lower `mem_limit`.
- **Docker-in-LXC**: confirm `setup_docker` + nesting is sufficient (no keyctl
  needed), same as Home Assistant.
- **GHCR pulls**: `ghcr.io/firecrawl/*:latest` tags exist and pull without auth.
- **Compose patch**: line-based edits must match the current upstream file; add a
  post-edit assertion. Upstream layout can drift — the update path re-applies the
  patch and should fail loudly if the expected anchors are gone.
- **Health endpoint**: confirm `/v1/health` returns 200 once containers are healthy;
  tune the wait timeout accordingly.
- **FoundationDB**: confirm the explicit service list keeps FDB containers down and
  the api starts fine on the postgres backend (default `NUQ_BACKEND` empty).

## 6. Verification plan

- Static: `shellcheck` both scripts against repo `.shellcheckrc`; compare structure
  against `install/homeassistant-install.sh` and `install/npmplus-install.sh`.
- Runtime (nested Proxmox VE test VM): run `ct/firecrawl.sh` end-to-end, confirm LXC
  creation, Docker install, image pulls, all 5 containers up, `/v1/health` 200, a
  sample `POST /v1/scrape`, reboot → containers auto-start, and `update` path works.

## 7. Out of scope

- ProxmoxVED submission and PocketBase/website metadata.
- Native (non-Docker) install.
- systemd service, override hardening beyond restart policy, and `check.sh`.
- Valkey/FoundationDB backends, proxy/SearXNG/webhook configuration (user can add
  later via `.env`).
