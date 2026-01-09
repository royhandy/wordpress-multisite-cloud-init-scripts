<?php
/**
 * WordPress configuration
 * All secrets are sourced from /etc/server.env via PHP-FPM EnvironmentFile
 */

function env_required(string $key): string {
    $value = getenv($key);
    if ($value === false || $value === '') {
        http_response_code(500);
        header('Content-Type: text/plain; charset=utf-8');
        echo "Missing required environment variable: {$key}\n";
        exit(1);
    }
    return $value;
}

if (PHP_SAPI === 'cli' && file_exists('/etc/server.env')) {
    foreach (file('/etc/server.env', FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
        if ($line[0] === '#' || !str_contains($line, '=')) continue;
        putenv($line);
    }
}

/** Database */
define('DB_NAME',     env_required('DB_NAME'));
define('DB_USER',     env_required('DB_USER'));
define('DB_PASSWORD', env_required('DB_PASSWORD'));
define('DB_HOST', env_required('DB_HOST'));
define('DB_CHARSET',  'utf8mb4');
define('DB_COLLATE',  '');

/** Authentication salts */
define('AUTH_KEY',         env_required('WP_AUTH_KEY'));
define('SECURE_AUTH_KEY',  env_required('WP_SECURE_AUTH_KEY'));
define('LOGGED_IN_KEY',    env_required('WP_LOGGED_IN_KEY'));
define('NONCE_KEY',        env_required('WP_NONCE_KEY'));
define('AUTH_SALT',        env_required('WP_AUTH_SALT'));
define('SECURE_AUTH_SALT', env_required('WP_SECURE_AUTH_SALT'));
define('LOGGED_IN_SALT',   env_required('WP_LOGGED_IN_SALT'));
define('NONCE_SALT',       env_required('WP_NONCE_SALT'));

$table_prefix = 'wp_';

/** Core behavior */
define('WP_DEBUG', false);
define('FORCE_SSL_ADMIN', true);
define('DISALLOW_FILE_EDIT', true);
define('DISALLOW_FILE_MODS', true);
define('AUTOMATIC_UPDATER_DISABLED', true);
define('DISABLE_WP_CRON', true);

/** Multisite */
define('MULTISITE', true);
define('SUBDOMAIN_INSTALL', (getenv('WP_SUBDOMAIN_INSTALL') ?: '1') === '1');
define('DOMAIN_CURRENT_SITE', env_required('WP_PRIMARY_DOMAIN'));
define('PATH_CURRENT_SITE', '/');
define('SITE_ID_CURRENT_SITE', 1);
define('BLOG_ID_CURRENT_SITE', 1);
define('COOKIE_DOMAIN', '');

/** URLs */
define('WP_HOME',    'https://' . env_required('WP_PRIMARY_DOMAIN'));
define('WP_SITEURL', 'https://' . env_required('WP_PRIMARY_DOMAIN'));

/** Redis object cache */
define('WP_CACHE', true);
define('WP_REDIS_SCHEME', 'unix');
define('WP_REDIS_PATH', '/run/redis/redis.sock');
define('WP_REDIS_PASSWORD', env_required('REDIS_PASSWORD'));
define('WP_REDIS_DATABASE', 0);

if (!defined('ABSPATH')) {
    define('ABSPATH', __DIR__ . '/');
}

require_once ABSPATH . 'wp-settings.php';
