# Critical VPS Toolkit Issue: Docker Outbound TCP Established Traffic Is Being Blocked

You are working on my existing Debian 13 VPS Setup Toolkit.

I discovered a serious Docker networking/firewall issue while troubleshooting SMTP and IMAP connectivity from a Next.js application running inside Docker.

Your task is to investigate the existing implementation, identify the exact root cause, and permanently fix it inside the existing toolkit.

**IMPORTANT: Do not create another firewall manager, another standalone toolkit, or an independent service. Integrate everything into the existing VPS Setup Toolkit.**

---

## 1. VPS Environment

- OS: Debian GNU/Linux 13 (Trixie)
- Docker Engine: 29.9.3
- Docker Swarm: Active
- Deployment platform: Dokploy
- Reverse proxy: Traefik
- Firewall: UFW + native nftables + Docker-managed iptables
- Public interface: `ens3`
- VPS internal IP: `10.253.31.111`
- Default gateway: `10.253.31.1`

### Docker networks

| Network | Subnet | Host interface |
|---|---|---|
| docker0 | 10.0.0.0/24 | docker0 |
| docker_gwbridge | 10.0.2.0/24 | docker_gwbridge |
| dokploy-network | 10.0.1.0/24 | Overlay |
| ingress | Docker Swarm ingress | Overlay |

Example Next.js container:

- Container IP: `10.0.2.6`
- Gateway: `10.0.2.1`
- Interface: `eth1`
- Application: Next.js

---

## 2. Actual Problem

My Next.js application cannot connect to external mail services.

Mail server:

` smtpy.nixtecsys.com `

IPv4:

`46.105.104.51`

Required services:

| Service | Port | Protocol |
|---|---:|---|
| IMAPS | 993 | TCP |
| SMTP Submission | 587 | TCP |

The VPS host can successfully establish TLS connections to both services.

Host IMAP test:

- TLS 1.2 established.
- Certificate verification: OK.
- Dovecot greeting received.
- Exit code: 0.

Host SMTP test:

- TLS 1.2 established.
- Certificate verification: OK.
- SMTP response: `250 CHUNKING`.
- Exit code: 0.

However, the Next.js container times out during TLS negotiation.

---

## 3. Packet Capture Evidence

We captured actual traffic using:

`tcpdump -ni any -vv 'host 46.105.104.51 and tcp port 993'`

The packet capture showed:

### Outbound SYN

Container:

`10.0.2.6 -> 46.105.104.51:993`

Packet successfully leaves through `ens3` after source NAT:

`10.253.31.111 -> 46.105.104.51:993`

### Incoming SYN-ACK

The mail server responds:

`46.105.104.51:993 -> 10.253.31.111`

The response is translated and reaches the Docker container:

`46.105.104.51:993 -> 10.0.2.6`

### Container ACK

The container successfully sends its ACK.

### TLS ClientHello

The container sends TLS ClientHello packets through its Docker interface.

However, these packets repeatedly appear on `docker_gwbridge` and do not appear leaving `ens3`.

This indicates a problem with outbound established-connection forwarding or firewall handling.

Do not assume that all Docker return traffic is broken. The SYN-ACK and ACK packets are demonstrably reaching the container. Investigate the precise direction and connection state of the subsequent TLS packets.

---

## 4. Current nftables Configuration

Existing firewall:

`table inet cloud_dev`

Forward chain:

`chain forward`

Default policy:

`drop`

Current outbound TCP rule:

```nft
iifname "docker_gwbridge" oifname "ens3" \
ip saddr 10.0.2.0/24 \
tcp dport { 25, 80, 143, 443, 465, 587, 993, 23306, 24900 } \
ct state new counter accept \
comment "DOCKER-EGRESS-TCP"
```

Existing return rule:

```nft
iifname "ens3" oifname "docker_gwbridge" \
ip daddr 10.0.2.0/24 \
ct state established,related counter accept \
comment "DOCKER-EGRESS-RETURN"
```

The current configuration does not clearly provide a corresponding outbound established-state permission.

A possible required rule is:

```nft
iifname "docker_gwbridge" oifname "ens3" \
ip saddr 10.0.2.0/24 \
tcp dport { 25, 80, 143, 443, 465, 587, 993, 23306, 24900 } \
ct state established counter accept \
comment "DOCKER-EGRESS-TCP-ESTABLISHED"
```

Alternatively, combine both states into the existing service-specific rule:

```nft
ct state { new, established }
```

**Do not blindly apply this example.** Inspect the complete existing ruleset, chain ordering, NAT behavior, connection tracking, and the toolkit's actual generated rules before selecting the correct implementation.

Also investigate whether an earlier `jump dokploy_auto` or another chain can affect rule evaluation.

---

## 5. Existing Toolkit Files

Main firewall script:

`/usr/local/lib/vps-setup-toolkit/scripts/firewall.sh`

Existing configuration:

`/etc/default/vps-setup`

Existing firewall watcher:

`vps-firewall-watch.service`

Watcher executable:

`/usr/local/sbin/vps-firewall-watch`

Watcher invokes:

`/usr/local/lib/vps-setup-toolkit/scripts/firewall.sh nft-reconcile`

The watcher runs approximately every 15 seconds.

Previously observed configuration:

