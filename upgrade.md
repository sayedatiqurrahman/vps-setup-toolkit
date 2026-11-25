# VPS SENTINEL v1.3.0 — Container Network Doctor implementation record

Status: **implemented, tested and ready to release**.

This document records how the Sentinel Container Network Doctor & Auto-Repair requirement was delivered inside the existing VPS Setup Toolkit. No separate tool, service or web dashboard was introduced. The feature is part of the Bash toolkit, the `vps-setup` CLI and menu 14.

## Problem solved

A service can work from the VPS host but fail from a Docker container because DNS, MTU/MSS, bridge forwarding, NAT, conntrack, firewall policy, routing, proxy or TLS state differs between the two network namespaces. The doctor compares both paths with the same probes and reports the difference before any change is made.

The original production incident is retained only as a sanitized regression fixture:

```text
VPS: Debian 13, Docker 29.x, Docker Swarm active, UFW active
Custom nftables chain: inet cloud_dev forward
WAN: ens3, MTU 1380
Docker bridges: docker0 / docker_gwbridge, MTU 1500
Swarm overlay: 10.0.1.0/24; gateway bridge: 10.0.2.0/24
Container: eth0 MTU 1450, eth1 MTU 1500
Target: sms.example.test:443 (documentation IP 203.0.113.42)
Symptom: host HTTPS succeeds; container TCP succeeds but TLS stalls
```

No hostname, IP, interface, subnet, port or credential from that fixture is hardcoded in the diagnostic engine. Targets come from explicit CLI arguments or from the allowed-port configuration.

## What was implemented

### Integrated module

- `scripts/network.sh` — container discovery, host/container probes, MTU evidence, Swarm handling, managed MSS chain, repair plan/apply/verify/rollback/watch/reconcile.
- `menu.sh` — menu 14, `vps-setup network ...` dispatch and usage text.
- `scripts/firewall.sh` — dynamic target persistence after firewall selection, watcher/cron network reconciliation.
- `scripts/docker.sh`, `scripts/dokploy.sh`, `scripts/coolify.sh` — Swarm ensure + network doctor enable on every Docker-related install path.
- `scripts/watchdog.sh`, `systemd/vps-firewall-watch.service` — persistent reconciliation and required state paths.
- `scripts/uninstall.sh` — `all` mode removes managed MSS rules/state/change log; `keep-config` preserves them.

### Diagnosis

- Running containers, all network attachments, container IPs/gateways, interface MTUs, Docker networks, overlay/gateway bridges, proxies and firewall backend.
- Matched probes from the host and from the container: DNS, TCP, TLS with certificate validation, HTTP/HTTPS, and protocol-appropriate application probes.
- Root causes: `NONE`, `DNS`, `ROUTING_OR_FIREWALL`, `MTU_MSS`, `TLS_OR_PROXY`, `APPLICATION_AUTH`, `APPLICATION_PROTOCOL`, `DESTINATION_OR_HOST`.
- Container probes use runtimes already present in the container (`node`, `python`, `php`) and install nothing. An optional sidecar must be supplied by the operator as a digest-pinned image.
- Proxy credential values are redacted in all output.

### Dynamic target ports

- An explicitly configured `NETWORK_TARGET_PORT` always wins.
- One allowed outbound TCP port is selected automatically.
- Multiple allowed TCP ports prompt interactively.
- Non-interactive runs deterministically use the first allowed port.
- Custom TCP ports from the firewall manager are included.
- The selected port maps to a protocol profile (`443` → HTTPS, `993` → IMAPS, `587` → SMTP, and so on). STARTTLS/plain profiles are verified at TCP level rather than as false TLS failures.

### Docker Swarm

- `active`: accepted and never reinitialized.
- `inactive`: initialized with `VPS_SETUP_SWARM_ADVERTISE_ADDR` or the detected WAN IPv4.
- `pending`, `locked`, `error` or unknown: reported for manual handling; no leave or reinit.

### Safe repair

Automatic repair exists only for `MTU_MSS`, and only when interface MTU evidence shows a Docker-side path MTU greater than the WAN MTU. The plan is read-only until `--dry-run` is reviewed and the operator types `APPLY-NETWORK-REPAIR` (or confirms in the menu).

The applied change is limited to:

