# Loop Detection & Circuit Breaking: Design Notes

## Problem

Claude Code in autonomous mode (`--dangerously-skip-permissions`) can enter loops where it:
- Re-runs the same failing command hoping for a different result
- Alternates between two approaches without converging
- Makes no meaningful file changes across many iterations
- Burns through tokens/cost without progress

Without intervention, a loop on Opus can cost $50-200+ before the user notices.

---

## Prior Art: Ralph

**Repo**: [frankbria/ralph-claude-code](https://github.com/frankbria/ralph-claude-code)

Ralph is a **bash wrapper** around the `claude` CLI (not a hooks-based system). It runs Claude in a `while true` loop with safety gates between each full invocation.

### How Ralph Works

Each iteration runs 8 steps:
1. Check hourly rate limit (default 100 calls/hour)
2. Check circuit breaker state
3. Check exit/completion conditions
4. Execute `claude` with 15-min timeout
5. Analyze response for errors/signals
6. Update rolling exit-signal windows
7. Record result in circuit breaker
8. Write `status.json` for monitoring

### Ralph's Circuit Breaker

Three-state machine (`CLOSED -> HALF_OPEN -> OPEN`):

| Transition | Condition |
|------------|-----------|
| CLOSED -> HALF_OPEN | 2+ loops with no file changes (`git diff --name-only`) |
| HALF_OPEN -> OPEN | 3+ consecutive loops with no progress |
| OPEN -> CLOSED | Manual reset only (`ralph --reset-circuit`) |

### Ralph's Exit Detection

Dual-condition gate requiring ANY of:
- 3 consecutive test-only loops
- 2 done-signal detections ("complete", "finished")
- All tasks in `fix_plan.md` marked done
- Explicit "DONE"/"EXIT" in output
- Confidence score >= 40

### Ralph's Limitations

- **Coarse granularity**: Can only see full session output, not individual tool calls
- **External orchestration**: Must restart Claude each iteration (loses context)
- **No pre-emptive blocking**: Can't stop a bad tool call before it executes
- **Session continuity**: Uses `--continue` to resume, but context grows unbounded

---

## Claude Code Hooks: The Alternative

Hooks are the native extension mechanism. They fire on specific events and can block actions in real-time.

### Relevant Hook Events

| Event | When | Can Block? | Use For |
|-------|------|------------|---------|
| `PreToolUse` | Before any tool call | Yes (deny) | Command dedup, input validation |
| `PostToolUse` | After successful tool call | No (feedback) | Progress tracking, state logging |
| `PostToolUseFailure` | After failed tool call | No (feedback) | Failure counting |
| `Stop` | Claude tries to finish | Yes (continue) | Completion validation |
| `UserPromptSubmit` | User sends a prompt | Yes (block) | Budget enforcement |
| `SessionStart` | Session begins | No | State initialization |

### Hook Input Data

Every hook receives via stdin:
```json
{
  "session_id": "abc123",
  "transcript_path": "/path/to/.claude/projects/.../transcript.jsonl",
  "cwd": "/workspace/my-project",
  "hook_event_name": "PreToolUse"
}
```

`PreToolUse` adds:
```json
{
  "tool_name": "Bash",
  "tool_input": {"command": "npm test"},
  "tool_use_id": "toolu_01ABC..."
}
```

`PostToolUseFailure` adds:
```json
{
  "tool_name": "Bash",
  "tool_input": {"command": "npm test"},
  "error": "Command exited with non-zero status code 1"
}
```

### Hook Output Control

From a `PreToolUse` hook:
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "Loop detected: same command 3 times",
    "additionalContext": "Try a different approach - this command has failed repeatedly."
  }
}
```

From a `Stop` hook:
```json
{
  "decision": "block",
  "reason": "No file changes detected in last 5 tool calls. Verify your work."
}
```

Exit codes: 0 = success (parse stdout JSON), 2 = blocking error (stderr shown).

### Critical: Stop Hook Infinite Loop Prevention

When a Stop hook blocks, Claude continues, then tries to stop again, firing the hook again. Must check `stop_hook_active`:

```bash
INPUT=$(cat)
if [ "$(echo "$INPUT" | jq -r '.stop_hook_active')" = "true" ]; then
  exit 0  # Let Claude stop on second attempt
