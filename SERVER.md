# Immutable WordPress Multisite Origin (Cloudflare-only)

## Purpose
This server is a hardened WordPress multisite origin intended to run **behind Cloudflare only**.
It is designed to be **rebuilt, not repaired**.

## Key Properties
- No SSH
- Cloudflare-only ingress (TCP 443)
- nftables default-drop firewall
- Single nginx catch-all
- WordPress multisite
- Redis via UNIX socket
- PHP-FPM via UNIX socket (/run/php/server-fpm.sock)
- Secrets in /etc/server.env only
- Email-only alerting

## Adding a New Site
1. Add DNS in Cloudflare (proxied)
2. Create site in WP Network Admin or via WP-CLI
3. Done — no nginx changes

## Certificate Management
- Cloudflare Origin CA cert
- Located at:
  - /etc/ssl/cf-origin.pem
  - /etc/ssl/cf-origin.key
- Rotation is manual and documented

## Alerts
Email alerts are sent for:
- Disk usage (WARN/CRIT)
- Reboot required
- Cloudflare IP update failure

## What NOT To Do
- Do not install SSH
- Do not open firewall ports
- Do not edit nginx/PHP manually
- Do not store secrets outside /etc/server.env
- Do not rely on WordPress auto-updates

## Rebuild Policy
If something is wrong:
1. Rebuild the server
2. Restore content & DB
3. Swap Cloudflare origin IP
