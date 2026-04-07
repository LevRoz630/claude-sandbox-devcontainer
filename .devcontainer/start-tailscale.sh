#!/bin/bash
set -uo pipefail

# Start tailscaled daemon in userspace networking mode (no /dev/net/tun needed).
# State is persisted via Docker volume at /var/lib/tailscale.
# Must run as root (via sudo allowlist).

SOCK="/var/run/tailscale/tailscaled.sock"
STATE="/var/lib/tailscale/tailscaled.state"
LOG="/tmp/tailscaled.log"

# Create socket directory
mkdir -p "$(dirname "$SOCK")"

# Skip if already running
if [ -S "$SOCK" ] && tailscale status &>/dev/null; then
    echo "tailscaled already running"
    exit 0
fi

# Start daemon in background
tailscaled \
    --tun=userspace-networking \
    --state="$STATE" \
    --socket="$SOCK" \
    &>"$LOG" &

# Wait for socket to appear
for i in $(seq 1 30); do
    [ -S "$SOCK" ] && break
    sleep 0.2
done

if [ ! -S "$SOCK" ]; then
    echo "ERROR: tailscaled failed to start (check $LOG)" >&2
    exit 1
fi

echo "tailscaled started (userspace networking, log: $LOG)"
echo "Run 'sudo tailscale up' to authenticate"
