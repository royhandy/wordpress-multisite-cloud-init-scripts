#!/usr/bin/env bash
set -euo pipefail
umask 027

# -----------------------------
# Config
# -----------------------------
ENV_FILE="/etc/server.env"

APP_USER="serveradmin"
APP_GROUP="www-data"

APP_NAME="Server Admin"
APP_PORT="8443"
APP_DIR="/var/www/server-admin"

TEMPLATE_MIGRATIONS="/opt/server-template/filament/migrations"

# -----------------------------
# Helpers
# -----------------------------
log() { printf "\n[%s] %s\n" "$(date -Is)" "$*"; }
die() { printf "\nERROR: %s\n" "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"
}

# -----------------------------
# Environment
# -----------------------------
source_env() {
  [[ -f "$ENV_FILE" ]] || die "Env file not found: $ENV_FILE"

  # shellcheck disable=SC1090
  set -a
  source "$ENV_FILE"
  set +a

  : "${WP_PRIMARY_DOMAIN:?}"
  : "${STATE_DIR:?}"
  : "${ADMIN_EMAIL:?}"
  : "${ADMIN_NAME:?}"
  : "${FILAMENT_ADMIN_PASSWORD:?}"
}

# -----------------------------
# Composer
# -----------------------------
install_composer() {
  command -v composer >/dev/null 2>&1 && return

  log "Installing Composer..."
  need_cmd php
  need_cmd curl

  local expected actual
  expected="$(curl -fsSL https://composer.github.io/installer.sig)"
  curl -fsSL -o /tmp/composer-setup.php https://getcomposer.org/installer
  actual="$(php -r "echo hash_file('sha384', '/tmp/composer-setup.php');")"

  [[ "$expected" == "$actual" ]] || die "Composer installer signature mismatch"

  php /tmp/composer-setup.php --quiet --install-dir=/usr/local/bin --filename=composer
  rm -f /tmp/composer-setup.php
}

# -----------------------------
# Laravel app
# -----------------------------
create_laravel_app() {
  if [[ -f "$APP_DIR/artisan" ]]; then
    log "Laravel app already exists"
    return
  fi

  log "Creating Laravel 12 app..."
  install -d -m 0750 -o "$APP_USER" -g "$APP_GROUP" "$(dirname "$APP_DIR")"

  sudo -u "$APP_USER" -H \
    composer create-project laravel/laravel:^12.0 "$APP_DIR" --no-interaction

  chown -R "$APP_USER:$APP_GROUP" "$APP_DIR"
  find "$APP_DIR" -type d -exec chmod 0750 {} +
  find "$APP_DIR" -type f -exec chmod 0640 {} +
  chmod -R g+w "$APP_DIR/storage" "$APP_DIR/bootstrap/cache"
}

# -----------------------------
# Database
# -----------------------------
mysql_exec() {
  mysql --protocol=socket "$@" 2>/dev/null || mysql "$@"
}

