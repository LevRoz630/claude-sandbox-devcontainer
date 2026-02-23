# Claude Code Sandbox Devcontainer

A devcontainer that sandboxes [Claude Code](https://docs.anthropic.com/en/docs/claude-code) so you can run it with `--dangerously-skip-permissions` without worrying about what it might do to your machine.

The container provides OS-level isolation: an allowlist-only firewall, locked-down sudo, no host credentials, and a set of security hooks that catch exfiltration attempts and prompt injection at the application layer.

## Getting started

1. Clone this repo (or copy `.devcontainer/` and `.claude/` into your own project)
2. Open in VS Code → Command Palette → **Dev Containers: Reopen in Container**
3. Once built, run `claude --dangerously-skip-permissions`

## What's inside

**Languages & tools:** R 4.x with renv, Node 20, Python 3 with Poetry, Claude Code, Git, gh CLI, git-delta, jq, fzf.

**Firewall:** Default-DROP iptables policy. HTTPS (443) is open to any domain for research; all other ports are restricted to an allowlist (Anthropic API, npm, CRAN, PyPI, GitHub, etc). Edit `.devcontainer/init-firewall.sh` to add domains.

**Security hooks** are deployed globally inside the container — they apply to every repo you open:

| Hook | Trigger | What it does |
|------|---------|--------------|
| `exfil-guard.sh` | PreToolUse (Bash) | Blocks `curl POST`, `wget --post-data`, `nc`, DNS exfil, etc. |
| `dedup-check.sh` | PreToolUse | Blocks after 3 identical tool calls (loop detection) |
| `injection-scanner.sh` | PostToolUse (WebFetch) | Flags prompt injection patterns in fetched content |
| `failure-reset.sh` | PostToolUse | Resets the failure counter on success |
| `failure-counter.sh` | PostToolUseFailure | Warns after 5 consecutive failures |
| `progress-gate.sh` | Stop | Blocks stop if no git progress detected |

Hook source of truth is `.claude/hooks/`. They're copied to `~/.claude/hooks/` on container creation by `setup-env.sh`.

## Security model

| Layer | How |
|-------|-----|
| Filesystem | Container only sees `/workspace` (bind mount) + Docker volumes |
| Network | Allowlist firewall, default DROP, HTTPS open for research |
| Exfiltration | Hooks block data-sending commands at the application layer |
| Injection | PostToolUse hook warns on known prompt injection patterns |
| Loop detection | Hooks block repeated commands, track failures, gate on progress |
| Credentials | SSH agent forwarding only (no keys in container), `.gitconfig` readonly |
| Sudo | Locked down — only `init-firewall.sh` is allowed |
| CI | Trivy scans for CVEs, Dockerfile misconfigs, secrets, and licenses |

## Mounts

| Mount | Type | Purpose |
|-------|------|---------|
| Workspace | bind (delegated) | Host repo → `/workspace` |
| `.gitconfig` | bind (readonly) | Git name/email only |
| bash history | Docker volume | Persists across rebuilds |
| `.claude` | Docker volume | Isolated Claude config + hooks |
| renv cache | Docker volume | R package cache |
| gh config | Docker volume | GitHub CLI auth (`gh auth login`) |

SSH keys are **not** mounted — agent forwarding is used instead.

## Network policy

HTTPS (443) is open broadly so Claude can research anything. Exfiltration over HTTPS is blocked at the application layer by the exfil-guard hook (no `curl -d`, no `wget --post-data`, no `nc`). Non-HTTPS traffic is limited to the allowlist.

Allowlisted domains: `api.anthropic.com`, `statsig.anthropic.com`, `sentry.io`, `registry.npmjs.org`, `cloud.r-project.org`, `packagemanager.posit.co`, `pypi.org`, `files.pythonhosted.org`, `github.com`, `bitbucket.org`, `enaborea.atlassian.net`, `api.weather.com`, and VS Code update servers.

## Verification

After building, check that things work:

```bash
curl http://example.com              # should fail (port 80 blocked)
curl https://api.github.com/zen     # should succeed (HTTPS open)
R --version && node --version && python3 --version && claude --version
bash tests/test-container.sh
bash tests/test-firewall.sh
bash tests/test-hooks.sh
```

## Roadmap

See [open issues](https://github.com/LevRoz630/claude-sandbox-devcontainer/issues).
