# Immutable WordPress Multisite Origin (Cloudflare-Only)

> ⚠️ **BETA WARNING**
>
> This project is currently in **beta**.
> It has **not been fully battle-tested in production**.
> Use at your own risk.
>
> You are expected to understand Linux system administration, Cloudflare, and WordPress multisite before deploying this.
> The authors assume **no responsibility** for data loss, downtime, or misconfiguration.

---

## Overview

This repository provides a **fully automated, immutable server template** for running a **WordPress multisite origin** behind **Cloudflare only**.

It is designed for:
- Small VPS instances (≈1 GB RAM)
- Very low ongoing maintenance
- Strong security through simplicity
- Rebuild-instead-of-repair operations

The server is intended to act **only as an origin**:
- All public traffic must come through Cloudflare
- The origin itself is locked down
- No SSH access is provided

---

## Key Characteristics

- No SSH (console-only access)
- Cloudflare-only ingress (TCP 443)
- nftables default-deny firewall
- Single nginx catch-all vhost
- WordPress multisite
- Redis object cache (UNIX socket only)
- Secrets stored in one file: `/etc/server.env`
- Email alerts (disk, reboot, Cloudflare IP update failures)
- Idempotent provisioning
- Designed to be rebuilt, not repaired

---

## What This Is Not

This project intentionally does **not** include:

- SSH access
- Per-site nginx configuration
- Automatic TLS / ACME / Let’s Encrypt
- Fail2ban
- Containers or Docker
- WordPress auto-updates
- Heavy monitoring stacks

---

## Architecture Summary

Internet → Cloudflare → nftables → nginx → PHP-FPM → WordPress Multisite → MariaDB + Redis

---

## Repository Layout

```
server-template/
├── cloud-init.yaml
├── install.sh
├── env.example
├── nginx/
├── php/
├── wordpress/
├── redis/
├── security/
├── alerts/
└── SERVER.md
```

---

## Prerequisites

Before deploying, you **must** have:

### Cloudflare
- Domains managed by Cloudflare
- Traffic proxied (orange cloud)

### Cloudflare Origin Certificate
Install **before provisioning**:

```
/etc/ssl/cf-origin.pem
/etc/ssl/cf-origin.key
```

### VPS With Console Access
- Ubuntu LTS
- Web console access required

### SMTP Provider
- Mailgun or compatible SMTP
- Used only for server alerts

---

## Deployment Instructions

### 1. Create the Server
Provision a fresh Ubuntu LTS VPS.

### 2. Install Origin Certificate
Ensure the certificate files exist before provisioning.

### 3. cloud-init Configuration

Replace the GitHub URL with your fork.

```
#cloud-config
# Minimal cloud-init bootstrap
# ASCII only - required for provider consoles that base64 encode user-data

package_update: true
package_upgrade: false

packages:
  - git
  - ca-certificates
  - curl
  - openssl

runcmd:
  - set -e

  # Clone repository
  - |
    if [ ! -d /opt/server-template ]; then
      git clone https://github.com/royhandy/wordpress-multisite-cloud-init-scripts.git /opt/server-template
    fi

  # Ensure scripts are executable
  - chmod 700 /opt/server-template/bootstrap.sh
  - chmod 700 /opt/server-template/install.sh

  # Run bootstrap phase only
  - /opt/server-template/bootstrap.sh

final_message: |
  ====================================================
  Bootstrap complete.

  cloud-init is finished and disabled.

  Manual next steps:
    1. Upload Cloudflare origin certs to:
       /etc/ssl/cf-origin/<domain>/cert.pem
       /etc/ssl/cf-origin/<domain>/key.pem
    2. Edit /etc/server.env
    3. Run:
       cd /opt/server-template && ./install.sh
  ====================================================

```

### 4. First Boot
Provisioning runs automatically on first boot via systemd.

### 5. Configure Secrets

Edit:
```
/etc/server.env
```

Set required values:
```
WP_PRIMARY_DOMAIN=example.com
MAILGUN_SMTP_LOGIN=postmaster@example.com
MAILGUN_SMTP_PASSWORD=yourpassword
MAIL_FROM=server@example.com
ALERT_EMAIL=alerts@example.com
```

---

## WordPress Usage

### Admin Login
```
https://your-domain/wp-admin/
```

### Create a Site
```
wp site create --slug=site1 --title="Site 1" --email=admin@example.com --allow-root
```

### Custom Domains
- Add domain to Cloudflare (proxied)
- Map in WordPress Network Admin
- No nginx changes required

---

## Updates & Maintenance

This system is **immutable by design**.

Correct approach:
1. Rebuild server
2. Restore DB + uploads
3. Update Cloudflare origin IP

---

## Alerts

Email alerts are sent for:
- Disk usage
- Reboot required
- Cloudflare IP update failures

---

## Security Model

Security relies on:
- Cloudflare WAF + CDN
- Strict firewalling
- Minimal attack surface
- No long-lived access channels

---

## Beta Disclaimer

This project is **beta software** and provided as-is.
You are responsible for testing, backups, and auditing.

---

## License

MIT License. See LICENSE file.
