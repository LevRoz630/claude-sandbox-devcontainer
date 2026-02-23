# Claude Code Sandbox Devcontainer

## Project Overview
A devcontainer providing OS-level isolation for running Claude Code with `--dangerously-skip-permissions`. It sandboxes Claude inside a locked-down Ubuntu container with allowlist-only firewall, no sudo escalation, and no host credential leakage.

## Key Directories
- `.devcontainer/` — Dockerfile, firewall init, env setup
- `.claude/hooks/` — Security hook scripts (source of truth, deployed globally on container create)
- `.github/workflows/` — Trivy CI security scanning
- `tests/` — Bash test suites for container, firewall, and hooks

## Stack
- Dockerfile + devcontainer.json (no docker-compose)
- Bash scripts (shellcheck-clean, `set -uo pipefail`)
- iptables/ipset firewall rules
- R 4.x + renv, Node 20, Python 3 + Poetry

## Conventions
- Test scripts use a `pass()`/`fail()`/`skip()` pattern with summary counts
- Firewall allowlist lives in `.devcontainer/init-firewall.sh`
- Hook scripts live in `.claude/hooks/`, deployed to `~/.claude/hooks/` by `setup-env.sh`
- All scripts should use `set -uo pipefail`
- Security is the primary concern — never weaken isolation

## Testing
```bash
bash tests/test-container.sh   # Container validation
bash tests/test-firewall.sh    # Firewall validation (needs firewall active)
bash tests/test-hooks.sh       # Hook unit tests (mock JSON, no API key needed)
```

## Security Invariants (never break these)
- No SSH private keys inside the container — agent forwarding only
- No `NOPASSWD: ALL` sudo — only allowlisted commands
- Firewall default policy is DROP — only allowlisted domains reachable
- Host filesystem not accessible outside /workspace
- Hooks are deployed globally in the container — they apply to all repos

## Competition / Hackathon Workflow

### Context Management (IMPORTANT)
- `/clear` between unrelated tasks — never let Feature A context pollute Feature B
- `/compact <focus>` after exploration and after planning — exploration reads many files that clutter context
- After 2 failed corrections: STOP, `/clear`, rewrite the prompt with what you learned
- Use subagents for investigation — they run in separate context and return summaries
- Monitor with `/cost`

### Rewind & Checkpoints
- Every Claude action creates a checkpoint automatically
- `Esc Esc` or `/rewind` opens checkpoint menu — restore conversation, code, or both
- "Summarize from here" condenses old context while preserving recent work
- Checkpoints persist across sessions — safe to close terminal and resume later
- IMPORTANT: checkpoints only track Claude's changes, not external processes — still commit to git

### Fresh-Context Review (IMPORTANT — do not skip)
- After completing any feature: run `/fresh-review` to get an unbiased review in an isolated context
- Alternative: `Use a subagent with worktree isolation to review the changes in <path>`
- Alternative: open a second terminal with `claude --worktree review`
- Claude reviewing its own code in the same session is biased — a fresh context catches what the builder missed

### Parallel Execution
- Use `claude --worktree <name>` for parallel independent features
- Each worktree gets its own branch and working directory — no conflicts
- For coordinated multi-agent work: `export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`

### Workflow Phases: Explore → Plan → Build → Review → Ship
1. **Explore** (Plan Mode) — read code, understand patterns, use subagents for broad exploration
2. **Plan** — detailed plan, Ctrl+G to edit in editor, then `/compact`
3. **Build** — implement in phases, verify each, run tests
4. **Review** — `/fresh-review` for unbiased review, fix CRITICAL/HIGH issues
5. **Ship** — commit, PR, `/compact` to reset for next task