- iptables mangle chain `VPS-SENTINEL-MSS`;
- one scoped `bridge → WAN` TCP SYN clamp rule per discovered Docker bridge/subnet, commented `VPS-SENTINEL-MSS <bridge>-<wan>`;
- at most one commented `FORWARD` jump, `VPS-SENTINEL-JUMP`;
- desired state in `/etc/vps-setup/network-mss.rules`;
- timestamped mangle backup under `/var/backups/vps-setup/`;
- an auditable entry in `/etc/vps-setup/network-changes.log`.

Fresh connections are verified after apply. Verification failure automatically rolls the change back. The watcher reconciles desired state after reboots, Docker restarts and bridge changes.

The toolkit never disables UFW/nftables, flushes a full ruleset, sets policies to ACCEPT, changes physical MTUs, recreates Swarm networks, exposes databases or the Docker API, disables TLS verification, or uses `NODE_TLS_REJECT_UNAUTHORIZED=0`.

## CLI and menu

```bash
sudo vps-setup network status
sudo vps-setup network containers
sudo vps-setup network diagnose --container <id-or-name> --target host.example.test:443 --protocol https
sudo vps-setup network test --container <id-or-name> --target host.example.test:443
sudo vps-setup network repair --container <id-or-name> --target host.example.test:443 --dry-run
sudo vps-setup network repair --container <id-or-name> --target host.example.test:443 --apply
sudo vps-setup network verify --container <id-or-name> --target host.example.test:443 --fresh-connections 5
sudo vps-setup network rollback [change-id]
sudo vps-setup network watch 1
sudo vps-setup network mss-status
```

`sudo vps-setup` → menu **14) Container Network Doctor** exposes status, containers, diagnosis, test, dry-run, apply, verify, rollback and reconciliation with the same back end.

## Dashboard

**Not applicable.** This repository has no web dashboard component. The supported integration points are the interactive menu (`vps-setup` → 14), the `vps-setup network ...` CLI, persistent config, logs and the systemd/cron watcher. Nothing in this release pretends a dashboard exists.

## Configuration reference

| Key / variable | Purpose |
|---|---|
| `ENABLE_MSS_CLAMP` | Enables the managed MSS reconciler (set on Docker paths) |
| `NETWORK_TARGET_HOST` | Hostname used when `--target` is omitted |
| `NETWORK_TARGET_PORT` | Explicit allowed-port override |
| `NETWORK_PROTOCOL` | Probe profile used with the configured target |
| `VPS_SETUP_SWARM_ADVERTISE_ADDR` | Swarm advertise address override |
| `VPS_SETUP_NO_NETWORK_AUTO_REPAIR=1` | Disable auto-enable on Docker install paths |
| `VPS_SETUP_NETWORK_STATE` | Override `/etc/vps-setup/network-mss.rules` |
| `VPS_SETUP_NETWORK_CHANGES` | Override `/etc/vps-setup/network-changes.log` |
| `VPS_SETUP_DIAG_SIDECAR` | Optional operator-supplied, digest-pinned diagnostic image |

State and logs are owned by root and backed up before modification.

## Verification performed

```bash
bash tests/run-tests.sh
```

Results: installer 26, validation 40, OS detection 23, firewall 42, network doctor 49, uninstall 28 — **208 passed, 0 failed**. `bash -n` passed for all shell scripts. ShellCheck is not installed in the build environment, so the runner reported it as skipped rather than claiming success.

Network tests stub `docker`, `ip`, `iptables`, `getent`, `curl`, `openssl`, `timeout`, `systemctl` and `ufw`. They cover dynamic port selection, Swarm state handling, container discovery, root-cause classification, protocol-specific probes, proxy redaction, dry-run, apply, idempotent reconcile, verification, rollback and safety invariants. No test modifies a real firewall, container or package set.

## Install / update procedure

Release `v1.3.0` is pinned by immutable tag with its SHA-256 published in `checksums/v1.3.0.sha256`. The installer verifies that checksum automatically.

Fresh install:

```bash
curl -fsSL https://raw.githubusercontent.com/sayedatiqurrahman/vps-setup-toolkit/v1.3.0/install.sh -o install.sh && sudo bash install.sh
```

Upgrade an existing toolkit while preserving configuration and state:

```bash
curl -fsSL https://raw.githubusercontent.com/sayedatiqurrahman/vps-setup-toolkit/v1.3.0/install.sh -o install.sh && sudo bash install.sh --install-only
sudo vps-setup status
sudo vps-setup network status
```

For Docker nodes, re-run menu 3, 4 or 5 (or `vps-setup run 3 --yes`) if you need to apply Swarm/network-doctor enablement to an existing installation. Use `sudo vps-setup network rollback` to undo a managed MSS repair at any time.
