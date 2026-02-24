#!/bin/bash
# PreToolUse hook (Bash): blocks commands that send data to external servers.
# Exit 2 = block the command.

set -uo pipefail

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

[[ "$TOOL_NAME" != "Bash" ]] && exit 0

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
[[ -z "$CMD" ]] && exit 0

# Allow localhost/loopback — local dev server testing is not exfiltration
if echo "$CMD" | grep -qiE '\b(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])\b'; then
    exit 0
fi

# curl/wget data-sending flags (external only — localhost already allowed above)
if echo "$CMD" | grep -qiE '\bcurl\b' && \
   echo "$CMD" | grep -qiE '(-X\s*(POST|PUT|PATCH|DELETE)|-d\b|--data|--form|-F\b|--upload-file)'; then
    echo "BLOCKED: curl with data-sending flags to external host. Use WebFetch for read-only research." >&2
    exit 2
fi

if echo "$CMD" | grep -qiE '\bwget\b' && \
   echo "$CMD" | grep -qiE '(--post-data|--post-file)'; then
    echo "BLOCKED: wget with POST data to external host. Use WebFetch for read-only research." >&2
    exit 2
fi

# Raw socket tools
if echo "$CMD" | grep -qiE '\b(nc|ncat|netcat|socat)\b.*[0-9]{1,3}\.[0-9]{1,3}'; then
    echo "BLOCKED: Raw socket tool targeting an IP address." >&2
    exit 2
fi

# Piping secrets to network commands
if echo "$CMD" | grep -qiE '(cat|echo|printf).{0,40}(env|secret|token|key|password|credential).{0,40}\|\s*(curl|wget|nc|ncat)'; then
    echo "BLOCKED: Piping sensitive data to a network command." >&2
    exit 2
fi

# DNS exfiltration (encoding data in DNS lookups)
if echo "$CMD" | grep -qiE '\b(dig|nslookup|host)\b.{0,20}\$'; then
    echo "BLOCKED: DNS command with variable expansion (possible DNS exfiltration)." >&2
    exit 2
fi

exit 0
