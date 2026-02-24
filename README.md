# Claude Code Sandbox Devcontainer

A devcontainer that sandboxes [Claude Code](https://docs.anthropic.com/en/docs/claude-code) so you can run it with `--dangerously-skip-permissions` without worrying about what it might do to your machine.

The container provides OS-level isolation: an allowlist-only firewall, locked-down sudo, no host credentials, and a set of security hooks that catch exfiltration attempts and prompt injection at the application layer.

## Prerequisites

- **Docker Desktop** (or compatible runtime like Podman/Rancher Desktop)
- **VS Code** with the [Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) extension
- **Git** configured with `user.name` and `user.email` in `~/.gitconfig`
- **SSH agent** running on the host with your keys loaded:
  - **Windows:** Enable the OpenSSH Authentication Agent service, then `ssh-add`
  - **Mac/Linux:** Typically running by default; verify with `ssh-add -l`
- **Anthropic API key** — needed for Claude Code to function. Either:
  - Set `ANTHROPIC_API_KEY` as a host environment variable, or
  - Run `claude login` inside the container on first use

## Getting started

1. Clone this repo (or copy `.devcontainer/` and `.claude/` into your own project)
2. Open in VS Code → Command Palette → **Dev Containers: Reopen in Container**
3. Once built, run `claude --dangerously-skip-permissions`
4. On first run inside the container:
   - Authenticate Claude Code: `claude login` (or set `ANTHROPIC_API_KEY` on your host)
   - Authenticate GitHub CLI: `gh auth login` (if you need PR/issue access)
5. Verify the setup: `bash tests/test-container.sh`

## MCP servers

MCP servers (Confluence, Bitbucket, GitHub) work inside the container automatically — set the env vars on your host and they get passed through on container build. `setup-env.sh` generates `~/.claude/.mcp.json` from them.

| Server | Required env vars |
|--------|-------------------|
| Confluence | `ATLASSIAN_SITE_NAME`, `ATLASSIAN_USER_EMAIL`, `ATLASSIAN_API_TOKEN` |
| Bitbucket | `ATLASSIAN_BITBUCKET_USERNAME`, `ATLASSIAN_BITBUCKET_APP_PASSWORD` |
| GitHub | `GITHUB_PERSONAL_ACCESS_TOKEN` |

Only servers whose credentials are present get added. The config is only generated once — it won't overwrite your edits.

HTTPS (443) is open, so no firewall changes are needed for MCP servers.

## Environment variables

Set these on your host before building the container. They're passed through via `devcontainer.json`.

| Variable | Purpose | Required |
|----------|---------|----------|
| `ANTHROPIC_API_KEY` | Claude Code authentication (alternative: `claude login`) | Yes |
| `ATLASSIAN_SITE_NAME` | Confluence/Jira site (e.g. `mycompany.atlassian.net`) | For Confluence MCP |
| `ATLASSIAN_USER_EMAIL` | Atlassian account email | For Confluence MCP |
| `ATLASSIAN_API_TOKEN` | Atlassian API token | For Confluence MCP |
| `ATLASSIAN_BITBUCKET_USERNAME` | Bitbucket username | For Bitbucket MCP |
| `ATLASSIAN_BITBUCKET_APP_PASSWORD` | Bitbucket app password | For Bitbucket MCP |
| `GITHUB_PERSONAL_ACCESS_TOKEN` | GitHub PAT (for MCP server, not `gh` CLI) | For GitHub MCP |
| `FIREWALL_EXTRA_DOMAINS` | Space-separated domains to add to firewall allowlist | No |
| `DNS_FILTER_PRIMARY` | DNS filtering provider (`auto`, IP, or `none`) | No |
| `TZ` | Timezone (default: `Europe/London`) | No |

How to set them:
- **Windows:** System Properties → Environment Variables, or `setx VAR value`
- **Mac/Linux:** Add `export VAR=value` to `~/.bashrc` or `~/.zshrc`

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

Hook source of truth is `.claude/hooks/`. They're copied to `~/.claude/hooks/` on container creation by `setup-env.sh`.

**Customization:** To remove languages you don't need (e.g. R), delete the corresponding lines from `.devcontainer/Dockerfile` and rebuild.

## Security model

| Layer | How |
|-------|-----|
| Filesystem | Container only sees `/workspace` (bind mount) + Docker volumes |
| Network | Allowlist firewall, default DROP, HTTPS open for research |
| Exfiltration | Hooks block data-sending commands at the application layer |
| Injection | PostToolUse hook warns on known prompt injection patterns |
| Loop detection | Hooks block repeated commands and track failures |
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

## Platform notes

**Windows:** The `.gitconfig` mount uses `%USERPROFILE%\.gitconfig`. SSH agent forwarding requires the OpenSSH Authentication Agent service to be running (`Get-Service ssh-agent` in PowerShell).

**Mac/Linux:** Change the `.gitconfig` mount in `devcontainer.json` from:
`source=${localEnv:USERPROFILE}\\.gitconfig` → `source=${localEnv:HOME}/.gitconfig`
SSH agent forwarding works out of the box on most systems.

## Network policy

HTTPS (443) is open broadly so Claude can research anything. Exfiltration over HTTPS is blocked at the application layer by the exfil-guard hook (no `curl -d`, no `wget --post-data`, no `nc`). Non-HTTPS traffic is limited to the allowlist.

Allowlisted domains: `api.anthropic.com`, `statsig.anthropic.com`, `sentry.io`, `registry.npmjs.org`, `cloud.r-project.org`, `packagemanager.posit.co`, `pypi.org`, `files.pythonhosted.org`, `github.com`, `bitbucket.org`, and VS Code update servers.

To add custom non-HTTPS domains, set `FIREWALL_EXTRA_DOMAINS` on the host (space-separated list). They'll be resolved and added to the allowlist on container start.

**DNS filtering:** By default, the container auto-detects whether it can reach Quad9 (9.9.9.9). If reachable, the system resolver (`/etc/resolv.conf`) is pointed at Quad9 and a DNAT rule redirects any explicit external DNS queries there too — so all DNS resolution goes through Quad9's malware/phishing/C2 blocklist. If unreachable (e.g., corporate network blocking external DNS), filtering is skipped and the network's default DNS is used.

Override with `DNS_FILTER_PRIMARY`:
- Unset (default): auto-detect
- `9.9.9.9`: always use Quad9
- `1.1.1.2`: use Cloudflare malware filtering
- `none`: disable DNS filtering

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
