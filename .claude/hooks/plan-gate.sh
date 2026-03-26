#!/bin/bash
# PreToolUse hook (Edit|Write): blocks code file writes until plan.md exists.
# Ensures a planning conversation happens before any implementation.
# Non-code files (markdown, config, data) are always allowed.
# Exit 2 = block the command.

set -uo pipefail

INPUT=$(cat)
if ! echo "$INPUT" | jq -e . >/dev/null 2>&1; then exit 0; fi

TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Only gate Edit and Write
[[ "$TOOL" != "Edit" && "$TOOL" != "Write" ]] && exit 0
[[ -z "$FILE" ]] && exit 0

# Extract extension (lowercase) and basename
EXT="${FILE##*.}"
EXT=$(echo "$EXT" | tr '[:upper:]' '[:lower:]')
BASE=$(basename "$FILE")

# Allowlist: non-code files that never need the plan gate
case "$EXT" in
    # Documentation
    md|txt|rst|adoc)                          exit 0 ;;
    # Config
    json|yaml|yml|toml|xml|ini|cfg|conf)      exit 0 ;;
    # Data
    csv|tsv)                                  exit 0 ;;
    # Lock files
    lock|sum)                                 exit 0 ;;
esac

# Allow dotfiles and meta files by name
case "$BASE" in
    .gitignore|.gitattributes|.editorconfig)  exit 0 ;;
    .env.example|.envrc)                      exit 0 ;;
    Makefile|Dockerfile|Procfile)              exit 0 ;;
esac

# Everything else is treated as code — require plan.md
if [[ ! -f "plan.md" ]]; then
    echo "BLOCKED: No plan.md in $(pwd). Discuss and write a plan before coding." >&2
    exit 2
fi

exit 0