configure_app_env_and_db() {
  log "Configuring database and Laravel environment..."

  need_cmd mysql
  need_cmd openssl

  local db="server_admin"
  local user="serveradmin"
  local creds_file="${STATE_DIR}/server-admin-db.creds"
  local pass

  install -d -m 0700 -o root -g root "$STATE_DIR"

  if [[ -f "$creds_file" ]]; then
    log "Reusing existing database credentials"
    # shellcheck disable=SC1090
    source "$creds_file"
    pass="$DB_PASSWORD"
  else
    log "Generating new database credentials"
    pass="$(openssl rand -hex 24)"
    cat > "$creds_file" <<EOF
DB_DATABASE=${db}
DB_USERNAME=${user}
DB_PASSWORD=${pass}
EOF
    chmod 0600 "$creds_file"
    chown root:root "$creds_file"
  fi

  mysql_exec <<SQL
CREATE DATABASE IF NOT EXISTS \`${db}\`
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS '${user}'@'localhost';

ALTER USER '${user}'@'localhost'
  IDENTIFIED BY '${pass}';

GRANT ALL PRIVILEGES ON \`${db}\`.* TO '${user}'@'localhost';
FLUSH PRIVILEGES;
SQL

  sudo -u "$APP_USER" -H bash -lc "cd '$APP_DIR' && php artisan key:generate --force"

  sed -i \
    -e "s|^APP_NAME=.*|APP_NAME=\"${APP_NAME}\"|" \
    -e "s|^APP_URL=.*|APP_URL=https://${WP_PRIMARY_DOMAIN}:${APP_PORT}|" \
    -e "s/^APP_ENV=.*/APP_ENV=production/" \
    -e "s/^APP_DEBUG=.*/APP_DEBUG=false/" \
    -e "s/^DB_CONNECTION=.*/DB_CONNECTION=mysql/" \
    -e "s/^DB_HOST=.*/DB_HOST=127.0.0.1/" \
    -e "s/^DB_PORT=.*/DB_PORT=3306/" \
    -e "s/^DB_DATABASE=.*/DB_DATABASE=${db}/" \
    -e "s/^DB_USERNAME=.*/DB_USERNAME=${user}/" \
    -e "s/^DB_PASSWORD=.*/DB_PASSWORD=${pass}/" \
    "$APP_DIR/.env"

  chown "$APP_USER:$APP_GROUP" "$APP_DIR/.env"
  chmod 0640 "$APP_DIR/.env"
}

# -----------------------------
# Filament v4
# -----------------------------
install_filament() {
  log "Installing Filament v4..."

  sudo -u "$APP_USER" -H bash -lc "
    cd '$APP_DIR'
    composer require filament/filament:'^4.0' --no-interaction
    php artisan filament:install
  "
}

# -----------------------------
# Migrations
# -----------------------------
replace_migrations() {
  log "Replacing migrations with template migrations..."

  rm -rf "$APP_DIR/database/migrations"/*
  cp -a "${TEMPLATE_MIGRATIONS}/." "$APP_DIR/database/migrations/"
  chown -R "$APP_USER:$APP_GROUP" "$APP_DIR/database/migrations"
}

run_migrations() {
  log "Running migrations..."
  sudo -u "$APP_USER" -H bash -lc "cd '$APP_DIR' && php artisan migrate --force"
}

# -----------------------------
# Admin user
# -----------------------------
create_filament_admin_user() {
  log "Ensuring Filament admin user..."

  sudo -u "$APP_USER" -H env \
    ADMIN_EMAIL="$ADMIN_EMAIL" \
    ADMIN_NAME="$ADMIN_NAME" \
    FILAMENT_ADMIN_PASSWORD="$FILAMENT_ADMIN_PASSWORD" \
    bash -lc 'cd "'"$APP_DIR"'" && php <<'"'"'PHP'"'"'
<?php

require 'vendor/autoload.php';

$app = require 'bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();

$email = getenv('ADMIN_EMAIL');
$name  = getenv('ADMIN_NAME') ?: 'Admin';
$pass  = getenv('FILAMENT_ADMIN_PASSWORD');

if (!$email || !$pass) {
    fwrite(STDERR, "Missing admin credentials\n");
    exit(2);
}

$user = App\Models\User::firstOrNew(['email' => $email]);
$user->name = $name;
$user->password = Illuminate\Support\Facades\Hash::make($pass);

if (property_exists($user, 'email_verified_at')) {
    $user->email_verified_at = now();
}

$user->save();

PHP'
  
  log "Filament admin user ensured for ADMIN_EMAIL=${ADMIN_EMAIL}"
}


# -----------------------------
# Main
# -----------------------------
main() {
  require_root
  source_env

  install_composer
  create_laravel_app
  configure_app_env_and_db

  install_filament
  replace_migrations
  run_migrations
  create_filament_admin_user

  log "Filament installation complete"
  log "Admin URL: https://${WP_PRIMARY_DOMAIN}:${APP_PORT}/admin"
}

main "$@"
