# Contributing to VPS Sentinel

VPS Sentinel (the VPS Setup Toolkit) is open source under the [MIT License](LICENSE), and contributions are genuinely welcome. Whether you are fixing a typo, reporting a bug, adding a service to the outbound catalog, or improving firewall safety, your work helps people keep their servers secure.

## Ways to contribute

You do not need to be a Bash expert to help:

- **Report a bug** — tell us what you expected, what happened, your OS/package manager (`sudo vps-setup status`), and the relevant log lines from `/var/log/vps-setup/`.
- **Improve documentation** — clarify the installation steps, troubleshooting notes or firewall explanations in [`README.md`](README.md) and [`docs/`](docs/).
- **Add a service** — extend [`config/services.conf`](config/services.conf) when a hosted provider needs a documented outbound port.
- **Improve portability** — add or refine package-manager/init-system handling in [`scripts/common.sh`](scripts/common.sh) for another Linux distribution.
- **Write tests** — strengthen the stubbed suites in [`tests/`](tests/).
- **Review pull requests** — ask questions, test on a different OS, and suggest safer defaults.

Good first issues: documentation clarity, an extra service catalog entry, a test for an edge case, or a ShellCheck note.

## Development setup

```bash
git clone https://github.com/sayedatiqurrahman/vps-setup-toolkit.git
cd vps-setup-toolkit

# Syntax check every script
bash -n $(find . -name '*.sh' -type f)

# Run all non-destructive tests
bash tests/run-tests.sh

# Optional but recommended on Debian/Ubuntu
sudo apt-get install shellcheck
```

The test suite uses temporary directories and stubbed `ip`, `ufw`, `nft`, `systemctl` and package managers. It never changes a real firewall or installs real packages. Never run the toolkit modules directly against a production VPS while developing.

## Workflow

1. Fork the repository on GitHub and create a branch from `main`:
   ```bash
   git checkout -b fix/short-description
   ```
2. Make focused changes. Keep commits small and self-explanatory.
3. Add or update tests when you change firewall, selection or detection logic.
4. Run `bash tests/run-tests.sh` and ShellCheck before opening a pull request.
5. Push your branch and open a pull request describing:
   - what changed and why,
   - which OS/family you tested on,
   - any safety considerations (especially inbound exposure).

## Code guidelines

- Use strict Bash: `set -Eeuo pipefail` in entry points and standalone modules.
- Keep ShellCheck clean. Shared variables and intentional dynamic sourcing are documented in `.shellcheckrc`.
- Be idempotent: running an operation twice must not duplicate UFW rules, nftables jumps, services or config lines.
- Never use `eval`, and validate all user input (ports, IPs, CIDRs, IDs) before use.
- Keep inbound and outbound configuration strictly separate. Never expose database, Redis, S3, Docker API or mail ports publicly by default.
- Never flush the full nftables ruleset or delete rules the toolkit does not own. Only the dedicated managed chain may be flushed.
- Back up files before modifying them and log meaningful actions to `/var/log/vps-setup/`.
- Preserve support for non-Debian/Ubuntu Linux through runtime OS detection; do not hard-fail on a different package manager.
- Do not commit secrets, API keys, passwords, provider tokens, SSH keys or customer data.

## Testing firewall changes

Firewall changes are high risk. Before submitting:

- Add assertions to [`tests/test-firewall.sh`](tests/test-firewall.sh) for new rules or changed matching conditions.
- Verify the generated ruleset is validated with `nft -c -f` before application.
- Check that a second apply is a no-op and that unrelated parent-chain rules survive.
- Confirm the watcher can restore the rules after a simulated bridge change.

## Commit messages

Use a short imperative subject line and explain the motivation in the body when useful:

```text
Fix duplicate UFW egress rule after repeated preset selection

The managed-rule tracking dropped ports that were added on an earlier
run, so the next preset change could not remove them. Preserve ownership
of still-desired rules across reconciles.
```

## Code of conduct

Be respectful and constructive. Assume good intent, review code rather than people, and keep discussions focused on making the toolkit safer and easier to use. Harassment or personal attacks are not acceptable.

## License

By contributing, you agree that your contributions are licensed under the project's [MIT License](LICENSE). You retain copyright of your work; the project may redistribute it under the same license.

Questions? Open an issue at <https://github.com/sayedatiqurrahman/vps-setup-toolkit/issues>.
