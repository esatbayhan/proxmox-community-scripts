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
