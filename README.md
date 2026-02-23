# Claude Code Sandbox Devcontainer

A devcontainer that provides OS-level isolation for running Claude Code with `--dangerously-skip-permissions`, eliminating permission prompts while reducing blast radius compared to running on the host.

## Architecture

```
┌─ Windows Host ─────────────────────────────────────────┐
│  C:\Users\...\Git_Clones\  (OneDrive)                  │
│                                                         │
│  ┌─ Devcontainer (Ubuntu Noble) ──────────────────────┐ │
│  │  /workspace/  ← bind mount from host repo          │ │
│  │  Firewall: allowlist-only outbound                  │ │
│  │  Hooks: exfil guard, injection scanner, loop detect │ │
│  │  R 4.x + renv cache (Docker volume)                │ │
│  │  Node 20 + Python 3 + Poetry                       │ │
│  │                                                     │ │
│  │  claude --dangerously-skip-permissions               │ │
│  └─────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

## Quick Start

1. Open any repo in VS Code
2. Copy the `.devcontainer/` and `.claude/` folders into that repo (or use this repo directly)
3. VS Code → Command Palette → "Dev Containers: Reopen in Container"
4. Once built, run: `claude --dangerously-skip-permissions`

## What's Included

- **R** (r-base) + renv with persistent cache volume
- **Node.js 20** + npm
- **Python 3** + Poetry (via pipx)
- **Claude Code** (latest, globally installed)
- **Git** + gh CLI + git-delta
- **Firewall** — allowlist-only outbound (iptables + ipset), HTTPS open for research
- **Security hooks** — exfiltration guard, prompt injection scanner, loop detection

## Security Model

| Layer | Mechanism |
|-------|-----------|
| Filesystem | Container sees only `/workspace` (bind mount) + Docker volumes |
| Network | Allowlist firewall — default DROP, HTTPS (443) open for research |
| Exfiltration guard | PreToolUse hook blocks `curl POST`, `wget --post-data`, `nc`, etc. |
| Injection scanner | PostToolUse hook warns on prompt injection patterns in WebFetch |
| Loop detection | Hooks block repeated commands, track failures, gate on progress |
| Credentials | SSH agent forwarding (no keys in container), `.gitconfig` readonly |
| Claude config | Docker volume (isolated from host `.claude/`) |
| Sudo | Locked down — only `init-firewall.sh` allowed |
| CI | Trivy scans for CVEs, misconfigs, secrets, licenses |

## Network Policy

HTTPS (port 443) is open to any domain for research. Exfiltration is mitigated at the application layer by the `exfil-guard.sh` hook, which blocks data-sending commands (`curl -X POST`, `wget --post-data`, `nc`, etc.). WebFetch is GET-only by design; WebSearch goes through Anthropic's API.

Non-HTTPS traffic is restricted to allowlisted domains only:

- `api.anthropic.com` — Claude API
- `statsig.anthropic.com`, `sentry.io` — Telemetry
- `registry.npmjs.org` — npm packages
- `cloud.r-project.org`, `packagemanager.posit.co` — CRAN/Posit
- `pypi.org`, `files.pythonhosted.org` — Python packages
- `github.com`, `bitbucket.org` — Git hosts
- `enaborea.atlassian.net` — Confluence MCP
- `api.weather.com` — IBM Weather API
- VS Code marketplace and update servers

To add more domains, edit `.devcontainer/init-firewall.sh`.

## Hooks

Six hooks are deployed globally inside the container via `setup-env.sh`:

| Hook | Event | Purpose |
|------|-------|---------|
| `exfil-guard.sh` | PreToolUse (Bash) | Blocks data-sending commands |
| `dedup-check.sh` | PreToolUse (all) | Blocks after 3 identical tool calls |
| `injection-scanner.sh` | PostToolUse (WebFetch) | Warns on prompt injection patterns |
| `failure-reset.sh` | PostToolUse (all) | Resets failure counter on success |
| `failure-counter.sh` | PostToolUseFailure | Warns after 5 consecutive failures |
| `progress-gate.sh` | Stop | Blocks stop if no git progress detected |

Source of truth: `.claude/hooks/`. Deployed to `~/.claude/hooks/` on container creation.

## Mounts

| Mount | Type | Purpose |
|-------|------|---------|
| Workspace | bind (delegated) | Host repo → `/workspace` |
| `.gitconfig` | bind (readonly) | Git config (name/email only) |
| bash history | Docker volume | Persistent across rebuilds |
| `.claude` | Docker volume | Isolated Claude config + hooks |
| renv cache | Docker volume | Persistent R package cache |
| `gh` config | Docker volume | GitHub CLI auth (use `gh auth login`) |

SSH keys are **not** mounted — SSH agent forwarding is used instead.

## Verification

After building, verify the sandbox works:

```bash
# Firewall blocks non-HTTPS unauthorized traffic
curl http://example.com              # Should fail (port 80 blocked)
curl https://api.github.com/zen     # Should succeed (HTTPS open)

# Tools are available
R --version
node --version
python3 --version
claude --version

# Git works via SSH agent forwarding
git remote -v
git fetch

# Run test suites
bash tests/test-container.sh
bash tests/test-firewall.sh
bash tests/test-hooks.sh
```

## Roadmap

See [open issues](https://github.com/LevRoz630/claude-sandbox-devcontainer/issues) for planned work.
