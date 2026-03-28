# Network Policy

HTTPS (443) is open broadly so Claude can research anything. Exfiltration over HTTPS is blocked at the application layer by the exfil-guard hook — it catches `curl -d`, `wget --post-data`, `nc`, and DNS exfiltration attempts. Non-HTTPS traffic is limited to the allowlist.

## Allowlisted domains

The firewall (`init-firewall.sh`) allows non-HTTPS traffic to these domains:

- `api.anthropic.com`, `statsig.anthropic.com`, `sentry.io` (Claude Code)
- `registry.npmjs.org` (npm)
- `cloud.r-project.org`, `packagemanager.posit.co` (R/CRAN)
- `pypi.org`, `files.pythonhosted.org` (Python)
- `github.com`, `bitbucket.org` (git)
- `my.1password.com`, `my.1password.eu`, `my.1password.ca`, `cache.agilebits.com` (1Password)
- VS Code update servers

To add custom non-HTTPS domains, set `FIREWALL_EXTRA_DOMAINS` on the host (space-separated list). They'll be resolved and added to the allowlist on container start.

## DNS filtering

By default, the container auto-detects whether it can reach Quad9 (9.9.9.9). If reachable, the system resolver (`/etc/resolv.conf`) is pointed at Quad9 and a DNAT rule redirects any explicit external DNS queries there too — so all DNS resolution goes through Quad9's malware/phishing/C2 blocklist. If unreachable (e.g., corporate network blocking external DNS), filtering is skipped and the network's default DNS is used.

Override with `DNS_FILTER_PRIMARY`:
- Unset (default): auto-detect
- `9.9.9.9`: always use Quad9
- `1.1.1.2`: use Cloudflare malware filtering
- `none`: disable DNS filtering
