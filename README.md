# Claude Code Sandbox

A devcontainer for running [Claude Code](https://docs.anthropic.com/en/docs/claude-code) with `--dangerously-skip-permissions`. The container is the sandbox: allowlist firewall, no host credentials, locked-down sudo, and application-layer hooks that catch exfiltration and prompt injection. You get full autonomous Claude without permission prompts slowing you down, and without worrying about what it might do to your machine.

The other half is a learning mode. Hooks and a global `CLAUDE.md` enforce a workflow where Claude has to plan before coding, explain its choices after, check in between steps, and stop when it's stuck instead of trying the same fix six times. You stay in the loop and build understanding of what's being built, rather than watching code appear.

## How the sandbox works

The firewall (`init-firewall.sh`) sets a default-DROP iptables policy. HTTPS is open on port 443 so Claude can research anything, but all other traffic is restricted to an allowlist of known domains (Anthropic API, npm, PyPI, GitHub, etc). See [docs/network-policy.md](docs/network-policy.md) for the full allowlist and DNS filtering config.

Credentials never touch the filesystem as plaintext. API keys come from environment variables (in-memory), 1Password (loaded at runtime, never written to disk), or OAuth login. SSH keys are either forwarded from the host agent or loaded from 1Password directly into an in-container ssh-agent. The `.gitconfig` is mounted read-only with credential and URL-rewrite sections stripped on startup — so 1Password browser plugins and SSH `insteadOf` rules from the host don't leak into the container.

Sudo is locked down to two commands: running the firewall script and fixing 1Password config permissions. No `NOPASSWD: ALL`.

On top of the OS-level isolation, five hooks run inside Claude Code itself. `exfil-guard.sh` blocks outbound data commands (`curl -d`, `wget --post-data`, `nc`) to external hosts while allowing localhost for dev testing. `injection-scanner.sh` scans content fetched by WebFetch for known prompt injection patterns and warns (advisory only, doesn't block). `dedup-check.sh` stops Claude after 5 identical tool calls, forcing it to try something different. `failure-counter.sh` warns after 5 consecutive failures, and `failure-reset.sh` clears that counter on success.

These hooks live in `.claude/hooks/` and get copied to `~/.claude/hooks/` on every container start, so they apply to every repo you open in the container.

## How the learning mode works

`plan-gate.sh` blocks any file writes (Edit, Write tools) until a `plan.md` exists in the working directory. Claude has to discuss the approach with you before it can touch code.

At session start, `learning-mode.sh` injects instructions into Claude's context: ask one question at a time, present trade-offs instead of choosing, insert `TODO(human)` markers for non-trivial logic, explain why after writing code. These rules also live in the global `CLAUDE.md` that `setup-env.sh` deploys to `~/.claude/CLAUDE.md`.

The failure hooks reinforce this. After 5 consecutive failures, `failure-counter.sh` tells Claude to stop and discuss architecture, preventing the "try random things until something works" pattern.

## Getting started

You need Docker Desktop (or Podman/Rancher Desktop), VS Code with the [Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) extension, and git configured with `user.name`/`user.email` in `~/.gitconfig`.

1. Clone this repo (or copy `.devcontainer/` and `.claude/` into your own project)
2. Create a `.env` file in the project root with your credentials (see [docs/setup-credentials.md](docs/setup-credentials.md))
3. Open in VS Code → Command Palette → **Dev Containers: Reopen in Container**
4. Run `cc` (alias for `claude --dangerously-skip-permissions`)
5. Verify: `bash tests/test-container.sh`

For CLI without VS Code:

```bash
set -a && source .env && set +a
devcontainer up --workspace-folder .
devcontainer exec --workspace-folder . bash
```

## Credentials

Three sources, checked in order: environment variables, 1Password, manual login. If a variable is already set, 1Password won't override it. Full details in [docs/setup-credentials.md](docs/setup-credentials.md).

## MCP servers

MCP servers are configured automatically from env vars on container start. Only servers whose credentials are present get registered.

| Server | Required env vars |
|--------|-------------------|
| Confluence | `ATLASSIAN_SITE_NAME`, `ATLASSIAN_USER_EMAIL`, `ATLASSIAN_API_TOKEN` |
| Jira | `ATLASSIAN_SITE_NAME`, `ATLASSIAN_USER_EMAIL`, `ATLASSIAN_API_TOKEN` |
| Bitbucket | `ATLASSIAN_USER_EMAIL`, `BITBUCKET_API_TOKEN` |
| GitHub | `GITHUB_PERSONAL_ACCESS_TOKEN` |
| Context7 | (none, always added) |

Confluence and Bitbucket use separate tokens — Atlassian has different token systems per product. Confluence uses a classic API token from [id.atlassian.com](https://id.atlassian.com/manage-profile/security/api-tokens). Bitbucket uses a scoped API token from Bitbucket → Account settings → Security → API tokens.

## Platform notes

**Windows:** The `.gitconfig` mount uses `%USERPROFILE%\.gitconfig`. SSH agent forwarding requires the OpenSSH Authentication Agent service (needs admin). Without admin, use 1Password SSH keys or HTTPS token auth.

**Mac/Linux:** Change the `.gitconfig` mount in `devcontainer.json` from `source=${localEnv:USERPROFILE}\\.gitconfig` to `source=${localEnv:HOME}/.gitconfig`. SSH agent forwarding works out of the box.

## Testing

```bash
bash tests/test-container.sh   # environment, tools, credential isolation
bash tests/test-firewall.sh    # firewall rules (needs firewall active)
bash tests/test-hooks.sh       # all 5 hooks with mock JSON input
bash tests/test-gitconfig.sh   # gitconfig sanitization
bash tests/test-clone-repos.sh # repo cloning utility
```

The container ships with R 4.x (renv), Node 20, Python 3 (Poetry), Claude Code, gh CLI, git-delta, jq, and fzf. To remove languages you don't need, delete the relevant lines from the Dockerfile.

## More

- [Credential and environment setup](docs/setup-credentials.md)
- [Network policy and firewall](docs/network-policy.md)
- [Open issues / roadmap](https://github.com/LevRoz630/claude-sandbox-devcontainer/issues)
