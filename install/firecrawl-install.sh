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

{
  echo "Firecrawl credentials"
  echo "API URL: http://<LXC-IP>:3002"
  echo "POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}"
  echo "BULL_AUTH_KEY: ${BULL_AUTH_KEY}"
  echo "Queue Admin: http://<LXC-IP>:3002/admin/${BULL_AUTH_KEY}/queues"
} >~/firecrawl.creds

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

motd_ssh
customize
cleanup_lxc
