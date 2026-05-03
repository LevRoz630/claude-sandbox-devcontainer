#!/bin/bash
# PreToolUse hook (Edit|Write): blocks code file writes until plan.md exists.
# Ensures a planning conversation happens before any implementation.
# Non-code files (markdown, config, data) are always allowed UNLESS they're
# config-shaped files that actually execute shell (Dockerfile, GH Actions, etc.) —
# those are force-planned via the danger list below.
# Exit 2 = block the command.

set -uo pipefail

INPUT=$(cat)
if ! echo "$INPUT" | jq -e . >/dev/null 2>&1; then exit 0; fi

TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Only gate Edit and Write
[[ "$TOOL" != "Edit" && "$TOOL" != "Write" ]] && exit 0
[[ -z "$FILE" ]] && exit 0

EXT="${FILE##*.}"
EXT=$(echo "$EXT" | tr '[:upper:]' '[:lower:]')
BASE=$(basename "$FILE")

require_plan() {
    if [[ ! -f "plan.md" ]]; then
        echo "BLOCKED: No plan.md in $(pwd). Discuss and write a plan before coding." >&2
        exit 2
    fi
    exit 0
}

# Force-plan: config-shaped files that execute shell. Overrides allowlists below.
case "$BASE" in
    Dockerfile|Dockerfile.*|Makefile|GNUmakefile|*.mk|Procfile|.envrc|\
    devcontainer.json|pyproject.toml|pom.xml|build.xml)
        require_plan ;;
esac
case "$FILE" in
    .claude/settings.json|*/.claude/settings.json|\
    .claude/settings.local.json|*/.claude/settings.local.json|\
    .claude/hooks/*|*/.claude/hooks/*|\
    .github/workflows/*.yml|*/.github/workflows/*.yml|\
    .github/workflows/*.yaml|*/.github/workflows/*.yaml|\
    .github/actions/*/action.yml|*/.github/actions/*/action.yml|\
    .github/actions/*/action.yaml|*/.github/actions/*/action.yaml)
        require_plan ;;
esac

# Allowlist: non-code files that never need the plan gate
case "$EXT" in
    md|txt|rst|adoc)                          exit 0 ;;
    json|yaml|yml|toml|xml|ini|cfg|conf)      exit 0 ;;
    csv|tsv)                                  exit 0 ;;
    lock|sum)                                 exit 0 ;;
esac

# Allow dotfiles and meta files by name
case "$BASE" in
    .gitignore|.gitattributes|.editorconfig)  exit 0 ;;
    .env.example)                             exit 0 ;;
esac

# Everything else is treated as code — require plan.md
require_plan