fi
```

---

## Proposed Design: Layered Detection

Three independent layers, each cheap enough to run on every tool call:

### Layer 1: Command Deduplication (PreToolUse)

**What**: Hash each `tool_input` and track counts. Deny after 3 identical calls.

**Cost**: ~15ms per call, 0 tokens, one state file.

**Config**:
```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|Write|Edit",
        "hooks": [{
          "type": "command",
          "command": "/home/vscode/.claude/hooks/dedup-check.sh",
          "timeout": 5
        }]
      }
    ]
  }
}
```

**Logic**:
```
hash = md5(tool_name + json(tool_input))
count = state[hash] || 0
if count >= 3:
    deny with reason "Same command attempted 3 times. Try a different approach."
else:
    state[hash] = count + 1
    allow
```

**Trade-off**: Only catches exact duplicates. A command that differs by one character bypasses this. That's acceptable — fuzzy matching costs tokens and risks false positives.

### Layer 2: Consecutive Failure Counter (PostToolUseFailure + PostToolUse)

**What**: Count consecutive failures. After 5 in a row, inject context telling Claude to step back.

**Cost**: ~10ms per call, 0 tokens, one state file.

**Config**:
```json
{
  "hooks": {
    "PostToolUseFailure": [
      {
        "hooks": [{
          "type": "command",
          "command": "/home/vscode/.claude/hooks/failure-counter.sh",
          "timeout": 5
        }]
      }
    ],
    "PostToolUse": [
      {
        "hooks": [{
          "type": "command",
          "command": "/home/vscode/.claude/hooks/failure-reset.sh",
          "timeout": 5
        }]
      }
    ]
  }
}
```

**Logic**:
```
PostToolUseFailure:
    failures += 1
    if failures >= 5:
        output systemMessage: "5 consecutive failures. Stop and reconsider your approach."

PostToolUse (success):
    failures = 0  # Reset on any success
```

**Trade-off**: Legitimate retries (e.g., waiting for a server to start) could hit the limit. 5 is conservative enough that real retries rarely exceed it. Can tune after observing real patterns.

### Layer 3: Progress Gate (Stop hook)

**What**: When Claude tries to stop, check whether files actually changed. If not, force continuation with guidance.

**Cost**: ~50-100ms per stop event (git diff), 0 tokens.

**Config**:
```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [{
          "type": "command",
          "command": "/home/vscode/.claude/hooks/progress-gate.sh",
          "timeout": 10
        }]
      }
    ]
  }
}
```

**Logic**:
```
if stop_hook_active == true:
    exit 0  # Prevent infinite loop — let Claude stop

changes = git diff --stat HEAD
if changes is empty AND no_progress_count >= 2:
    exit 0  # Let Claude stop — it's genuinely stuck, don't force it
elif changes is empty:
    no_progress_count += 1
    block with reason "No file changes detected. Review what was accomplished."
else:
    no_progress_count = 0
    exit 0  # Real progress made, allow stop
