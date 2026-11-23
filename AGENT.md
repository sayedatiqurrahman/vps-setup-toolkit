# Project Development Prompt — VPS Setup Toolkit

You are a senior Linux system administrator, DevOps engineer, Bash developer, and security-focused software architect.

I have created a GitHub repository for a project named **VPS Setup Toolkit**.

## CRITICAL: READ THIS FIRST

At the repository root, I have already added the complete setup and security documentation:

`complete-vps-setup-security-guide.md`

**This is the ONLY existing project file.**

Before writing any code:

1. Read the entire Markdown file from beginning to end.
2. Understand every installation procedure, service category, firewall rule, security requirement, configuration, and troubleshooting instruction.
3. Treat this document as the primary project specification.
4. Do not assume that other scripts, directories, configurations, or project files already exist.
5. Do not delete, overwrite, or unnecessarily modify the original Markdown file.
6. Do not invent features that conflict with the documentation.

## Main Objective

Develop a complete, production-oriented, interactive VPS Setup Toolkit for Debian and Ubuntu servers.

The toolkit should allow users to configure a fresh VPS through a single command and an interactive terminal menu.

Example:

```bash
curl -fsSL https://YOUR-REPOSITORY-URL/install.sh | sudo bash
```

Use a secure installation method. Prefer downloading and verifying the installer before executing it when practical.

## 1. Core Requirements

- One main installer and one unified interactive menu.
- Root permission checking.
- OS and architecture detection.
- Debian and Ubuntu compatibility checks.
- Dependency installation.
- Automatic configuration backup before modifying existing files.
- Safe error handling and logging.
- Installation progress and clear success/failure messages.
- Idempotent operations: running the installer repeatedly must not create duplicate rules, services, or configurations.
- Support for installation, configuration, repair, removal, and status checking where applicable.

## 2. Interactive Main Menu

Create a clear terminal menu with categories such as:

1. Base VPS Setup
2. Node.js and PM2
3. Docker Engine
4. Dokploy
5. Coolify
6. PHP and Nginx
7. WordPress Requirements
8. SSH Security
9. Firewall and Service Port Manager
10. Custom Port Configuration
11. Repair and Recovery
12. System Status
13. Uninstall Toolkit
0. Exit

Users must be able to select individual categories or multiple categories in one operation.

For example:

`2,3,4,9`

The toolkit should display a summary of selected operations and request confirmation before making changes.

Do not install every available service automatically.

## 3. Firewall and Service Selection

Implement the service selector according to the existing Markdown specification.

Requirements:

- Select one or multiple service categories.
- Support custom TCP ports.
- Support custom UDP ports.
- Validate all port numbers.
- Prevent duplicate entries.
- Save selected configuration persistently.
- Apply selected outbound rules to UFW and the managed nftables rules.
- Keep inbound and outbound firewall configuration separate.
- Provide a confirmation screen before applying changes.
- Display currently configured rules.
- Support adding and removing selected services.

Never expose database, Redis, Docker API, or S3 ports publicly by default.

Default public inbound access should remain limited to SSH, HTTP, and HTTPS unless the administrator explicitly authorizes additional inbound access.

## 4. Docker and nftables Compatibility

This is a particularly important requirement.

The VPS may use Docker Swarm, Dokploy, Coolify, Traefik, and multiple Docker networks.

The firewall implementation must:

- Detect Docker bridge interfaces dynamically.
- Detect Docker bridge subnets dynamically.
- Handle Docker bridge recreation.
- Recover after server reboot.
- Avoid flushing the complete nftables ruleset.
- Never overwrite unrelated existing firewall rules.
- Use a dedicated toolkit-managed nftables chain.
- Integrate safely with the existing firewall configuration.
- Avoid duplicate jump rules.
- Persist configuration across reboots.
- Provide a persistent systemd watcher where required.
- Detect missing firewall tables or chains and recover safely.

Never assume that every VPS has the same Docker interfaces or network subnets.

## 5. Installation Categories

Support independent installation and management of:

- Node.js (multiple supported versions)
- npm and pnpm
- PM2
- Docker Engine
- Docker Compose
- Dokploy
- Coolify
- PHP
- Composer
- Nginx
- WordPress prerequisites
- Git
- UFW
- nftables
- Fail2ban
- Basic server security tools

