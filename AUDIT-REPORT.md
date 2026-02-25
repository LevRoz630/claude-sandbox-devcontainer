# Claude Code Sandbox — Audit Report

**Date:** 2026-02-25
**Branch:** master (commit 7026b18)
**Agents:** test-runner, security-auditor, docker-reviewer

---

## 1. Test Results

| Suite | Pass | Fail | Skip | Exit Code | Notes |
|---|---|---|---|---|---|
| test-container.sh | 46 | 1 | 0 | 1 | GitHub OAuth token in hosts.yml |
| test-hooks.sh | 43 | 0 | 0 | 0 | All 5 hooks passing |
| test-firewall.sh | 16 | 0 | 1 | 0 | DNS filtering skipped (Quad9 not set as resolver) |
| **TOTAL** | **105** | **1** | **1** | — | — |

### Failure Detail

**FAIL: GitHub OAuth token found in hosts.yml** (test-container.sh §5)

`gh auth login --with-token` in `setup-credentials.sh:44` writes a plaintext token to the persistent Docker volume at `/home/vscode/.config/gh/hosts.yml`. This violates the "no plaintext secrets on disk" invariant.

**Fix:** Use `GH_TOKEN` environment variable instead of `gh auth login`. The `gh` CLI honors `GH_TOKEN` without writing to disk.

---

## 2. Security Findings

### HIGH: Credentials written to disk in plaintext

Three files store secrets as plaintext on persistent Docker volumes:

| File | Written by | Contains |
|---|---|---|
| `~/.op-credentials` | `setup-1password.sh:107-114` | All 6 API keys/tokens as `export VAR=value` |
| `~/.git-credentials` | `setup-credentials.sh:34-38` | Bitbucket token in URL format |
| `~/.config/gh/hosts.yml` | `gh auth login` (setup-credentials.sh:44) | GitHub PAT |

All have `chmod 600` but are plaintext on persistent volumes, violating invariant #2: "No plaintext secrets on disk."

**Fix:**
- `gh` → export `GH_TOKEN` env var instead of `gh auth login` (no file written)
- `git` → use `git credential-cache` (in-memory daemon) instead of `git credential-store` (file)
- `.op-credentials` → write to a tmpfs mount (RAM-only, vanishes on stop) instead of home dir

### HIGH: `postStartCommand` silently swallows firewall failures

`devcontainer.json:76`:
```
sudo init-firewall.sh && bash setup-env.sh || true
```

Shell precedence: `(A && B) || true`. If `init-firewall.sh` fails (iptables missing, GitHub API down, bad DNS), `&&` short-circuits, `|| true` catches it, exit 0. The container starts **with no firewall and no error**. The user thinks they're protected.

**Fix:** Make firewall mandatory, let env setup fail gracefully:
```
sudo /usr/local/bin/init-firewall.sh && (bash /usr/local/bin/setup-env.sh || true)
```

### MEDIUM: IPv6 not addressed by firewall

`init-firewall.sh` only configures `iptables` (IPv4). No `ip6tables` rules exist. The kernel default IPv6 policy is ACCEPT. If Docker's network has IPv6, all IPv6 traffic flows freely — bypassing every firewall rule.

**Fix:** Add to `init-firewall.sh`:
```bash
ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT DROP
ip6tables -A INPUT -i lo -j ACCEPT
ip6tables -A OUTPUT -o lo -j ACCEPT
```

### MEDIUM: `setup-env.sh` uses `set -e` instead of `set -euo pipefail`

Inconsistent with project convention. Unset variables silently expand to empty strings; pipe failures are swallowed.

**Fix:** Change to `set -euo pipefail`.

### MEDIUM: Hook state files world-readable in /tmp

`dedup-check.sh:21`, `failure-counter.sh:11` — State dirs created with default umask. Any process in the container can read/modify/delete counters.

**Fix:** `mkdir -p -m 700 "$STATE_DIR"`

### LOW: Exfil-guard has known bypass vectors

The hook only inspects for `curl`/`wget`/`nc` patterns. Runtimes like `python3 -c`, `node -e`, bash `/dev/tcp` can bypass it. This is an inherent limitation of regex-based command inspection.

**Accepted:** The exfil-guard is a heuristic defence-in-depth layer, not a security boundary. The firewall provides network-level control. Document the limitation.

### By Design: HTTPS (port 443) open to all destinations

`init-firewall.sh:34` allows outbound HTTPS to any IP. This is intentional — the container is for research and needs unrestricted HTTPS access. The exfil-guard hooks and injection scanner provide the appropriate controls at this layer.

