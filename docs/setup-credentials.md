# Credentials and Environment Setup

Credentials (API keys, tokens) can come from three sources. The container checks them in this order:

1. Environment variables set on the host or in a `.env` file (gitignored). Passed through via `devcontainer.json containerEnv`. If a variable is already set, 1Password won't override it.
2. 1Password — the `op` CLI is installed in the container. If configured, it fills in any credentials that aren't already set from env vars.
3. Manual login — run `claude login`, `gh auth login`, etc. inside the container.

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
- `.env` file (recommended): Create `.env` in the project root and fill in values — it's gitignored.
- 1Password: See below — no env vars needed for credentials.
- Windows: System Properties → Environment Variables, or `setx VAR value`.
- Mac/Linux: Add `export VAR=value` to `~/.bashrc` or `~/.zshrc`.

## 1Password setup

The container ships with the [1Password CLI](https://developer.1password.com/docs/cli/) pre-installed. Two auth modes:

**Service account (headless / CI / SSO accounts):** Set `OP_SERVICE_ACCOUNT_TOKEN` on the host. Authentication is automatic, no interaction needed. This is the only option for SSO accounts (Microsoft, Google, Okta) because SSO signin requires the 1Password desktop app, which isn't available inside the container. Create a service account at your 1Password admin console → Integrations → [Service Accounts](https://developer.1password.com/docs/service-accounts/get-started/).

**Interactive (master-password accounts):** Open a terminal in the container and run `setup-1password`. The command walks you through setup:

- First time: Prompts for auth method (master password vs SSO), then guided `op account add` with sign-in address, email, secret key, and master password.
- Subsequent starts: Prompts only for your master password (account config persists in a Docker volume).
- During container build (non-interactive): Exits gracefully with a reminder to run `setup-1password` in a terminal.

Account metadata is stored in a Docker volume (`~/.config/op` inside the container), so it survives container rebuilds.

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
   If you choose SSO, the script explains how to create a service account token instead.
5. On subsequent container starts, just run `setup-1password` again — only your master password is needed.

The script only fills in variables that aren't already set, so you can mix sources (e.g. Anthropic key from env var, Atlassian tokens from 1Password).

SSH keys from 1Password are loaded directly into the ssh-agent (never written to disk). The `gh` CLI is authenticated automatically if a GitHub Token exists.

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

SSH keys are not mounted. They're either loaded from 1Password into an in-container agent, or forwarded from the host agent. HTTPS token auth is also supported as an alternative to SSH.
