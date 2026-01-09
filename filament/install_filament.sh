#!/usr/bin/env bash
set -euo pipefail
umask 027

# -----------------------------
# Config (edit if you want)
# -----------------------------
ENV_FILE="/etc/server.env"

APP_USER="serveradmin"
APP_GROUP="www-data"

APP_NAME="Server Admin"
APP_PORT="8443"
APP_DIR="/var/www/server-admin"

TEMPLATE_MIGRATIONS="/opt/server-template/filament/migrations"

# Set SKIP_PACKAGES=1 if you don't want this script to install anything.
SKIP_PACKAGES="${SKIP_PACKAGES:-0}"

# -----------------------------
# Helpers
# -----------------------------
log() { printf "\n[%s] %s\n" "$(date -Is)" "$*"; }
die() { printf "\nERROR: %s\n" "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root (e.g. sudo $0)"
}

detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt"
  elif command -v dnf >/dev/null 2>&1; then
    echo "dnf"
  elif command -v yum >/dev/null 2>&1; then
    echo "yum"
  else
    echo ""
  fi
}

install_packages() {
  [[ "$SKIP_PACKAGES" == "1" ]] && { log "SKIP_PACKAGES=1 set; skipping package installs."; return 0; }

  local mgr; mgr="$(detect_pkg_mgr)"
  [[ -n "$mgr" ]] || { log "No supported package manager detected; skipping package installs."; return 0; }

  if [[ "$mgr" == "apt" ]]; then
    log "Installing required packages (apt)..."
    apt-get update -y
    apt-get install -y --no-install-recommends \
      ca-certificates curl unzip git openssl \
      php-cli php-mbstring php-xml php-curl php-zip php-mysql php-gd php-intl \
      mariadb-client
  else
    log "Installing required packages ($mgr)..."
    "$mgr" install -y \
      ca-certificates curl unzip git openssl \
      php-cli php-mbstring php-xml php-curl php-zip php-mysqlnd php-gd php-intl \
      mariadb
  fi
}

# Render KEY=VALUE line with safe quoting for a shell EnvironmentFile
render_env_line() {
  local key="$1" value="$2"
  # If value is "simple", write unquoted; else write double-quoted with escaping.
  if [[ "$value" =~ ^[A-Za-z0-9_./:+@%-=]+$ ]]; then
    printf '%s=%s' "$key" "$value"
  else
    local esc="$value"
    esc="${esc//\\/\\\\}"
    esc="${esc//\"/\\\"}"
    esc="${esc//\$/\\\$}"
    esc="${esc//\`/\\\`}"
    printf '%s="%s"' "$key" "$esc"
  fi
}

# Update or append KEY=... in ENV_FILE (replaces all existing KEY= lines with a single one)
set_env_kv() {
  local key="$1" value="$2"
  local line tmp
  line="$(render_env_line "$key" "$value")"
  tmp="$(mktemp)"

  awk -v k="$key" -v nl="$line" '
    BEGIN { found=0 }
    {
      if ($0 ~ "^" k "=") {
        if (!found) { print nl; found=1 }
        next
      }
      print
    }
    END { if (!found) print nl }
  ' "$ENV_FILE" > "$tmp"

  cat "$tmp" > "$ENV_FILE"
  rm -f "$tmp"
}

source_env() {
  [[ -f "$ENV_FILE" ]] || die "Env file not found: $ENV_FILE"

  # shellcheck disable=SC1090
  set -a
  source "$ENV_FILE"
  set +a

  [[ -n "${WP_PRIMARY_DOMAIN:-}" ]] || die "WP_PRIMARY_DOMAIN is not set in $ENV_FILE"
  [[ -n "${STATE_DIR:-}" ]] || die "STATE_DIR is not set in $ENV_FILE"

  [[ -n "${ADMIN_EMAIL:-}" ]] || die "ADMIN_EMAIL is not set in $ENV_FILE"
  [[ -n "${ADMIN_NAME:-}"  ]] || die "ADMIN_NAME is not set in $ENV_FILE"
  [[ -n "${FILAMENT_ADMIN_PASSWORD:-}" ]] || die "FILAMENT_ADMIN_PASSWORD is not set in $ENV_FILE"
}

ensure_app_user_creds_in_env() {
  need_cmd openssl

  # If APP_USER is already set in the env file, ensure it matches our configured APP_USER
  if [[ -n "${APP_USER:-}" && "${APP_USER}" != "${APP_USER}" ]]; then
    die "APP_USER in $ENV_FILE does not match script APP_USER (this check should never trigger)."
  fi

  # If APP_USER_PASSWORD already exists, keep it; otherwise generate one.
  local pw="${APP_USER_PASSWORD:-}"
  if [[ -z "$pw" ]]; then
    # Hex is safest for shell env files (no whitespace / quotes)
    pw="$(openssl rand -hex 18)"
  fi

  # Persist into /etc/server.env
  set_env_kv "APP_USER" "$APP_USER"
  set_env_kv "APP_USER_PASSWORD" "$pw"

  # Export into current shell for later steps
  export APP_USER_PASSWORD="$pw"
}