```

**Trade-off**: Only useful for tasks that modify files. Research/exploration tasks don't produce git diffs. Could also check transcript for new information gathered, but that adds complexity.

---

## What NOT to Do

### Don't use prompt/agent hooks for every tool call

At ~$0.0005 per prompt hook invocation across 100 tool calls, that's $0.05 per session — cheap in isolation. But the latency is 1-5 seconds per evaluation. On a 100-tool-call session, that adds 2-8 minutes of waiting. The command hooks above achieve the same detection in 15ms.

**When prompt hooks ARE worth it**: On the Stop event only. One LLM evaluation at the end of a session to judge whether the task is truly complete is $0.0005 and 2 seconds — acceptable.

### Don't track too much state

Ralph's 6 state files work because it runs between full sessions. For per-tool-call hooks, keep it to 2-3 files maximum:
- `dedup-state.json` — command hash counts
- `failure-count` — single integer
- `progress-state.json` — stop-hook progress tracking

### Don't block too aggressively

A hook that denies a tool call doesn't stop Claude — it just tells Claude the tool was denied. Claude may then try a slightly different variant, or explain why it needs to run the command. This is actually good behavior. The goal is to inject information ("you've tried this 3 times"), not to hard-halt the session.

---

## Cost Summary

| Component | Per-Call Cost | Per-Session (100 calls) | Tokens |
|-----------|-------------|------------------------|--------|
| Layer 1 (dedup) | ~15ms, $0 | ~1.5s, $0 | 0 |
| Layer 2 (failures) | ~10ms, $0 | ~1.0s, $0 | 0 |
| Layer 3 (progress) | ~100ms, $0 | ~100ms (1x per stop) | 0 |
| **Total** | **~25ms** | **~2.6s** | **0** |

Compare to the cost of NOT detecting a loop:
- 50-iteration loop on Opus: ~$50-200 in API costs
- Developer time noticing and restarting: 5-30 minutes
- Lost context from manual restart: unquantifiable

---

## Implementation Plan

### Phase 1: Logging Only (Week 1)

Deploy all three hooks but in **observe mode** — log everything, block nothing. Analyze real patterns before setting thresholds.

```bash
# In dedup-check.sh, instead of denying:
echo "DEDUP: hash=$HASH count=$COUNT tool=$TOOL_NAME" >> /tmp/claude-hook-log.jsonl
exit 0  # Always allow
```

### Phase 2: Soft Blocking (Week 2)

Enable denial for Layer 1 (dedup) and Layer 2 (failures) with conservative thresholds:
- Dedup: 5 identical commands (not 3)
- Failures: 7 consecutive (not 5)

Monitor false-positive rate.

### Phase 3: Tune and Harden (Week 3+)

Based on Week 1-2 data:
- Lower thresholds where loops were detected late
- Raise thresholds where false positives occurred
- Add the Stop hook progress gate
- Consider a prompt hook on Stop for high-value autonomous runs

### File Locations

All hooks go in `~/.claude/hooks/` (global) or `.claude/hooks/` (per-project):

```
~/.claude/
  settings.json          # Hook configuration
  hooks/
    dedup-check.sh       # Layer 1: command deduplication
    failure-counter.sh   # Layer 2: failure counting
    failure-reset.sh     # Layer 2: reset on success
    progress-gate.sh     # Layer 3: stop-hook progress check
```

Settings configuration in `~/.claude/settings.json`:
```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|Write|Edit",
        "hooks": [{
          "type": "command",
          "command": "~/.claude/hooks/dedup-check.sh",
          "timeout": 5
        }]
      }
    ],
    "PostToolUseFailure": [
      {
        "hooks": [{
          "type": "command",
          "command": "~/.claude/hooks/failure-counter.sh",
          "timeout": 5
        }]
      }
    ],
    "PostToolUse": [
      {
        "hooks": [{
          "type": "command",
          "command": "~/.claude/hooks/failure-reset.sh",
          "timeout": 5
        }]
      }
    ],
    "Stop": [
      {
        "hooks": [{
          "type": "command",
          "command": "~/.claude/hooks/progress-gate.sh",
          "timeout": 10
        }]
      }
    ]
  }
}
```

---

## Open Questions

1. **Dedup scope**: Should the hash window reset per-session or persist across sessions? Resetting per-session means Claude can retry the same failed command in a new session. Persisting means legitimate re-runs of the same command (e.g., `npm test`) across sessions could be blocked. **Recommendation**: Per-session.

2. **Failure counter granularity**: Should failures be counted per tool type or globally? A Bash failure followed by a Write failure are probably unrelated. **Recommendation**: Global — Claude's overall approach is failing, regardless of which tool it uses.

3. **Progress gate scope**: `git diff` only catches file changes. Should we also check the transcript for "new information gathered" (e.g., successful Read/Grep calls)? **Recommendation**: Start with git diff only. Add transcript analysis in Phase 3 if needed.

4. **Container vs host**: Should hooks run inside the devcontainer or on the host? Inside the container, they benefit from isolation but are limited by the firewall. On the host, they can access more state but break the sandbox model. **Recommendation**: Inside the container. The hooks don't need network access.

5. **Ralph-style orchestration vs hooks**: Should we also build an outer loop (like Ralph) that restarts Claude sessions, or rely purely on hooks? **Recommendation**: Start with hooks only. They are lower-friction, don't require session restarts, and operate at tool-call granularity. If hooks prove insufficient (e.g., Claude enters a conceptual loop that doesn't repeat exact commands), consider adding a Ralph-style outer loop.
