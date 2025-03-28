#!/usr/bin/env bash
# File: wordpress.sh
# Location: Save to your Proxmox host or host in your repository
# Usage: bash -c "$(wget -qLO - https://github.com/koncept-kit/ProxmoxVE/raw/main/ct/wordpress.sh)"
# Purpose: Main script for creating WordPress LXC container with HTTPS and PHPMyAdmin

source <(curl -s https://raw.githubusercontent.com/koncept-kit/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2021-2025 koncept-kit
# License: MIT | https://github.com/koncept-kit/ProxmoxVE/raw/main/LICENSE
# Source: https://wordpress.org/

## App Default Values
APP="Wordpress"
var_tags="blog;cms;wordpress"
var_disk="10"          # Increased disk size for more space
var_cpu="2"
var_ram="2048"
var_os="debian"
var_version="12"
var_install="wordpress-install"  # This references the wordpress-install.sh script

header_info "$APP" 
variables
color
catch_errors

function update_script() {
    header_info
    check_container_storage
    check_container_resources
    if [[ ! -f /var/www/html/wp-config.php ]]; then
        msg_error "No ${APP} Installation Found!"
        exit
    fi
    msg_error "Wordpress should be updated via the user interface."
    exit
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN} ${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access WordPress using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}https://${IP}/${CL}"
echo -e "${INFO}${YW} Access PHPMyAdmin using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}https://${IP}/phpmyadmin/${CL}"
echo -e "\n${INFO}${YW} Default WordPress database information:${CL}"
echo -e "${TAB}${YW}Database Name: ${GN}wordpress${CL}"
echo -e "${TAB}${YW}Username: ${GN}wpuser${CL}"
echo -e "${TAB}${YW}Password: ${GN}[Stored in /root/.wp_db_pass]${CL}"
echo -e "\n${INFO}${YW} Default PHPMyAdmin login:${CL}"
echo -e "${TAB}${YW}Username: ${GN}root${CL}"
echo -e "${TAB}${YW}Password: ${GN}[MariaDB root password stored in /root/.mariadb_root_password]${CL}"
echo -e "\n${INFO}${YW} Notes:${CL}"
echo -e "${TAB}${YW}- Self-signed SSL certificates are automatically regenerated on clone${CL}"
echo -e "${TAB}${YW}- Template is ready for immediate use after cloning${CL}"