```ini
TCP_EGRESS_PORTS=""
UDP_EGRESS_PORTS=""
SELECTED_SERVICE_IDS=""
CUSTOM_TCP_PORTS=""
CUSTOM_UDP_PORTS=""
MANAGED_UFW_TCP=""
MANAGED_UFW_UDP=""
ENABLE_DOKPLOY_INGRESS="1"
TRAEFIK_IP="10.0.2.2"
TRAEFIK_BRIDGE="docker_gwbridge"
NFT_FAMILY="inet"
NFT_TABLE="cloud_dev"
NFT_PARENT="forward"
NFT_MANAGED="vps_docker_forward"
WAN_IF=""
WATCH_INTERVAL="15"
```

The existing watcher has also reported:

`nftables validation failed; generated rules were NOT applied.`

The current script appears to suppress the actual `nft -c -f` error and delete its temporary generated file. Investigate and fix this diagnostic problem too.

---

## 6. Required Permanent Fix

### A. Correct Docker outbound connection-state handling

The firewall generator must correctly handle:

- New outbound TCP connections.
- Established outbound TCP packets.
- Established and related return packets.
- UDP traffic where appropriate.
- Multiple Docker bridges and supported subnets.
- Docker Swarm overlay traffic where applicable.

Do not assume one interface or one subnet covers every Docker workload.

### B. Unified Service Access menu

Integrate the following existing planned menu item:

`[X] Unified Service Access (Host + Docker Containers)`

It must support:

1. Select individual common services.
2. Select all common services.
3. Add custom TCP ports.
4. Add custom UDP ports.
5. Remove previously selected services.
6. View currently configured services and ports.
7. Test host connectivity.
8. Test Docker container connectivity.
9. Repair/reconcile firewall rules.
10. Backup and restore configuration.
11. Persist rules after reboot.
12. Persist rules after Docker network recreation.
13. Avoid duplicate rules.

Include common categories such as:

- HTTP/HTTPS
- DNS/NTP
- SMTP/SMTPS/Submission
- IMAP/IMAPS
- POP3/POP3S
- MySQL/MariaDB
- PostgreSQL
- MongoDB
- Redis
- S3-compatible storage
- Garage/MinIO
- SSH/SFTP
- Git/package registries
- API and messaging services
- Monitoring
- LDAP
- VPN services
- Custom TCP/UDP services

Services should be outbound-only by default. Never expose public inbound ports unless the user explicitly selects that behavior.

### C. Firewall reconciliation

The toolkit must:

- Generate correct nftables rules.
- Validate using `nft -c -f`.
- Display actual parser errors.
- Preserve failed generated files for debugging.
- Apply only valid rulesets.
- Preserve unrelated nftables rules and chains.
- Avoid flushing the entire ruleset.
- Avoid duplicate rules during repeated reconciliation.
- Preserve Dokploy and Traefik ingress functionality.
- Avoid breaking Docker's own firewall chains.

### D. Configuration and persistence

All selected services must be stored in the existing toolkit configuration system.

The watcher must regenerate the correct rules after configuration changes, reboot, or Docker bridge recreation.

Do not implement another independent timer or competing firewall watcher.

---

## 7. Implementation Workflow

Follow this order:

**Phase 1 — Inspect**

Read the complete relevant scripts and understand:

- `build_nft_ruleset`
- `nft_reconcile`
- Existing service selection logic
- Configuration parsing
- Watcher implementation
- Docker interface detection
- Existing nftables chain ownership

Do not modify anything before understanding the current implementation.

**Phase 2 — Backup**

Back up all files that will be modified, preserving permissions and ownership.

**Phase 3 — Diagnose**

Reproduce the missing outbound established-state behavior using a safe test.

Check chain ordering and confirm that the proposed rule is reached before any drop verdict.

**Phase 4 — Implement**

Make the smallest correct changes to the existing toolkit.

**Phase 5 — Validate**

Run shell syntax checks and nftables syntax validation.

Verify the generated rules do not conflict with Dokploy, Traefik, UFW, or Docker.

**Phase 6 — Test**

Verify:

- New TCP connections.
- Established outbound TCP traffic.
- Return traffic.
- IMAP 993.
- SMTP 587.
- HTTPS 443.
- MariaDB 23306.
- Garage S3 24900.
- DNS and NTP.
- Existing Dokploy application ingress.
- Docker network recreation.
- Firewall watcher reconciliation.

**Phase 7 — Report**

Provide:

- Root cause.
- Files modified.
- Backup locations.
- Exact changes made.
- Commands executed.
- Validation results.
- Any remaining issues.

---

## 8. Strict Safety Requirements

- Do not disable UFW.
- Do not disable nftables.
- Do not change the default DROP policies to ACCEPT.
- Do not flush Docker firewall chains.
- Do not restart Docker or Dokploy unnecessarily.
- Do not modify SSH access or SSH ports.
- Do not expose SMTP, IMAP, database, or Redis ports publicly.
- Do not remove working temporary rules before equivalent managed rules are installed and verified.
- Do not create duplicate firewall managers.
- Do not claim a fix is successful without actual connectivity tests.

**Final objective:** Make the existing VPS Setup Toolkit correctly and persistently manage outbound connectivity for both the VPS host and Docker containers, including all TCP connection states, without breaking existing applications, Dokploy, Traefik, or security policies.