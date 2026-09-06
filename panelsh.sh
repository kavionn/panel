#!/bin/bash

set -e
set -o pipefail

######################################################################################
#                                                                                    #
# Project 'pterodactyl-installer'                                                    #
#                                                                                    #
# Copyright (C) 2018 - 2026, Vilhelm Prytz, <vilhelm@prytznet.se>                    #
#                                                                                    #
#   This program is free software: you can redistribute it and/or modify             #
#   it under the terms of the GNU General Public License as published by             #
#   the Free Software Foundation, either version 3 of the License, or                #
#   (at your option) any later version.                                              #
#                                                                                    #
#   This program is distributed in the hope that it will be useful,                  #
#   but WITHOUT ANY WARRANTY; without even the implied warranty of                   #
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the                    #
#   GNU General Public License for more details.                                     #
#                                                                                    #
#   You should have received a copy of the GNU General Public License                #
#   along with this program.  If not, see <https://www.gnu.org/licenses/>.           #
#                                                                                    #
# https://github.com/pterodactyl-installer/pterodactyl-installer/blob/master/LICENSE #
#                                                                                    #
# This script is not associated with the official Pterodactyl Project.               #
# https://github.com/pterodactyl-installer/pterodactyl-installer                     #
#                                                                                    #
######################################################################################

export GITHUB_SOURCE="v1.3.0"
export SCRIPT_RELEASE="v1.3.0"
export GITHUB_BASE_URL="https://raw.githubusercontent.com/pterodactyl-installer/pterodactyl-installer"

LOG_PATH="/var/log/pterodactyl-installer.log"
PANEL_PATH="${PANEL_PATH:-/var/www/pterodactyl}"
PANEL_BACKUP_ROOT="${PANEL_BACKUP_ROOT:-/var/backups/pterodactyl}"
NOOKTHEME_URL="${NOOKTHEME_URL:-https://github.com/Nookure/NookTheme/releases/latest/download/panel.tar.gz}"

# check for curl
if ! [ -x "$(command -v curl)" ]; then
  echo "* curl is required in order for this script to work."
  echo "* install using apt (Debian and derivatives) or yum/dnf (CentOS)"
  exit 1
fi

# Always remove lib.sh, before downloading it
[ -f /tmp/lib.sh ] && rm -rf /tmp/lib.sh
curl -sSL -o /tmp/lib.sh "$GITHUB_BASE_URL"/master/lib/lib.sh
# shellcheck source=lib/lib.sh
source /tmp/lib.sh

install_nooktheme() (
  set -Eeuo pipefail

  local panel_path="${PANEL_PATH%/}"
  local panel_parent="${panel_path%/*}"
  local panel_name="${panel_path##*/}"
  local timestamp
  local backup_dir
  local archive=""
  local db_option_file=""
  local db_dump_partial=""
  local maintenance_enabled=0
  local panel_owner

  cleanup_nooktheme() {
    local status=$?
    trap - EXIT

    [ -n "$db_option_file" ] && rm -f "$db_option_file"
    [ -n "$db_dump_partial" ] && rm -f "$db_dump_partial"
    [ -n "$archive" ] && rm -f "$archive"

    if [ "$maintenance_enabled" -eq 1 ] && [ "$status" -ne 0 ]; then
      echo "* NookTheme installation failed; attempting to bring the panel back online."
      (cd "$panel_path" && php artisan up) || true
      echo "* The pre-installation backup is available at: $backup_dir"
    fi

    exit "$status"
  }

  write_database_client_config() {
    php -r '
      $panelPath = $argv[1];
      $outputFile = $argv[2];

      chdir($panelPath);
      require $panelPath . "/vendor/autoload.php";
      $app = require $panelPath . "/bootstrap/app.php";
      $kernel = $app->make(Illuminate\Contracts\Console\Kernel::class);
      $kernel->bootstrap();

      $connectionName = (string) config("database.default");
      $connection = $app->make("db")->connection($connectionName);
      $database = $connection->getConfig();
      $driver = (string) ($database["driver"] ?? "");

      if (!in_array($driver, ["mysql", "mariadb"], true)) {
          fwrite(STDERR, "* Cannot create a database backup for unsupported connection: " . $driver . PHP_EOL);
          exit(2);
      }

      $databaseName = (string) ($database["database"] ?? "");
      $username = (string) ($database["username"] ?? "");
      if ($databaseName === "" || $username === "") {
          fwrite(STDERR, "* Cannot create a database backup: the resolved database name or username is empty." . PHP_EOL);
          exit(3);
      }

      $escape = static function ($value): string {
          return str_replace(
              ["\\", "\"", "\n", "\r"],
              ["\\\\", "\\\"", "\\n", "\\r"],
              (string) $value
          );
      };

      $lines = [
          "[client]",
          "user=\"" . $escape($username) . "\"",
          "password=\"" . $escape($database["password"] ?? "") . "\"",
      ];
      $socket = (string) ($database["unix_socket"] ?? "");
      if ($socket !== "") {
          $lines[] = "socket=\"" . $escape($socket) . "\"";
      } else {
          $host = (string) ($database["host"] ?? "127.0.0.1");
          $port = (string) ($database["port"] ?? "3306");
          $lines[] = "host=\"" . $escape($host) . "\"";
          $lines[] = "port=" . $port;
      }

      $contents = implode(PHP_EOL, $lines) . PHP_EOL;
      if (file_put_contents($outputFile, $contents, LOCK_EX) === false) {
          fwrite(STDERR, "* Cannot write the temporary database client configuration." . PHP_EOL);
          exit(4);
      }
      chmod($outputFile, 0600);
      echo $databaseName;
    ' "$panel_path" "$db_option_file"
  }

  trap cleanup_nooktheme EXIT

  if [ "${EUID}" -ne 0 ]; then
    echo "* NookTheme installation must be run as root."
    exit 1
  fi

  for required_command in php composer curl tar stat mktemp mysqldump; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
      echo "* Cannot install NookTheme: required command '$required_command' is missing."
      exit 1
    fi
  done

  if [ ! -f "$panel_path/artisan" ] || [ ! -f "$panel_path/.env" ]; then
    echo "* Cannot install NookTheme: no completed Pterodactyl installation was found at $panel_path."
    exit 1
  fi

  panel_owner="$(stat -c '%U:%G' "$panel_path/artisan")"
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup_dir="${PANEL_BACKUP_ROOT%/}/nooktheme-${timestamp}"
  archive="$(mktemp /tmp/nooktheme-panel.XXXXXX.tar.gz)"

  echo "* Downloading the latest NookTheme release."
  curl --fail --location --silent --show-error --retry 3 --retry-delay 2 \
    "$NOOKTHEME_URL" --output "$archive"
  tar -tzf "$archive" >/dev/null

  mkdir -p "$backup_dir"
  chmod 700 "$backup_dir"

  cd "$panel_path"
  php artisan down
  maintenance_enabled=1

  echo "* Backing up the current panel files to $backup_dir."
  tar -czf "$backup_dir/panel-files.tar.gz" -C "$panel_parent" "$panel_name"

  local db_database
  db_option_file="$(mktemp "$backup_dir/.mysql-client.XXXXXX")"
  chmod 600 "$db_option_file"
  db_database="$(write_database_client_config)"

  echo "* Backing up the Pterodactyl database."
  db_dump_partial="$backup_dir/database.sql.partial"
  mysqldump --defaults-extra-file="$db_option_file" \
    --single-transaction --quick --skip-lock-tables "$db_database" \
    >"$db_dump_partial"
  mv "$db_dump_partial" "$backup_dir/database.sql"
  db_dump_partial=""
  rm -f "$db_option_file"
  db_option_file=""

  echo "* Installing NookTheme."
  tar -xzf "$archive" -C "$panel_path"
  chmod -R 755 "$panel_path/storage" "$panel_path/bootstrap/cache"
  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction
  php artisan view:clear
  php artisan config:clear
  php artisan migrate --seed --force
  chown -R "$panel_owner" "$panel_path"
  php artisan queue:restart
  php artisan up
  maintenance_enabled=0

  echo "* NookTheme installation completed."
  echo "* Backup saved at: $backup_dir"
)

