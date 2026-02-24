# Claude Code Sandbox Devcontainer

A devcontainer that sandboxes [Claude Code](https://docs.anthropic.com/en/docs/claude-code) so you can run it with `--dangerously-skip-permissions` without worrying about what it might do to your machine.

The container provides OS-level isolation: an allowlist-only firewall, locked-down sudo, no host credentials, and a set of security hooks that catch exfiltration attempts and prompt injection at the application layer.

## Prerequisites

- **Docker Desktop** (or compatible runtime like Podman/Rancher Desktop)
- **VS Code** with the [Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) extension
- **Git** configured with `user.name` and `user.email` in `~/.gitconfig`
- **Claude Code authentication** (one of):
  - Run `claude login` inside the container (OAuth, no API key needed), or
  - Set `ANTHROPIC_API_KEY` as a host environment variable, or
  - Store it in 1Password (see [Credentials](#credentials) below)
- **SSH keys** (optional, for git over SSH) — three options:
  - **1Password** (recommended): Store keys in the vault; they're loaded into an in-container agent automatically (no host admin needed)
  - **Host agent forwarding**: Requires OpenSSH Agent running on the host (Windows: `Get-Service ssh-agent`; Mac/Linux: usually running by default)
  - **HTTPS only**: Skip SSH entirely — use token-based HTTPS for GitHub/Bitbucket (configured automatically from env vars or 1Password)

## Getting started

### VS Code (recommended)

1. Clone this repo (or copy `.devcontainer/` and `.claude/` into your own project)
2. Create a `.env` file in the project root with your credentials (see [Environment variables](#environment-variables))
3. Open in VS Code → Command Palette → **Dev Containers: Reopen in Container**
4. Once built, run `cc` (alias for `claude --dangerously-skip-permissions`)
5. On first run inside the container:
   - Set up credentials: `setup-1password` (if using 1Password), or `claude login` (OAuth)
   - Authenticate GitHub CLI: `gh auth login` (if you need PR/issue access, and not using 1Password)
6. Verify the setup: `bash tests/test-container.sh`

### CLI

The `devcontainer` CLI doesn't read `.env` files — you must source it first:

```bash
set -a && source .env && set +a
devcontainer up --workspace-folder .
devcontainer exec --workspace-folder . bash
```

## Credentials

Credentials (API keys, tokens) can come from three sources. The container checks them in this order:

1. **Environment variables** — set on the host or in a `.env` file (gitignored). Passed through via `devcontainer.json containerEnv`. If a variable is already set, 1Password won't override it.
2. **1Password** — the `op` CLI is installed in the container. If configured, it fills in any credentials that aren't already set from env vars. See [1Password setup](#1password-setup) below.
3. **Manual** — run `claude login`, `gh auth login`, etc. inside the container.

### 1Password setup

The container ships with the [1Password CLI](https://developer.1password.com/docs/cli/) pre-installed. Two auth modes:

**Service account (headless / CI / SSO accounts):** Set `OP_SERVICE_ACCOUNT_TOKEN` on the host. Authentication is automatic, no interaction needed. **This is the only option for SSO accounts** (Microsoft, Google, Okta) because SSO signin requires the 1Password desktop app, which isn't available inside the container. Create a service account at your 1Password admin console → Integrations → [Service Accounts](https://developer.1password.com/docs/service-accounts/get-started/).

**Interactive (master-password accounts):** Open a terminal in the container and run `setup-1password`. The command walks you through setup:

- **First time:** Prompts for auth method (master password vs SSO), then guided `op account add` with sign-in address, email, secret key, and master password
- **Subsequent starts:** Prompts only for your master password (account config persists in a Docker volume)
- **During container build** (non-interactive): Exits gracefully with a reminder to run `setup-1password` in a terminal

Account metadata is stored in a Docker volume (`~/.config/op` inside the container), so it survives container rebuilds. (A bind mount from the host was removed because Windows mounts have `777` permissions which the `op` CLI rejects.)

To set it up:

1. Create a vault in 1Password (default name: `DevContainer`, or set `OP_VAULT_NAME` to use a different one)
2. Add these items to the vault:

| Item name | Type | Fields |
|-----------|------|--------|
| Anthropic API Key | API Credential | `credential` |
| Atlassian | Login | `site name`, `email`, `api token` |
| Bitbucket Token | API Credential | `credential` |
| GitHub Token | API Credential | `token` |
| SSH Key GitHub | Secure Note | `private_key` (concealed, optional) |
| SSH Key Bitbucket | Secure Note | `private_key` (concealed, optional) |

   The `op` CLI can't set the private key field on SSH Key items, so SSH keys are stored as Secure Notes with a `private_key[concealed]` field. Create them in PowerShell:
   ```powershell
   op item create --vault DevContainer --category="Secure Note" --title="SSH Key Bitbucket" "private_key[concealed]=$(Get-Content -Raw $HOME\.ssh\id_rsa)"
   ```

3. Build the container and open a terminal
4. Run `setup-1password` and follow the prompts:
   ```
   No 1Password account configured.

   How do you sign in to 1Password?
     1) Master password + secret key
     2) SSO (Microsoft, Google, Okta, etc.)

   Choice [1/2]: 1

   Sign-in address: my.1password.eu
   Email: you@example.com
   Secret key: A3-XXXXXX-...

   Adding account and signing in...
   (Enter your master password when prompted)

   Signed in to 1Password!
   Loading credentials from vault 'DevContainer'...
     ANTHROPIC_API_KEY: loaded
     ...
   ```
   If you choose **SSO**, the script explains how to create a service account token instead.
5. On subsequent container starts, just run `setup-1password` again — only your master password is needed

The script only fills in variables that aren't already set — so you can mix sources (e.g. Anthropic key from env var, Atlassian tokens from 1Password).

SSH keys from 1Password are loaded directly into the ssh-agent (never written to disk). The `gh` CLI is authenticated automatically if a GitHub Token exists.

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

Git HTTPS push/pull to Bitbucket is configured automatically from `BITBUCKET_API_TOKEN` (uses `x-bitbucket-api-token-auth` as the git credential username, as [required by Bitbucket scoped tokens](https://support.atlassian.com/bitbucket-cloud/docs/using-api-tokens/)).

Only servers whose credentials are present get added. The config is only generated once — it won't overwrite your edits.

HTTPS (443) is open, so no firewall changes are needed for MCP servers.

## Environment variables

Set these on your host before building the container, or add them to `.env` in the project root (gitignored). They're passed through via `devcontainer.json`. If using 1Password, the credential variables are optional — they'll be pulled from the vault instead.

| Variable | Purpose | Required |
|----------|---------|----------|
| `ANTHROPIC_API_KEY` | Claude Code authentication (alternative: `claude login` OAuth or 1Password) | No* |
| `ATLASSIAN_SITE_NAME` | Confluence/Jira site name (e.g. `mycompany`) | For Confluence/Jira MCP* |
| `ATLASSIAN_USER_EMAIL` | Atlassian account email | For Confluence + Bitbucket* |
| `ATLASSIAN_API_TOKEN` | Classic Atlassian API token ([create here](https://id.atlassian.com/manage-profile/security/api-tokens)) | For Confluence/Jira MCP* |
| `BITBUCKET_API_TOKEN` | Bitbucket scoped API token (Bitbucket → Account settings → Security) | For Bitbucket MCP + git HTTPS* |
| `GITHUB_PERSONAL_ACCESS_TOKEN` | GitHub PAT (for MCP server + git HTTPS + `gh` CLI auth) | For GitHub MCP* |
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

**Claude Code setup:** On container creation, `setup-env.sh` automatically:
- Deploys security hooks from `.claude/hooks/` to `~/.claude/hooks/` (global for all repos in the container)
- Generates `~/.claude/settings.json` with hook registrations (PreToolUse, PostToolUse, PostToolUseFailure)
- Generates `~/.claude/.mcp.json` with MCP server configs (from env vars or 1Password)
- Deploys a global `~/.claude/CLAUDE.md` for container-wide instructions
- Configures git credentials for Bitbucket HTTPS and authenticates the `gh` CLI from tokens

The `cc` alias runs `claude --dangerously-skip-permissions` — safe because the container IS the sandbox.

**Firewall:** Default-DROP iptables policy. HTTPS (443) is open to any domain for research; all other ports are restricted to an allowlist (Anthropic API, npm, CRAN, PyPI, GitHub, etc). Edit `.devcontainer/init-firewall.sh` to add domains.

**Security hooks** are deployed globally inside the container — they apply to every repo you open:

| Hook | Trigger | What it does |
|------|---------|--------------|
| `exfil-guard.sh` | PreToolUse (Bash) | Blocks `curl POST`, `wget --post-data`, `nc`, DNS exfil, etc. |
| `dedup-check.sh` | PreToolUse | Blocks after 3 identical tool calls (loop detection) |
| `injection-scanner.sh` | PostToolUse (WebFetch) | Flags prompt injection patterns in fetched content |
| `failure-reset.sh` | PostToolUse | Resets the failure counter on success |
| `failure-counter.sh` | PostToolUseFailure | Warns after 5 consecutive failures |

Hook source is `.claude/hooks/`. They're copied to `~/.claude/hooks/` on container creation by `setup-env.sh`. Edit hooks in the repo, rebuild to deploy.

**Customization:** To remove languages you don't need (e.g. R), delete the corresponding lines from `.devcontainer/Dockerfile` and rebuild.

## Security model

| Layer | How |
|-------|-----|
| Filesystem | Container only sees `/workspace` (bind mount) + Docker volumes |
| Network | Allowlist firewall, default DROP, HTTPS open for research |
| Exfiltration | Hooks block data-sending commands at the application layer |
| Injection | PostToolUse hook warns on known prompt injection patterns |
| Loop detection | Hooks block repeated commands and track failures |
| Credentials | 1Password (never on disk), SSH via agent forwarding or in-container agent, `.gitconfig` readonly |
| Sudo | Locked down — only `init-firewall.sh` and op config ownership fix allowed |
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
| op config | Docker volume | 1Password CLI account metadata (persists across rebuilds) |

SSH keys are **not** mounted — they're either loaded from 1Password into an in-container agent, or forwarded from the host agent. HTTPS token auth is also supported as an alternative to SSH.

## Platform notes

**Windows:** The `.gitconfig` mount uses `%USERPROFILE%\.gitconfig`. SSH agent forwarding requires the OpenSSH Authentication Agent service (needs admin). If you don't have admin, use 1Password SSH keys (loaded into an in-container agent) or HTTPS token auth instead.

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