create_app_user() {
  log "Ensuring non-root OS user '${APP_USER}' exists and has a password..."

  if id -u "$APP_USER" >/dev/null 2>&1; then
    log "User '$APP_USER' already exists"
  else
    useradd --create-home --shell /bin/bash --groups "$APP_GROUP" "$APP_USER"
  fi

  # Set/rotate the password to match APP_USER_PASSWORD (idempotent)
  echo "${APP_USER}:${APP_USER_PASSWORD}" | chpasswd

  # Reasonable permissions
  usermod -aG "$APP_GROUP" "$APP_USER" || true
  chmod 0750 "/home/${APP_USER}" 2>/dev/null || true
}

install_composer() {
  if command -v composer >/dev/null 2>&1; then
    log "Composer already installed: $(composer --version | head -n1)"
    return 0
  fi

  log "Installing Composer to /usr/local/bin/composer..."
  need_cmd php
  need_cmd curl

  local expected actual
  expected="$(curl -fsSL https://composer.github.io/installer.sig)"
  curl -fsSL -o /tmp/composer-setup.php https://getcomposer.org/installer
  actual="$(php -r "echo hash_file('sha384', '/tmp/composer-setup.php');")"
  [[ "$expected" == "$actual" ]] || die "Composer installer signature mismatch"

  php /tmp/composer-setup.php --quiet --install-dir=/usr/local/bin --filename=composer
  rm -f /tmp/composer-setup.php
  log "Composer installed: $(composer --version | head -n1)"
}

create_laravel_app() {
  if [[ -d "$APP_DIR" && -f "$APP_DIR/artisan" ]]; then
    log "Laravel app already exists at $APP_DIR"
    return 0
  fi

  log "Creating Laravel 12 app at $APP_DIR..."
  install -d -m 0750 -o "$APP_USER" -g "$APP_GROUP" "$(dirname "$APP_DIR")"

  sudo -u "$APP_USER" -H \
    composer create-project "laravel/laravel:^12.0" "$APP_DIR" --no-interaction

  chown -R "$APP_USER:$APP_GROUP" "$APP_DIR"
  find "$APP_DIR" -type d -exec chmod 0750 {} \;
  find "$APP_DIR" -type f -exec chmod 0640 {} \;
  chmod -R g+w "$APP_DIR/storage" "$APP_DIR/bootstrap/cache"
}

mysql_exec() {
  # Prefer socket auth as root if available
  if mysql --protocol=socket -e "SELECT 1" >/dev/null 2>&1; then
    mysql --protocol=socket "$@"
  else
    mysql "$@"
  fi
}