execute() {
  echo -e "\n\n* pterodactyl-installer $(date) \n\n" >>"$LOG_PATH"

  if [ "$1" == "nooktheme" ]; then
    install_nooktheme |& tee -a "$LOG_PATH"
    return 0
  fi

  [[ "$1" == *"canary"* ]] && export GITHUB_SOURCE="master" && export SCRIPT_RELEASE="canary"
  update_lib_source
  run_ui "${1//_canary/}" |& tee -a "$LOG_PATH"

  if [ "$1" == "panel" ]; then
    install_nooktheme |& tee -a "$LOG_PATH"
  fi

  if [[ -n $2 ]]; then
    echo -e -n "* Installation of $1 completed. Do you want to proceed to $2 installation? (y/N): "
    read -r CONFIRM
    if [[ "$CONFIRM" =~ [Yy] ]]; then
      execute "$2"
    else
      error "Installation of $2 aborted."
      exit 1
    fi
  fi
}

welcome ""

done=false
while [ "$done" == false ]; do
  options=(
    "Install the panel"
    "Install Wings"
    "Install both [0] and [1] on the same machine (wings script runs after panel)"
    "Install or update NookTheme only on an existing panel"
    # "Uninstall panel or wings\n"

    "Install panel with canary version of the script (the versions that lives in master, may be broken!)"
    "Install Wings with canary version of the script (the versions that lives in master, may be broken!)"
    "Install both [4] and [5] on the same machine (wings script runs after panel)"
    "Uninstall panel or wings with canary version of the script (the versions that lives in master, may be broken!)"
  )

  actions=(
    "panel"
    "wings"
    "panel;wings"
    "nooktheme"
    # "uninstall"

    "panel_canary"
    "wings_canary"
    "panel_canary;wings_canary"
    "uninstall_canary"
  )

  output "What would you like to do?"

  for i in "${!options[@]}"; do
    output "[$i] ${options[$i]}"
  done

  echo -n "* Input 0-$((${#actions[@]} - 1)): "
  read -r action

  [ -z "$action" ] && error "Input is required" && continue

  valid_input=("$(for ((i = 0; i <= ${#actions[@]} - 1; i += 1)); do echo "${i}"; done)")
  [[ ! " ${valid_input[*]} " =~ ${action} ]] && error "Invalid option"
  [[ " ${valid_input[*]} " =~ ${action} ]] && done=true && IFS=";" read -r i1 i2 <<<"${actions[$action]}" && execute "$i1" "$i2"
done

# Remove lib.sh, so next time the script is run the, newest version is downloaded.
rm -rf /tmp/lib.sh
