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
- **Anthropic API key** — needed for Claude Code to function. Options:
  - Use 1Password (see [Credentials](#credentials) below), or
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

## Credentials

Credentials (API keys, tokens) can come from three sources. The container checks them in this order:

1. **Environment variables** — set on the host or in a `.env` file (gitignored). Passed through via `devcontainer.json containerEnv`. If a variable is already set, 1Password won't override it.
2. **1Password** — the `op` CLI is installed in the container. If configured, it fills in any credentials that aren't already set from env vars. See [1Password setup](#1password-setup) below.
3. **Manual** — run `claude login`, `gh auth login`, etc. inside the container.

### 1Password setup

The container ships with the [1Password CLI](https://developer.1password.com/docs/cli/) pre-installed. Two auth modes:

**Service account (headless / CI):** Set `OP_SERVICE_ACCOUNT_TOKEN` on the host. Authentication is automatic, no interaction needed.

**Interactive (personal vault):** On first container create, you'll see instructions to add your 1Password account. After that, account metadata is persisted in a Docker volume (`~/.config/op`), so subsequent starts only need your master password.

To set it up:

1. Create a vault in 1Password (default name: `DevContainer`, or set `OP_VAULT_NAME` to use a different one)
2. Add these items to the vault:

| Item name | Type | Fields |
|-----------|------|--------|
| Anthropic API Key | API Credential | `credential` |
| Atlassian | Login | `site name`, `email`, `api token` |
| Bitbucket Token | API Credential | `credential` |
| GitHub Token | API Credential | `token` |
| SSH Key GitHub | SSH Key | `private_key` (optional) |
| SSH Key Bitbucket | SSH Key | `private_key` (optional) |

3. Build the container. On first terminal open, `setup-1password.sh` will attempt to authenticate and pull credentials from the vault.

The script only fills in variables that aren't already set — so you can mix sources (e.g. Anthropic key from env var, Atlassian tokens from 1Password).

SSH keys from 1Password are loaded directly into the ssh-agent (never written to disk). If the vault has a GitHub Token, the `gh` CLI is authenticated automatically.

### Env vars

If you don't want 1Password, plain env vars still work exactly as before.

## MCP servers

MCP servers (Confluence, Jira, Bitbucket, GitHub) are configured automatically from env vars — whether those come from `.env`, host environment, or 1Password. `setup-env.sh` generates `~/.claude/.mcp.json` from them.

| Server | Package | Required env vars |
|--------|---------|-------------------|
| Confluence | `@aashari/mcp-server-atlassian-confluence` | `ATLASSIAN_SITE_NAME`, `ATLASSIAN_USER_EMAIL`, `ATLASSIAN_API_TOKEN` |
| Bitbucket | `@aashari/mcp-server-atlassian-bitbucket` | `ATLASSIAN_USER_EMAIL`, `BITBUCKET_API_TOKEN` |
| GitHub | `@modelcontextprotocol/server-github` | `GITHUB_PERSONAL_ACCESS_TOKEN` |

Confluence and Bitbucket use **separate tokens** (Atlassian has different token systems per product):
- **Confluence:** Classic API token from [id.atlassian.com](https://id.atlassian.com/manage-profile/security/api-tokens) (basic auth)
- **Bitbucket:** Scoped API token from Bitbucket → Account settings → Security → API tokens

Git HTTPS push/pull to Bitbucket is configured automatically from `BITBUCKET_API_TOKEN`.

Only servers whose credentials are present get added. The config is only generated once — it won't overwrite your edits.

HTTPS (443) is open, so no firewall changes are needed for MCP servers.

## Environment variables

Set these on your host before building the container, or add them to `.env` in the project root (gitignored). They're passed through via `devcontainer.json`. If using 1Password, the credential variables are optional — they'll be pulled from the vault instead.

| Variable | Purpose | Required |
|----------|---------|----------|
| `ANTHROPIC_API_KEY` | Claude Code authentication (alternative: `claude login` or 1Password) | Yes* |
| `ATLASSIAN_SITE_NAME` | Confluence/Jira site name (e.g. `mycompany`) | For Confluence/Jira MCP* |
| `ATLASSIAN_USER_EMAIL` | Atlassian account email | For Confluence + Bitbucket* |
| `ATLASSIAN_API_TOKEN` | Classic Atlassian API token ([create here](https://id.atlassian.com/manage-profile/security/api-tokens)) | For Confluence/Jira MCP* |
| `BITBUCKET_API_TOKEN` | Bitbucket scoped API token (Bitbucket → Account settings → Security) | For Bitbucket MCP + git HTTPS* |
| `GITHUB_PERSONAL_ACCESS_TOKEN` | GitHub PAT (for MCP server, not `gh` CLI) | For GitHub MCP* |
| `OP_SERVICE_ACCOUNT_TOKEN` | 1Password service account token (for headless/CI auth) | No |
| `OP_VAULT_NAME` | 1Password vault name (default: `DevContainer`) | No |
| `FIREWALL_EXTRA_DOMAINS` | Space-separated domains to add to firewall allowlist | No |
| `DNS_FILTER_PRIMARY` | DNS filtering provider (`auto`, IP, or `none`) | No |
| `TZ` | Timezone (default: `Europe/London`) | No |

\* Can come from 1Password instead of env vars.

How to set them:
- **`.env` file** (recommended): Create `.env` in the project root and fill in values — it's gitignored
- **1Password**: See [1Password setup](#1password-setup) — no env vars needed for credentials
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
| Credentials | 1Password (never on disk), SSH agent forwarding, `.gitconfig` readonly |
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
| op config | Docker volume | 1Password CLI account metadata |

SSH keys are **not** mounted — agent forwarding is used instead.

## Platform notes

**Windows:** The `.gitconfig` mount uses `%USERPROFILE%\.gitconfig`. SSH agent forwarding requires the OpenSSH Authentication Agent service to be running (`Get-Service ssh-agent` in PowerShell).

**Mac/Linux:** Change the `.gitconfig` mount in `devcontainer.json` from:
`source=${localEnv:USERPROFILE}\\.gitconfig` → `source=${localEnv:HOME}/.gitconfig`
SSH agent forwarding works out of the box on most systems.

## Network policy

HTTPS (443) is open broadly so Claude can research anything. Exfiltration over HTTPS is blocked at the application layer by the exfil-guard hook (no `curl -d`, no `wget --post-data`, no `nc`). Non-HTTPS traffic is limited to the allowlist.

Allowlisted domains: `api.anthropic.com`, `statsig.anthropic.com`, `sentry.io`, `registry.npmjs.org`, `cloud.r-project.org`, `packagemanager.posit.co`, `pypi.org`, `files.pythonhosted.org`, `github.com`, `bitbucket.org`, 1Password (`my.1password.com`, `.eu`, `.ca`, `cache.agilebits.com`), and VS Code update servers.

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