---

## 3. Docker Best Practices Findings

### No `.dockerignore` file

No `.dockerignore` exists. CI builds with `context: .devcontainer` (just that dir), so CI is fine. But local builds from the repo root send the entire workspace — `.git/`, `.env` files, everything — to the Docker daemon as build context.

**Fix:** Add `.devcontainer/.dockerignore`:
```
*
!Dockerfile
!*.sh
```

### `CLAUDE_CODE_VERSION=latest` defeats reproducibility

`Dockerfile:6`, `devcontainer.json:7` — every build gets an unpredictable Claude Code version. A breaking change upstream silently breaks the container. No way to roll back.

**Fix:** Pin to a specific version in `devcontainer.json` and `trivy.yml`.

### Base image not pinned to digest

`Dockerfile:1` — `FROM mcr.microsoft.com/devcontainers/base:noble` is a floating tag. Microsoft updates it whenever they want. Rebuilding the same Dockerfile on different days produces different images.

**Fix:** Pin to `@sha256:<digest>` with a comment documenting when it was pinned.

### CI actions use floating major tags

`trivy.yml` — `actions/checkout@v4`, `docker/setup-buildx-action@v3`, etc. Major tags can be force-pushed by upstream to point at new commits.

**Fix:** Pin to full SHA hashes with version comments.

### Unpinned tool versions

Poetry, renv, 1Password CLI, and Node.js patch versions are all unpinned.

**Fix:** Add explicit version constraints when next updating each tool.

### Git-delta downloaded without checksum verification

`Dockerfile:46-49` — `.deb` downloaded via wget and installed without integrity check.

**Fix:** Add SHA256 verification after download.

### Missing OCI labels and HEALTHCHECK

Minor. Add `LABEL` instructions for image metadata and a basic health check.

---

## 4. Test Coverage Gaps

### Critical gaps
- **Missing test cases for socat/netcat, curl PATCH/DELETE** — patterns exist in exfil-guard but are untested
- **Hex-encoded payload and HTML comment injection patterns** in injection-scanner untested
- **1Password CLI (`op`)** not checked in tool availability tests

### Missing test suites
- `setup-env.sh`, `setup-credentials.sh`, `setup-1password.sh`, `sandbox-status.sh` have zero test coverage
- `init-firewall.sh` logic (error handling, FIREWALL_EXTRA_DOMAINS, DNS modes) only tested behaviorally

### Test quality
- Exit codes should be captured immediately (`rc=$?`) rather than relying on `$?` surviving
- Firewall localhost test has a race condition (`sleep 1` instead of retry loop)

---

## 5. Positive Findings

Both auditors highlighted strong security practices:

- **Fail-closed firewall** with self-test on startup
- **Sudoers lockdown** — base image's `NOPASSWD: ALL` explicitly removed
- **No secrets in Docker image layers** — all credentials injected at runtime
- **SSH keys never touch disk** — loaded directly into agent via `op read | ssh-add -`
- **Readonly `.gitconfig` mount** — host config protected from container writes
- **Comprehensive CI scanning** — Trivy: image vulns, misconfigs, licenses, secrets
- **Idempotent startup scripts** with graceful degradation
- **apt-get clean + `--no-install-recommends`** in every layer
- **Hook corruption handling** — state files validated for numeric content

---

## 6. Prioritized Remediation

| Priority | Issue | Effort |
|---|---|---|
| **P0** | Fix `postStartCommand` to not swallow firewall failures | Trivial |
| **P0** | Eliminate plaintext credential files (GH_TOKEN, credential-cache, tmpfs) | Small |
| **P1** | Add IPv6 DROP rules | Trivial |
| **P1** | Fix `setup-env.sh` to use `set -euo pipefail` | Trivial |
| **P1** | Hook state dir permissions (`mkdir -m 700`) | Trivial |
| **P2** | Add `.dockerignore` | Trivial |
| **P2** | Pin `CLAUDE_CODE_VERSION` to specific version | Trivial |
| **P2** | Pin base image to digest | Trivial |
| **P2** | Pin CI actions to SHA | Small |
| **P3** | Add missing exfil-guard test cases (socat, PATCH/DELETE) | Small |
| **P3** | Add missing injection-scanner test cases | Small |
| **P3** | Pin Poetry, renv, 1Password CLI versions | Small |
| **P3** | Add git-delta checksum verification | Small |
| **P3** | Add OCI labels and HEALTHCHECK | Trivial |
