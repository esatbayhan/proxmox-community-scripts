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
  # re-apply image patch (git pull restores upstream compose with build: directives)
  COMPOSE=/opt/firecrawl/docker-compose.yaml
  sed -i 's|^  # image: ghcr.io/firecrawl/firecrawl$|  image: ghcr.io/firecrawl/firecrawl|' "$COMPOSE"
  sed -i 's|^  build: apps/api$|  # build: apps/api|' "$COMPOSE"
  sed -i 's|^    # image: ghcr.io/firecrawl/playwright-service:latest$|    image: ghcr.io/firecrawl/playwright-service:latest|' "$COMPOSE"
  sed -i 's|^    build: apps/playwright-service-ts$|    # build: apps/playwright-service-ts|' "$COMPOSE"
  sed -i 's|^    # image: ghcr.io/firecrawl/nuq-postgres:latest$|    image: ghcr.io/firecrawl/nuq-postgres:latest|' "$COMPOSE"
  sed -i 's|^    build: apps/nuq-postgres$|    # build: apps/nuq-postgres|' "$COMPOSE"
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
