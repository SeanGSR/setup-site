# Web Setup Script

A bash script to manage Nginx web sites on Debian/Ubuntu and Arch Linux. Handles static sites, WordPress, PHP applications, and reverse proxies with SFTP access, SSL, backups, and more.

## Features

- **Multi-distro** — Debian/Ubuntu and Arch Linux (Manjaro, EndeavourOS, etc.)
- **Site types** — Static, WordPress, PHP, Reverse Proxy
- **WordPress** — Automated install with database, PHP-FPM pool, wp-config, ImageMagick/AVIF support
- **SFTP access** — Chroot-jailed users per site via SSH
- **SSL** — Let's Encrypt via Certbot with auto-renewal (systemd timer)
- **Local domains** — `.local` / `.test` / `.localhost` support via `/etc/hosts` with automatic nsswitch.conf fix
- **Backup system** — Full site + database backups with retention policy, restore, and remote sync (Backblaze B2, S3, rsync)
- **Site management** — Rename domains, update WordPress core/plugins/themes, manage PHP extensions, regenerate nginx configs

## Requirements

- Linux (Debian/Ubuntu or Arch-based)
- Root access (`sudo`)
- Nginx, PHP, MariaDB (auto-installed by the script)

## Installation

```bash
# Download
curl -O https://raw.githubusercontent.com/SeanGSR/setup-site/main/setup-site.sh
chmod +x setup-site.sh

# Run
sudo bash setup-site.sh
```

## Usage

```
sudo bash setup-site.sh
```

### Main Menu

```
1 | Create a new site
2 | Edit a site
3 | List all sites
4 | Renew SSL certificates
5 | Setup SSL auto-renewal
6 | Backup Manager
7 | Delete a site
8 | Exit
```

### Create a Site

1. Choose site type (Static, WordPress, PHP, Reverse Proxy)
2. Choose public or local domain
3. Enter domain name
4. Script installs dependencies, creates directories, configures nginx, sets up PHP-FPM pool, and optionally creates an SFTP user

### Edit a Site

Options vary based on site type:

- Rename domain
- Manage SFTP users
- Update WordPress (core, plugins, themes via WP-CLI)
- Update PHP extensions (imagick, redis, apcu, opcache)
- Toggle SSL
- Regenerate nginx config
- Quick backup

### Backup Manager

```
1 | Backup a site         — full backup (files + database)
2 | Backup all sites      — backup every site at once
3 | Restore a site        — restore from a previous backup
4 | List backups          — show all available backups
5 | Setup auto-backup     — daily/weekly scheduled backups
6 | Setup remote sync     — S3, rsync, rclone
7 | Back
```

**Backups include:**
- All site files (public/, logs/, config)
- Database dump via `mysqldump --single-transaction`
- Automatic retention (default: keep last 7)
- Optional remote sync to Backblaze B2, S3, or any rclone/rsync target

**Scheduled backups** use systemd timers (daily, every 12h, or weekly).

## Directory Structure

```
/home/user/sites/
├── example.com/
│   ├── public/          # Web root (WordPress, PHP, or static files)
│   ├── logs/            # Nginx access & error logs
│   ├── backups/         # Nginx config backups
│   ├── users/           # SFTP user credential files
│   └── db-credentials.txt
│
/home/user/backups/
├── example.com/
│   ├── backup-example.com-20260302-030000.tar.gz
│   └── ...
```

## Distro Support

| Feature | Debian/Ubuntu | Arch Linux |
|---------|:---:|:---:|
| Package manager | apt | pacman |
| Web user | www-data | http |
| PHP paths | versioned (`/etc/php/8.3/`) | unversioned (`/etc/php/`) |
| PHP-FPM service | `php8.3-fpm` | `php-fpm` |
| nginx sites-enabled | built-in | auto-created by script |
| sshd service | `ssh` | `sshd` |

## Restoring on a New Server

1. Set up the new server and create the site via the script
2. Install rclone, configure your remote, pull backups:
   ```bash
   sudo rclone copy myremote:bucket/sites /home/user/backups --progress
   ```
3. Use the script: **Backup Manager > Restore a site**

Or restore manually:
```bash
cd /home/user/sites
tar -xzf /home/user/backups/example.com/backup-example.com-20260302.tar.gz
mysql example_com < /home/user/sites/example.com/backups/db-20260302.sql
chown -R www-data:www-data /home/user/sites/example.com/public
systemctl restart php8.3-fpm nginx
```

## License

MIT
