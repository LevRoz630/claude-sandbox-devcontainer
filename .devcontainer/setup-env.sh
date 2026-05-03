#!/bin/bash
# Container startup: git config, hooks, credentials, MCP. Runs on every start.
set -euo pipefail
source /usr/local/bin/devcontainer-lib.sh

# Writable git config derived from readonly host mount.
# We copy (not [include]) the host config, stripping [credential] and [url] sections
# that break in-container auth (e.g. 1Password op-plugin hangs, SSH insteadOf rewrites
# bypass HTTPS credential flow). User identity, core, alias, etc. are preserved.
WRITABLE_GITCONFIG="/home/vscode/.gitconfig-local"
if [ ! -f "$WRITABLE_GITCONFIG" ] || grep -q '^\[include\]' "$WRITABLE_GITCONFIG" 2>/dev/null; then
    # (Re)generate: first run or migrating from old [include]-based config
    if [ -f /home/vscode/.gitconfig ]; then
        awk '
        /^\[url /        { skip=1; next }
        /^\[credential/  { skip=1; next }
        /^\[/            { skip=0 }
        !skip            { print }
        ' /home/vscode/.gitconfig > "$WRITABLE_GITCONFIG"
    else
        touch "$WRITABLE_GITCONFIG"
    fi
fi

if ! grep -q "GIT_CONFIG_GLOBAL" /home/vscode/.bashrc 2>/dev/null; then
    echo 'export GIT_CONFIG_GLOBAL="/home/vscode/.gitconfig-local"' >> /home/vscode/.bashrc
fi

# Credentials (1Password or env vars) — tmpfs (RAM-only)
[ -f /run/credentials/op-env ] && source /run/credentials/op-env
[ -f /usr/local/bin/setup-1password.sh ] && source /usr/local/bin/setup-1password.sh || true

# GH_TOKEN for new shells (env var, no file written)
if [ -n "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]; then
    if ! grep -q 'GH_TOKEN' /home/vscode/.bashrc 2>/dev/null; then
        echo 'export GH_TOKEN="${GITHUB_PERSONAL_ACCESS_TOKEN:-}"' >> /home/vscode/.bashrc
    fi
fi

# Deploy hooks globally
mkdir -p /home/vscode/.claude/hooks
if [ -d /workspace/.claude/hooks ] && ls /workspace/.claude/hooks/*.sh >/dev/null 2>&1; then
    cp /workspace/.claude/hooks/*.sh /home/vscode/.claude/hooks/
    chmod +x /home/vscode/.claude/hooks/*.sh
fi

# Hooks template — baseline hook config for this container
cat > /tmp/hooks-template.json << 'TEMPLATE'
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [{"type": "command", "command": "bash ~/.claude/hooks/learning-mode.sh"}]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "bash ~/.claude/hooks/exfil-guard.sh"}]
      },
      {
        "matcher": "Edit|Write",
        "hooks": [{"type": "command", "command": "bash ~/.claude/hooks/plan-gate.sh"}]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "WebFetch",
        "hooks": [{"type": "command", "command": "bash ~/.claude/hooks/injection-scanner.sh"}]
      },
      {
        "matcher": "",
        "hooks": [{"type": "command", "command": "bash ~/.claude/hooks/failure-reset.sh"}]
      }
    ],
    "PostToolUseFailure": [
      {
        "matcher": "",
        "hooks": [{"type": "command", "command": "bash ~/.claude/hooks/failure-counter.sh"}]
      }
    ],
    "Stop": []
  }
}
TEMPLATE

if [ ! -f /home/vscode/.claude/settings.json ]; then
    # First run: use template as-is
    cp /tmp/hooks-template.json /home/vscode/.claude/settings.json
else
    # Merge: fill in any missing hook events from template, preserve existing ones
    jq -s '.[1].hooks as $template | .[0] | .hooks = ($template + .hooks)' \
        /home/vscode/.claude/settings.json /tmp/hooks-template.json > /tmp/settings-merged.json \
        && mv /tmp/settings-merged.json /home/vscode/.claude/settings.json
fi
rm -f /tmp/hooks-template.json

# Fix auto-updates: Dockerfile installs via npm, not native installer
CLAUDE_JSON="/home/vscode/.claude/.claude.json"
if [ -f "$CLAUDE_JSON" ]; then
    python3 -c "
import json, sys
with open('$CLAUDE_JSON') as f: d = json.load(f)
changed = False
if d.get('installMethod') != 'npm':
    d['installMethod'] = 'npm'; changed = True
if d.get('autoUpdates') != True:
    d['autoUpdates'] = True; changed = True
if changed:
    with open('$CLAUDE_JSON', 'w') as f: json.dump(d, f, indent=2)
    print('Claude auto-update config patched')
"
fi

# MCP servers, git credentials, gh auth
source /usr/local/bin/setup-credentials.sh
setup_post_credentials

if [ ! -f /home/vscode/.claude/CLAUDE.md ]; then
    cat > /home/vscode/.claude/CLAUDE.md << 'CLAUDEMD'
# Global Container Instructions

- Markdown/documentation files (*.md) may be created or edited when explicitly requested
- Never add Co-Authored-By lines to git commits

## Interaction Style — Pedagogical Mode

- NEVER write code before a plan exists. Every task starts with questions and discussion.
- Ask ONE question at a time. Do not bundle multiple questions in one message.
- When multiple approaches exist, present options with trade-offs — do not choose for me.
- Default to Plan Mode thinking: explore, discuss, propose, then implement.
- For non-trivial logic (algorithms, business rules, error handling, data modeling),
  explain trade-offs and insert TODO(human) for me to write.
- After writing code, provide a brief Insight explaining WHY you made the choices you did.
- If I ask "why", point me to relevant files/docs rather than explaining directly.
- Never implement more than one plan step without checking in.
- Keep responses concise — no walls of text. If it takes more than a short paragraph, break it into a conversation.

## Response Length

Default to brevity. Match length to actual question complexity:

- Simple lookup, definition, or yes/no: 1-2 sentences.
- Explanation, reasoning, or recommendation: 2-3 sentences per distinct point, 3 points maximum unless I ask for more.
- Drafts, code, documents, multi-part analysis: use the length the task genuinely requires.

Lead with the answer. Cut preamble, question-restating, and closing recaps of what you just said. If you catch yourself adding caveats, alternatives, or "related context" I didn't ask for, stop and delete them - I'll ask follow-ups if I want them.

## Debugging — Root Cause First

- NO fixes without root cause investigation. Read errors, reproduce, trace data flow.
- Phase 1: Evidence (error messages, stack traces, recent changes, data flow tracing)
- Phase 2: Pattern analysis (find working examples, compare differences)
- Phase 3: Single hypothesis, test one variable at a time
- Phase 4: Implement fix, verify without breaking other tests
- After 3 failed fix attempts: STOP. Do not attempt fix #4 — discuss architecture with me.
- Red flags (stop immediately): "quick fix for now", "just try changing X", multiple changes at once.

## Verification — No Claims Without Evidence

- Never claim work is complete without running verification commands in the current session.
- Gate: identify the proving command → run it fresh → read full output → confirm it matches the claim → only then state completion.
- Red flags: "should work", "probably fine", "done!" before running anything, trusting agent reports without independent verification.
- Applies before: any success claim, commits, PRs, marking tasks complete.

## Parallel Agents — Two-Stage Review

- When dispatching subagents for plan tasks, use two-stage review:
  1. Spec compliance — does the output match the plan/requirements?
  2. Code quality — is it clean, safe, and maintainable?
- Do not merge subagent output that fails either stage.

## Code Review — Review Against the Plan

- When reviewing code (own or subagent), review against the original plan/spec, not just general quality.
- Check: does every plan requirement have a corresponding implementation?
- Check: are there implementations that weren't in the plan (scope creep)?
- Use `/fresh-review` or `claude --worktree review` for unbiased review in isolated context.
CLAUDEMD
fi

git config --global --add safe.directory /workspace

# Container credential helper: gh CLI (host's op-plugin/VS Code helpers were stripped
# during gitconfig copy above; this ensures gh is always set even after rebuilds)
git config --global credential.helper '!/usr/bin/gh auth git-credential'

if ! grep -q "HISTFILE=/commandhistory/.bash_history" /home/vscode/.bashrc 2>/dev/null; then
    echo 'export PROMPT_COMMAND="history -a"' >> /home/vscode/.bashrc
    echo 'export HISTFILE=/commandhistory/.bash_history' >> /home/vscode/.bashrc
fi

# Startup summary
CRED_COUNT=0
CRED_TOTAL=${#CREDENTIAL_VARS[@]}
for var in "${CREDENTIAL_VARS[@]}"; do
    [ -n "${!var:-}" ] && CRED_COUNT=$((CRED_COUNT + 1))
done

API_STATUS="set"
[ -z "${ANTHROPIC_API_KEY:-}" ] && API_STATUS="NOT SET"

echo ""
echo "Claude Sandbox ready | API: ${API_STATUS} | Creds: ${CRED_COUNT}/${CRED_TOTAL} | MCP:${MCP_SERVERS:- none}"
echo ""
echo "  Recommended plugins (run inside Claude Code):"
echo "    /plugin install claude-md-management@claude-plugins-official"
echo "    /plugin install claude-code-setup@claude-plugins-official"
echo "    /plugin install hookify@claude-plugins-official"
echo "  Language servers: pyright-lsp, typescript-lsp, ruby-lsp, rust-analyzer-lsp"
echo "  Development: code-simplifier, security-guidance"