configure_app_env_and_db() {
  log "Configuring database and Laravel environment..."

  need_cmd mysql
  need_cmd openssl

  local db="server_admin"
  local user="serveradmin"
  local creds_file="${STATE_DIR}/server-admin-db.creds"
  local pass

  # Ensure state dir exists
  install -d -m 0700 -o root -g root "$STATE_DIR"

  # Generate OR reuse DB password
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

  # Ensure database and user exist and password is correct
  mysql_exec <<SQL
CREATE DATABASE IF NOT EXISTS \`${db}\`
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS '${user}'@'localhost';

ALTER USER '${user}'@'localhost'
  IDENTIFIED BY '${pass}';

GRANT ALL PRIVILEGES ON \`${db}\`.* TO '${user}'@'localhost';
FLUSH PRIVILEGES;
SQL

  # Ensure Laravel app key exists
  sudo -u "$APP_USER" -H bash -lc "cd '$APP_DIR' && php artisan key:generate --force"

  # Update Laravel .env deterministically
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

  log "Database configured and credentials synchronized"
}


artisan_has() {
  local cmd="$1"
  sudo -u "$APP_USER" -H bash -lc "cd '$APP_DIR' && php artisan list" | grep -qE "^ +${cmd}\b"
}

install_filament_and_panel_delete_generated_migrations() {
  log "Installing Filament v4..."
  sudo -u "$APP_USER" -H bash -lc "
    set -euo pipefail
    cd '$APP_DIR'
    composer require filament/filament:'^4.0' --no-interaction
  "

  # Snapshot migrations BEFORE running any Filament installer/scaffold
  local before after
  before="$(mktemp)"
  after="$(mktemp)"
  sudo -u "$APP_USER" -H bash -lc "cd '$APP_DIR' && ls -1 database/migrations | sort" > "$before" || true

  # Create the panel with default name "admin" (best-effort, based on available commands)
  if artisan_has "make:filament-panel"; then
    log "Creating Filament panel: admin (make:filament-panel)"
    sudo -u "$APP_USER" -H bash -lc "cd '$APP_DIR' && php artisan make:filament-panel admin --no-interaction || php artisan make:filament-panel admin"
  elif artisan_has "filament:install"; then
    # Many Filament installs create an 'admin' panel provider by default.
    log "Running Filament installer (filament:install)"
    sudo -u "$APP_USER" -H bash -lc "cd '$APP_DIR' && php artisan filament:install --no-interaction || php artisan filament:install"
  elif artisan_has "filament:install-panels"; then
    log "Running Filament panels installer (filament:install-panels)"
    sudo -u "$APP_USER" -H bash -lc "cd '$APP_DIR' && php artisan filament:install-panels --no-interaction || php artisan filament:install-panels"
  else
    log "No known Filament panel/installer command found; continuing (package installed)."
  fi

  sudo -u "$APP_USER" -H bash -lc "cd '$APP_DIR' && ls -1 database/migrations | sort" > "$after" || true

  # Delete migrations created by Filament installer/scaffold
  if [[ -s "$before" && -s "$after" ]]; then
    mapfile -t new_migs < <(comm -13 "$before" "$after" || true)
    if (( ${#new_migs[@]} > 0 )); then
      log "Deleting Filament-generated migrations (${#new_migs[@]} files)..."
      for f in "${new_migs[@]}"; do
        rm -f "$APP_DIR/database/migrations/$f"
      done
    else
      log "No new migrations detected from Filament installer/scaffold."
    fi
  else
    log "Could not diff migrations; skipping deletion step."
  fi

  rm -f "$before" "$after"

  # Usually helpful for Laravel apps (ignore if it fails)
  sudo -u "$APP_USER" -H bash -lc "cd '$APP_DIR' && php artisan storage:link >/dev/null 2>&1 || true"
}

copy_template_migrations() {
  [[ -d "$TEMPLATE_MIGRATIONS" ]] || die "Template migrations folder not found: $TEMPLATE_MIGRATIONS"
  [[ -d "$APP_DIR/database/migrations" ]] || die "Laravel migrations folder not found: $APP_DIR/database/migrations"

  log "Copying template migrations from $TEMPLATE_MIGRATIONS to Laravel migrations folder..."
  cp -a "${TEMPLATE_MIGRATIONS}/." "$APP_DIR/database/migrations/"
  chown -R "$APP_USER:$APP_GROUP" "$APP_DIR/database/migrations"
}

run_migrations() {
  log "Running migrations..."
  sudo -u "$APP_USER" -H bash -lc "cd '$APP_DIR' && php artisan migrate --force"
}

create_filament_admin_user() {
  log "Creating/updating Filament admin user (after migrations)..."

  sudo -u "$APP_USER" -H bash -lc "
    set -euo pipefail
    cd '$APP_DIR'
    php -r '
require "vendor/autoload.php";
$app = require "bootstrap/app.php";
$kernel = $app->make(Illuminate\Contracts\Console\Kernel::class);
$kernel->bootstrap();

$email = getenv("ADMIN_EMAIL") ?: "";
$name  = getenv("ADMIN_NAME") ?: "Admin";
$pass  = getenv("FILAMENT_ADMIN_PASSWORD") ?: "";

if (!$email) { fwrite(STDERR, "ADMIN_EMAIL is missing.\n"); exit(2); }
if (!$pass)  { fwrite(STDERR, "FILAMENT_ADMIN_PASSWORD is missing.\n"); exit(2); }

$userClass = "App\Models\User";
if (!class_exists($userClass)) { fwrite(STDERR, "App\Models\User not found.\n"); exit(3); }

$user = $userClass::firstOrNew(["email" => $email]);
$user->name = $name ?: ($user->name ?: "Admin");
$user->password = Illuminate\Support\Facades\Hash::make($pass);

if (property_exists($user, "email_verified_at") && !$user->email_verified_at) {
    $user->email_verified_at = now();
}

$user->save();
'
  "

  log "Filament admin user ensured for ADMIN_EMAIL=${ADMIN_EMAIL}"
}

main() {
  require_root
  install_packages

  source_env
  ensure_app_user_creds_in_env
  create_app_user

  install_composer
  create_laravel_app
  configure_app_env_and_db

  install_filament_and_panel_delete_generated_migrations
  copy_template_migrations
  run_migrations
  create_filament_admin_user

  log "Done."
  log "App URL (for your nginx): https://${WP_PRIMARY_DOMAIN}:${APP_PORT} -> ${APP_DIR}/public"
  log "Note: APP_USER and APP_USER_PASSWORD were written to ${ENV_FILE} (treat that file as secret)."
}

main "$@"
