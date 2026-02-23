#!/bin/bash
# =============================================================================
# PreToolUse hook: Exfiltration guard
#
# Blocks Bash commands that could send data to external servers.
# Since HTTPS (443) is now open for research, this hook prevents the agent
# from using that open channel to POST/PUT secrets out.
#
# Hook event: PreToolUse (matcher: Bash)
# Exit 2 = block the command, stderr fed back to Claude.
# =============================================================================

set -uo pipefail

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

[[ "$TOOL_NAME" != "Bash" ]] && exit 0

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
[[ -z "$CMD" ]] && exit 0

# --- Block curl/wget data-sending flags ---
# curl: -X POST/PUT/PATCH/DELETE, -d/--data, --data-*, -F/--form, --upload-file
if echo "$CMD" | grep -qiE '\bcurl\b' && \
   echo "$CMD" | grep -qiE '(-X\s*(POST|PUT|PATCH|DELETE)|-d\b|--data|--form|-F\b|--upload-file)'; then
    echo "BLOCKED: curl with data-sending flags. Use WebFetch for read-only research." >&2
    exit 2
fi

# wget: --post-data, --post-file
if echo "$CMD" | grep -qiE '\bwget\b' && \
   echo "$CMD" | grep -qiE '(--post-data|--post-file)'; then
    echo "BLOCKED: wget with POST data. Use WebFetch for read-only research." >&2
    exit 2
fi

# --- Block raw socket tools (data exfiltration channels) ---
if echo "$CMD" | grep -qiE '\b(nc|ncat|netcat|socat)\b.*[0-9]{1,3}\.[0-9]{1,3}'; then
    echo "BLOCKED: Raw socket tool targeting an IP address." >&2
    exit 2
fi

# --- Block piping secrets to network commands ---
if echo "$CMD" | grep -qiE '(cat|echo|printf).{0,40}(env|secret|token|key|password|credential).{0,40}\|\s*(curl|wget|nc|ncat)'; then
    echo "BLOCKED: Piping sensitive data to a network command." >&2
    exit 2
fi

# --- Block DNS exfiltration (encoding data in DNS lookups) ---
if echo "$CMD" | grep -qiE '\b(dig|nslookup|host)\b.{0,20}\$'; then
    echo "BLOCKED: DNS command with variable expansion (possible DNS exfiltration)." >&2
    exit 2
fi

exit 0
