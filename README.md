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
│  │  R 4.x + renv cache (Docker volume)                │ │
│  │  Node 20 + Python 3.11 + Poetry                    │ │
│  │                                                     │ │
│  │  claude --dangerously-skip-permissions               │ │
│  └─────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

## Quick Start

1. Open any repo in VS Code
2. Copy the `.devcontainer/` folder into that repo (or use this repo directly)
3. VS Code → Command Palette → "Dev Containers: Reopen in Container"
4. Once built, run: `claude --dangerously-skip-permissions`

## What's Included

- **R** (r-base) + renv with persistent cache volume
- **Node.js 20** + npm
- **Python 3** + Poetry (via pipx)
- **Claude Code** (latest, globally installed)
- **Git** + gh CLI + git-delta
- **Firewall** — allowlist-only outbound (iptables + ipset)

## Security Model

| Layer | Mechanism |
|-------|-----------|
| Filesystem | Container sees only `/workspace` (bind mount) + Docker volumes |
| Network | Allowlist firewall — only approved domains are reachable |
| Host credentials | SSH keys + git config mounted readonly |
| Claude config | Docker volume (isolated from host `.claude/`) |
| Permissions | `--dangerously-skip-permissions` is safe because the container IS the sandbox |

## Allowed Outbound Domains

- `api.anthropic.com` — Claude API
- `statsig.anthropic.com`, `sentry.io` — Telemetry
- `registry.npmjs.org` — npm packages
- `cloud.r-project.org`, `packagemanager.posit.co` — CRAN/Posit
- `pypi.org`, `files.pythonhosted.org` — Python packages
- `github.com`, `bitbucket.org` — Git hosts
- `*.atlassian.net` — Confluence MCP
- `api.weather.com` — IBM Weather API
- VS Code marketplace and update servers

To add more domains, edit `.devcontainer/init-firewall.sh`.

## Mounts

| Mount | Type | Purpose |
|-------|------|---------|
| Workspace | bind (delegated) | Host repo → `/workspace` |
| `.ssh` | bind (readonly) | Git SSH auth |
| `.gitconfig` | bind (readonly) | Git config |
| `gh` config | bind (readonly) | GitHub CLI auth |
| bash history | Docker volume | Persistent across rebuilds |
| `.claude` | Docker volume | Isolated Claude config |
| renv cache | Docker volume | Persistent R package cache |

## Verification

After building, verify the sandbox works:

```bash
# Firewall blocks unauthorized traffic
curl https://example.com          # Should fail (REJECTED)
curl https://api.github.com/zen   # Should succeed

# Tools are available
R --version
node --version
python3 --version
claude --version

# Git works through readonly SSH mount
git remote -v
git fetch

# Workspace is isolated
ls /home/  # Only vscode user
```


## Roadmap

See [open issues](https://github.com/LevRoz630/claude-sandbox-devcontainer/issues) for planned work.