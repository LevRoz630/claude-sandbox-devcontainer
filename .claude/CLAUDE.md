# Claude Code Sandbox Devcontainer

## Project Overview
Devcontainer for running Claude Code with `--dangerously-skip-permissions`. Ubuntu container with allowlist firewall, locked-down sudo, 1Password credential loading, and no host credential leakage.

## Key Directories
- `.devcontainer/` — Dockerfile, firewall, env setup
- `.claude/hooks/` — Security hooks (deployed globally on container create)
- `.github/workflows/` — Trivy CI scanning
- `tests/` — Bash test suites

## Stack
- Dockerfile + devcontainer.json (no docker-compose)
- Bash scripts (shellcheck-clean, `set -uo pipefail`)
- iptables/ipset firewall
- R 4.x + renv, Node 20, Python 3 + Poetry

## Conventions
- Tests use `pass()`/`fail()`/`skip()` with summary counts
- Firewall allowlist in `.devcontainer/init-firewall.sh`
- Hooks in `.claude/hooks/`, deployed to `~/.claude/hooks/` by `setup-env.sh`
- Credentials: 1Password → env vars → skip (see `setup-1password.sh`); interactive signin via `setup-1password` command, op config in Docker volume
- MCP servers registered via `claude mcp add-json --scope user` by `setup-env.sh`
- All scripts use `set -uo pipefail`

## Testing
```bash
bash tests/test-container.sh   # Container validation
bash tests/test-firewall.sh    # Firewall validation (needs firewall active)
bash tests/test-hooks.sh       # Hook unit tests (mock JSON, no API key)
```

## Security Invariants
- No SSH private keys inside the container — agent forwarding or 1Password (memory only)
- No plaintext secrets on disk — 1Password or env vars (in-memory export)
- No `NOPASSWD: ALL` sudo — only allowlisted commands
- Firewall default policy is DROP — only allowlisted domains reachable
- Host filesystem not accessible outside /workspace
- Hooks deploy globally in the container — apply to all repos

## Workflow: Explore → Plan → Build → Review → Ship

### Context Management
- `/clear` between unrelated tasks
- `/compact <focus>` after exploration and planning
- After 2 failed corrections: stop, `/clear`, rewrite the prompt
- Use subagents for investigation (separate context, return summaries)

### Checkpoints
- Every action creates a checkpoint; `Esc Esc` or `/rewind` to restore
- Checkpoints only track Claude's changes — still commit to git

### Review
- After completing a feature: `/fresh-review` for unbiased review in isolated context
- Or: `claude --worktree review` in a second terminal

### Parallel Work
- `claude --worktree <name>` for independent features
- `export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` for multi-agent coordination
