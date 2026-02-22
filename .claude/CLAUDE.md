# Claude Code Sandbox Devcontainer

## Project Overview
A devcontainer providing OS-level isolation for running Claude Code with `--dangerously-skip-permissions`. It sandboxes Claude inside a locked-down Ubuntu container with allowlist-only firewall, no sudo escalation, and no host credential leakage.

## Key Directories
- `.devcontainer/` — Dockerfile, firewall init, env setup
- `tests/` — Bash test suites for firewall and container validation
- `docs/` — Design docs and research

## Stack
- Dockerfile + devcontainer.json (no docker-compose)
- Bash scripts (shellcheck-clean, `set -uo pipefail`)
- iptables/ipset firewall rules
- R 4.x + renv, Node 20, Python 3 + Poetry

## Conventions
- Test scripts use a `pass()`/`fail()`/`skip()` pattern with summary counts
- Firewall allowlist lives in `.devcontainer/init-firewall.sh`
- All scripts should use `set -uo pipefail`
- Security is the primary concern — never weaken isolation

## Testing
```bash
bash /workspace/tests/test-container.sh   # Container validation
bash /workspace/tests/test-firewall.sh    # Firewall validation (needs firewall active)
```

## Security Invariants (never break these)
- No SSH private keys inside the container — agent forwarding only
- No `NOPASSWD: ALL` sudo — only allowlisted commands
- Firewall default policy is DROP — only allowlisted domains reachable
- Host filesystem not accessible outside /workspace
