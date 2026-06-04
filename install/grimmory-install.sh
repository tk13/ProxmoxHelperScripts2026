#!/usr/bin/env bash

# Modified to be updated for 06-03-2026 from Booklore.

# Copyright (c) 2021-2026 community-scripts ORG
# Author: MickLesk (CanbiZ)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/grimmory-tools/grimmory

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt install -y ffmpeg
msg_ok "Installed Dependencies"

JAVA_VERSION="25" setup_java
NODE_VERSION="22" setup_nodejs
setup_mariadb
setup_yq
MARIADB_DB_NAME="grimmory_db" MARIADB_DB_USER="grimmory_user" MARIADB_DB_EXTRA_GRANTS="GRANT SELECT ON \`mysql\`.\`time_zone_name\`" setup_mariadb_db
fetch_and_deploy_gh_release "grimmory" "grimmory-tools/grimmory" "tarball"

msg_info "Building Frontend"
cd /opt/grimmory/frontend
$STD npm install --force
$STD npm run build --configuration=production
msg_ok "Built Frontend"

msg_info "Embedding Frontend into Backend"
mkdir -p /opt/grimmory/backend/src/main/resources/static
cp -r /opt/grimmory/frontend/dist/grimmory/browser/* /opt/grimmory/backend/src/main/resources/static/
msg_ok "Embedded Frontend into Backend"

msg_info "Creating Environment"
mkdir -p /opt/grimmory_storage/{data,books,bookdrop}
cat <<EOF >/opt/grimmory_storage/.env
# Database Configuration
DATABASE_URL=jdbc:mariadb://localhost:3306/${MARIADB_DB_NAME}
DATABASE_USERNAME=${MARIADB_DB_USER}
DATABASE_PASSWORD=${MARIADB_DB_PASS}

# App Configuration (Spring Boot mapping from app.* properties)
APP_PATH_CONFIG=/opt/grimmory_storage/data
APP_BOOKDROP_FOLDER=/opt/grimmory_storage/bookdrop
SERVER_PORT=6060
EOF
msg_ok "Created Environment"

msg_info "Building Backend"
cd /opt/grimmory/backend
APP_VERSION=$(get_latest_github_release "grimmory-tools/grimmory")
yq eval ".app.version = \"${APP_VERSION}\"" -i src/main/resources/application.yaml
$STD ./gradlew clean build -x test --no-daemon
mkdir -p /opt/grimmory/dist
JAR_PATH=$(find /opt/grimmory/backend/build/libs -maxdepth 1 -type f -name "backend-*.jar" ! -name "*plain*" | head -n1)
if [[ -z "$JAR_PATH" ]]; then
  msg_error "Backend JAR not found"
  exit 153
fi
cp "$JAR_PATH" /opt/grimmory/dist/app.jar
msg_ok "Built Backend"

msg_info "Creating Service"
cat <<EOF >/etc/systemd/system/grimmory.service
[Unit]
Description=Grimmory Java Service
After=network.target mariadb.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/grimmory/dist
ExecStart=/usr/bin/java -XX:+UseG1GC -XX:+UseStringDeduplication -XX:+UseCompactObjectHeaders -XX:MaxRAMPercentage=75.0 -XX:+ExitOnOutOfMemoryError -jar /opt/grimmory/dist/app.jar
EnvironmentFile=/opt/grimmory_storage/.env
SuccessExitStatus=143
TimeoutStopSec=10
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now grimmory
msg_ok "Created Service"

motd_ssh
customize
cleanup_lxc