Check compatibility before installing each component.

Do not install Dokploy and Coolify together automatically. Let the administrator decide.

Do not blindly replace existing installations or configurations.

## 6. Configuration and Security

- Store persistent configuration under `/etc/vps-setup/` or another appropriate system location.
- Store logs under `/var/log/vps-setup/`.
- Use secure file permissions.
- Never store passwords or API secrets in public repository files.
- Never disable SSH security without explicit confirmation.
- Preserve existing SSH access.
- Never expose Docker's unauthenticated TCP API.
- Never open all ports automatically.
- Use trusted source IP restrictions for additional inbound access whenever possible.
- Make destructive operations require explicit confirmation.

## 7. Project Architecture

Create a clean and maintainable repository.

You may choose a modular architecture, but retain a single entry point.

Suggested structure:

```text
vps-setup-toolkit/
├── complete-vps-setup-security-guide.md
├── README.md
├── LICENSE
├── CHANGELOG.md
├── install.sh
├── config/
│   └── services.conf
├── scripts/
│   ├── common.sh
│   ├── system.sh
│   ├── firewall.sh
│   ├── docker.sh
│   ├── nodejs.sh
│   ├── pm2.sh
│   ├── dokploy.sh
│   ├── coolify.sh
│   ├── php.sh
│   ├── nginx.sh
│   ├── security.sh
│   └── recovery.sh
├── systemd/
│   └── vps-firewall-watch.service
├── docs/
│   ├── INSTALLATION.md
│   ├── FIREWALL.md
│   ├── SERVICES.md
│   └── TROUBLESHOOTING.md
└── tests/
    ├── test-firewall.sh
    └── test-validation.sh
```

You may improve this architecture if necessary.

## 8. Documentation

Create a professional README containing:

- Project overview
- Features
- Supported operating systems
- Installation instructions
- Usage examples
- Screenshots or terminal menu examples
- Firewall security explanation
- Supported services
- Troubleshooting
- Contribution guidelines
- License

The README must explain how users can install the toolkit and select individual services.

Keep the original complete setup Markdown guide intact.

## 9. Development Standards

- Use Bash with strict error handling where appropriate.
- Quote variables correctly.
- Validate all user input.
- Avoid unsafe `eval`.
- Avoid hardcoded interface names and network subnets.
- Use functions and reusable modules.
- Include meaningful comments.
- Check whether commands and services exist before using them.
- Handle missing dependencies.
- Make operations idempotent.
- Use shellcheck-compatible code.
- Test firewall commands before applying them wherever practical.

## 10. Testing and Validation

Before considering the project complete:

1. Validate shell syntax using `bash -n`.
2. Run ShellCheck where available.
3. Test menu input validation.
4. Test multiple service selections.
5. Test custom TCP and UDP port validation.
6. Test duplicate prevention.
7. Test UFW rule generation.
8. Test nftables rule generation.
9. Test Docker bridge detection.
10. Test systemd service generation.
11. Test recovery after simulated Docker bridge changes.
12. Verify that unrelated firewall rules are preserved.
13. Verify that repeated execution does not duplicate configuration.

Use safe test environments or dry-run modes. Never test destructive firewall changes against a production VPS without explicit authorization.

## 11. Working Instructions

Work directly inside the existing repository.

Follow this sequence:

**Phase 1:** Read and analyze `complete-vps-setup-security-guide.md`.

**Phase 2:** Prepare the project architecture and implementation plan.

**Phase 3:** Build the core installer and interactive menu.

**Phase 4:** Implement firewall and service selection.

**Phase 5:** Implement individual installation modules.

**Phase 6:** Implement recovery, status, and uninstall functionality.

**Phase 7:** Write README and supporting documentation.

**Phase 8:** Run validation and fix discovered problems.

Do not stop after creating an architecture or placeholder files. Implement functional code.

Do not silently skip features. If something cannot be safely implemented, explain why and provide a safe alternative.

Do not ask me to manually create files that you can create yourself.

**Final requirement:** Deliver a functional, documented, tested VPS Setup Toolkit that follows the existing Markdown specification and can be used by other VPS administrators, not just my personal server.