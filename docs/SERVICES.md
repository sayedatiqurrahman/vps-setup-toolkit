# Supported services and modules

Every module checks prerequisites, avoids replacing existing installations, and is safe to re-run.

All modules use the OS detection performed in `scripts/common.sh`: they choose packages and service commands for the detected family (`debian`, `rhel`, `suse`, `arch`, `alpine`) and init system (`systemd`, `openrc`, `sysv`). Unsupported Linux OSes warn and continue with best-effort package-manager support; vendor-specific steps need `ALLOW_UNSUPPORTED_OS=1`.

When any install category (menu 1-8) runs from the main menu, the toolkit asks for firewall basics **first** and for outbound service access **afterwards** (one-by-one, standard preset, all 20 categories, or skip). See [`FIREWALL.md`](FIREWALL.md#guided-firewall-workflow).

## Base VPS Setup (menu 1)

Installs a family-appropriate set of core tools. On apt systems: `ca-certificates`, `curl`, `wget`, `gnupg`, `lsb-release`, `jq`, `git`, `ufw`, `nftables`, `iproute2`, `procps`, `systemd`. RPM systems use `gnupg2`, `firewalld`, `iproute` and `procps-ng`; other families get their native equivalents. Applies the documented UFW baseline where UFW exists: default deny inbound, default allow outbound, TCP 22/80/443 plus any alternate SSH port detected via `sshd -T`. If UFW is unavailable, base setup warns and leaves host-firewall configuration to you rather than disabling another firewall.

## Node.js, npm, pnpm and PM2 (menu 2)

- Node.js from NodeSource: 18.x, 20.x or 22.x (default 22, matching the guide). The NodeSource setup script is attempted on Debian/RPM families; elsewhere set `ALLOW_UNSUPPORTED_OS=1` to try it or install Node from your distribution packages.
- npm is installed with Node.js; pnpm can be installed globally on request.
- PM2 is installed globally. The module prints the `pm2 startup` suggestion rather than modifying boot services automatically.
- Existing Node/npm versions are left alone.

## Docker Engine (menu 3)

Adds Docker's signed apt repository for Debian/Ubuntu-family systems using the detected codename and architecture, installs `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`, and enables the daemon. On other families, distribution Docker packages are used only when `ALLOW_UNSUPPORTED_OS=1` is set. The firewall watcher is installed in all cases (systemd unit or cron fallback), and automatic `docker_gwbridge` Traefik ingress rules are enabled. Docker's unauthenticated TCP API is never enabled.

## Dokploy (menu 4) and Coolify (menu 5)

Both launchers:

- require Docker (offering to install it first),
- print a warning and the upstream installer URL,
- require typed confirmation,
- download the official installer to a temporary file (never pipe directly into a shell),
- show its SHA-256 before asking permission to execute.

Dokploy additionally enables managed HTTP/HTTPS forwarding to Traefik at `TRAEFIK_IP` on `TRAEFIK_BRIDGE` automatically when launched from the main menu; the rules (`DOKPLOY-INGRESS` / `DOKPLOY-RETURN`) are re-applied by the watcher after every reboot. Selecting both panels in one menu operation requires an explicit `BOTH-PANELS-INTENTIONAL` confirmation; they are never installed together automatically.

## PHP, Nginx and WordPress prerequisites (menus 6 and 7)

- Nginx from distribution packages; existing site configs are not modified. `nginx -t` is checked.
- PHP-FPM and CLI plus `mysql`, `curl`, `gd`, `mbstring`, `xml`, `zip`, `intl`, `bcmath` extensions (Debian naming). On other families the equivalent distribution package names are attempted, and unavailable ones are reported rather than silently skipped. On apt systems with multiple PHP versions you can choose X.Y; otherwise the distribution default is used.
- WordPress prerequisites verify the same extensions and print manual next steps. WordPress itself is not downloaded or configured.

## SSH security (menu 8)

- Read-only checklist and audit based on the original guide.
- Optional hardening of `PermitRootLogin` and `PasswordAuthentication` only: changes are made on a copy, validated with `sshd -t -f`, backed up, and reloaded. No automatic SSH port change. Password authentication cannot be disabled unless an `authorized_keys` file exists.
- Fail2ban installation with a managed `jail.d/vps-setup.conf` SSH jail: the `systemd` backend is used on systemd hosts and fail2ban's portable `auto` backend with `%(sshd_log)s` elsewhere.

## Firewall service manager (menu 9)

Catalog IDs 1-20 (from the guide):

| ID | Category | Ports |
|---|---|---|
| 1 | Web/API | TCP 80,443 |
| 2 | DNS | TCP/UDP 53 |
| 3 | NTP | UDP 123 |
| 4 | SSH/Git | TCP 22 |
| 5 | SMTP | TCP 25,465,587 |
| 6 | IMAP | TCP 143,993 |
| 7 | POP3 | TCP 110,995 |
| 8 | MySQL/MariaDB | TCP 3306 |
| 9 | PostgreSQL | TCP 5432 |
| 10 | Microsoft SQL Server | TCP 1433 |
| 11 | Oracle | TCP 1521 |
| 12 | Redis | TCP 6379 |
| 13 | MongoDB | TCP 27017 |
| 14 | S3/MinIO common | TCP 9000 |
| 15 | Elasticsearch | TCP 9200,9300 |
| 16 | RabbitMQ | TCP 5671,5672 |
| 17 | MQTT | TCP 1883,8883 |
| 18 | Nixtec external MariaDB | TCP 23306 |
| 19 | Nixtec Garage/S3 | TCP 24900 |
| 20 | SMS/REST API | TCP 443 |

IDs 21/22 accept custom TCP/UDP ports. All input is validated (1-65535), de-duplicated and persisted. Commands inside the selector:

- numbers: toggle categories on/off
- `r`: remove categories or custom port groups
- `l`: list currently configured rules
- `a`: reapply the current saved configuration
- `0`: back

## Custom port configuration (menu 10)

Adds/removes host inbound UFW rules. A trusted IPv4/CIDR is preferred; public access needs confirmation, and sensitive ports need typed authorization. The toolkit never opens Docker API or database ports publicly by default.

## Repair, status and uninstall (menus 11-13)

- **Repair**: recreates missing config, reapplies UFW/nftables, reinstalls the watcher, and can restore a validated nftables ruleset from a file.
- **Status**: OS, installed components, service states, UFW, Docker bridges, managed chain and watcher.
- **Uninstall**: typed `UNINSTALL` confirmation; optional, separate cleanup of managed nftables chain/jump, managed UFW egress rules, and config/state/logs.
