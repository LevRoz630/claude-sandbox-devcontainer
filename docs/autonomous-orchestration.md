# Autonomous Orchestration: Research & Technical Analysis

How to make Claude Code work longer and harder without human intervention,
while keeping it safe inside a container sandbox.

---

## Table of Contents

1. [The Problem](#the-problem)
2. [Three Approaches Compared](#three-approaches-compared)
3. [snarktank/ralph — The Original](#snarktankralph--the-original)
4. [frankbria/ralph-claude-code — The Evolved Fork](#frankbriaralph-claude-code--the-evolved-fork)
5. [Native Claude Code Hooks — The Third Path](#native-claude-code-hooks--the-third-path)
6. [Technical Deep Dive: How Each Handles Loops](#technical-deep-dive-how-each-handles-loops)
7. [Technical Deep Dive: How Each Detects Completion](#technical-deep-dive-how-each-detects-completion)
8. [Alignment Analysis](#alignment-analysis)
9. [Recommendation](#recommendation)
10. [Broader Ecosystem](#broader-ecosystem)

---

## The Problem

Running Claude Code with `--dangerously-skip-permissions` in a sandbox eliminates
permission prompts. But Claude still stops after completing what it *thinks* is the
task. For complex multi-step work, this creates a pattern:

```
Human: "Implement feature X with tests"
Claude: [does 60% of the work, stops]
Human: "Keep going, you still need to..."
Claude: [does another 20%, stops]
Human: "The tests are failing because..."
Claude: [fixes tests, stops]
```

Each interruption:
- Breaks Claude's chain of thought (especially harmful on Opus with extended thinking)
- Requires the human to read, evaluate, and re-prompt
- Wastes the human's "concentrated thought" time on supervision

**Goal**: Claude should autonomously iterate until objective success criteria are met
(tests pass, linter clean, all stories implemented), only stopping when genuinely done
or genuinely stuck.

**Constraint**: Must prevent runaway loops that burn $50-200+ in API costs on Opus
before anyone notices.

---

## Three Approaches Compared

| | snarktank/ralph | frankbria/ralph-claude-code | Native Hooks |
|---|---|---|---|
| **Architecture** | Bash loop, fresh process per iteration | Bash wrapper with session resume | Shell scripts in `~/.claude/hooks/` |
| **Codebase** | ~100 lines | ~4,850 lines | ~50-200 lines per hook |
| **Session model** | New process each loop (context destroyed) | `--resume` (context preserved across loops) | Same conversation (context fully preserved) |
| **Loop detection** | Hard iteration cap only | 3-state circuit breaker | Custom per-tool-call hooks |
| **Mid-turn control** | None | None | Yes (PreToolUse can deny individual tool calls) |
| **Completion check** | Grep for magic string | Dual-condition gate with rolling signals | Stop hook with script/LLM evaluation |
| **Maintenance** | Low (but also low maintainer investment) | High (5K lines of bash) | Low (small scripts, first-party API) |
| **Stars** | 10,364 | 6,891 | N/A (built-in feature) |
| **License** | MIT | MIT | N/A |

---

## snarktank/ralph — The Original

**Repo**: https://github.com/snarktank/ralph
**Author**: Ryan Carson, based on [Geoffrey Huntley's Ralph pattern](https://ghuntley.com/ralph/)
**Created**: January 7, 2026 | **Last commit**: February 2, 2026
**Contributors**: 4 | **Commits on main**: ~20

### How It Works

The entire runtime is one bash loop:

```bash
# Simplified from ralph.sh (~100 lines total)
for i in $(seq 1 $MAX_ITERATIONS); do
    # Pipe prompt template into Claude, capture output
    OUTPUT=$(claude --dangerously-skip-permissions --print < CLAUDE.md)

    # Check for completion signal
    if echo "$OUTPUT" | grep -q '<promise>COMPLETE</promise>'; then
        echo "All stories complete!"
        exit 0
    fi

    sleep 2
done
echo "Max iterations reached"
exit 1
```

Claude reads a `prd.json` file each iteration containing user stories with pass/fail
flags. The prompt template (`CLAUDE.md`) instructs Claude to:

1. Read `prd.json`, pick the highest-priority failing story
2. Implement it, run quality checks (typecheck, lint, test)
3. If checks pass, commit and set `passes: true` in `prd.json`
4. Append learnings to `progress.txt`
5. If all stories pass, output `<promise>COMPLETE</promise>`

**Memory between iterations** persists only through files:
- `prd.json` — which stories are done
- `progress.txt` — append-only learnings log
- Git history — committed code

### Loop Detection

**There is almost none.** The only safeguard is `MAX_ITERATIONS` (default 10).

No detection for:
- Repeated failures (API errors silently burn iterations)
- Stuck states (same story failing every loop)
- Regressions (story N breaks story N-1)
- Rate limits (no API limit awareness)
- Context exhaustion (`progress.txt` grows unbounded)

### Completion Detection

Grep for `<promise>COMPLETE</promise>` in stdout. This is **fragile**:

- Claude can emit the string prematurely (documented in issue #93)
- No independent verification — the bash loop trusts Claude's self-report
- A community fix (checking `prd.json` directly) exists but is unmerged

### Assessment

**Strengths**: Conceptually clean, trivially understandable, zero dependencies beyond
`jq` and the Claude CLI.

**Weaknesses**: Too simple for production use. No error handling, no circuit breaking,
no rate limit awareness, orphaned process risk, fragile completion detection. The high
star count (10K+) reflects the idea's viral appeal, not the code's maturity. Maintainer
engagement is low — many substantive community PRs remain unmerged for weeks.

**Critical flaw for our use case**: Each iteration spawns a **fresh process**, destroying
all conversation context. This directly conflicts with maximizing concentrated thought,
especially on Opus where extended thinking builds deep reasoning chains that are lost on
every restart.

---

## frankbria/ralph-claude-code — The Evolved Fork

**Repo**: https://github.com/frankbria/ralph-claude-code
**Created**: August 27, 2025 | **Last commit**: February 9, 2026
**Version**: v0.11.4 | **Contributors**: 13 | **Tests**: 484 (BATS, 100% pass)

### How It Works

A substantially more sophisticated bash wrapper:

```
ralph --monitor
  └─ ralph_loop.sh (1,793 lines, main orchestrator)
       ├─ sources lib/response_analyzer.sh (959 lines)
       ├─ sources lib/circuit_breaker.sh (490 lines)
       ├─ sources lib/date_utils.sh, timeout_utils.sh
       └─ enters while(true) loop:
            1. Check circuit breaker state (can_execute?)
            2. Check rate limits (can_make_call?)
            3. Check graceful exit conditions (should_exit_gracefully?)
            4. Build command: claude -p <prompt> --output-format json
                              --allowedTools <tools>
                              --resume <session_id>
                              --append-system-prompt <loop_context>
            5. Capture output, parse JSON
            6. Extract RALPH_STATUS block from response
            7. Analyze response (analyze_response)
            8. Update exit signals (update_exit_signals)
            9. Record result in circuit breaker (record_loop_result)
            10. Sleep 5 seconds, repeat
```

Key difference from snarktank: uses `--resume <session_id>` to preserve conversation
context across loop iterations. This is a major improvement — Claude retains memory of
what it tried previously.

### The RALPH_STATUS Protocol

The prompt template instructs Claude to end every response with:

```
---RALPH_STATUS---
STATUS: IN_PROGRESS | COMPLETE | BLOCKED
TASKS_COMPLETED_THIS_LOOP: <number>
FILES_MODIFIED: <number>
TESTS_STATUS: PASSING | FAILING | NOT_RUN
WORK_TYPE: IMPLEMENTATION | TESTING | DOCUMENTATION | REFACTORING
EXIT_SIGNAL: false | true
RECOMMENDATION: <one line summary of what to do next>
---END_RALPH_STATUS---
```

The wrapper parses this block to make decisions. Extraction uses:
1. `jq` on JSON output (primary)
2. Regex on the `---RALPH_STATUS---` block in `.result` text (fallback)
3. Text grep for keywords (last resort)

### Loop Detection: 3-State Circuit Breaker

```
CLOSED ──(2 no-progress loops)──> HALF_OPEN ──(1 more)──> OPEN
  ^                                    │                      │
  │                              (progress detected)    (30min cooldown)
  │                                    │                      │
  └────────────────────────────────────┘                      v
  ^                                                      HALF_OPEN
  └──────────────────────────────────────────────────────────┘
```

**Trigger conditions** (any one opens the circuit):

| Trigger | Threshold | What It Detects |
|---------|-----------|-----------------|
| No progress | 3 consecutive loops with no file changes AND no completion signals | Claude is spinning without producing output |
| Same error | 5 loops with repeated errors | Claude hitting the same wall repeatedly |
| Output decline | Output size drops >70% | Claude giving up / producing empty responses |
| Permission denial | 2 loops with denied permissions | Claude can't do what it needs to do |

**Progress detection** uses multiple signals:
- `git diff --name-only` for uncommitted changes
- `git diff <start_sha> HEAD` for committed changes
- Claude's self-reported `FILES_MODIFIED` from RALPH_STATUS
- Completion signals from response analysis

**Recovery mechanisms**:
- `HALF_OPEN`: If progress detected, returns to `CLOSED`
- Cooldown auto-recovery: After 30 minutes in `OPEN`, transitions to `HALF_OPEN`
- Auto-reset on startup (configurable)
- Manual: `ralph --reset-circuit`

**State persisted in**:
- `.ralph/.circuit_breaker_state` — current state + counters
- `.ralph/.circuit_breaker_history` — transition log
- `.ralph/.exit_signals` — rolling window of last 5 signals

### Completion Detection: Dual-Condition Gate

Both conditions must be true simultaneously to exit:

| completion_indicators >= 2 | EXIT_SIGNAL = true | Result |
|---|---|---|
| Yes | Yes | **EXIT** |
| Yes | No | Continue |
| No | Yes | Continue |
| No | No | Continue |

Additional exit conditions checked independently:
- All checkboxes in `.ralph/fix_plan.md` marked `[x]`
- 3+ consecutive test-only loops (test saturation)
- 2+ "done" signals in recent window
- Safety valve: 5 consecutive `EXIT_SIGNAL=true` force-exits

### Configuration

Project-level `.ralphrc`:

```bash
MAX_CALLS_PER_HOUR=100            # Rate limit
CLAUDE_TIMEOUT_MINUTES=15         # Per-execution timeout (1-120 min)
CLAUDE_OUTPUT_FORMAT="json"       # json or text
ALLOWED_TOOLS="Write,Read,Edit,Bash(git *),Bash(npm *),Bash(pytest)"
SESSION_CONTINUITY=true           # Use --resume
SESSION_EXPIRY_HOURS=24           # Session timeout
CB_NO_PROGRESS_THRESHOLD=3       # Circuit breaker: loops without progress
CB_SAME_ERROR_THRESHOLD=5        # Circuit breaker: repeated errors
CB_OUTPUT_DECLINE_THRESHOLD=70   # Circuit breaker: output size decline %
CB_COOLDOWN_MINUTES=30           # Circuit breaker: recovery cooldown
CB_AUTO_RESET=false              # Reset circuit on startup
```

### Known Issues

- **#175**: `set -e` + `set -o pipefail` causes silent script death on timeout
- **#97**: Ralph not starting on existing project (P1 bug)
- **#154**: Bash wildcard patterns in `ALLOWED_TOOLS` not working
- **#177**: tmux session persists after loop exits
- macOS requires `brew install coreutils` for `gtimeout`
- BSD/GNU `stat`, `date` differences require platform detection

### Assessment

**Strengths**: Genuinely good engineering in the circuit breaker and exit detection.
Session continuity via `--resume` is a major improvement over snarktank. Well-tested
(484 BATS tests). Active development, responsive maintainer, real community contributions.

**Weaknesses**: 5,000 lines of bash is inherently fragile. Completion still relies on
Claude following prompt instructions — it's prompt engineering, not enforcement. No
mid-execution control (can't intervene between tool calls). No token/cost tracking. Some
P1 bugs remain open. Cross-platform bash compatibility is a recurring maintenance burden.

**Critical assessment for our use case**: The circuit breaker concepts are excellent and
worth adopting. But the bash wrapper architecture fights against Claude Code's native
design. Every time the wrapper interrupts to check status, it adds latency and overhead.
The `--resume` flag preserves context but still creates an unnatural boundary in Claude's
reasoning. For maximizing concentrated thought, the control should happen *inside* the
session, not around it.

---

## Native Claude Code Hooks — The Third Path

Claude Code has a first-party hooks system with 14 lifecycle events. Hooks are shell
commands, LLM prompts, or agent evaluations that fire at specific points.

### The Stop Hook: Core Mechanism

The `Stop` hook fires every time Claude finishes responding. It receives:

```json
{
  "session_id": "abc123",
  "transcript_path": "/home/user/.claude/projects/.../00893aaf.jsonl",
  "cwd": "/home/user/my-project",
  "hook_event_name": "Stop",
  "stop_hook_active": true
}
```

**`stop_hook_active`** is the critical field. It is `true` when Claude is already
continuing because a previous Stop hook blocked it. Without checking this field,
the hook creates an unrecoverable infinite loop.

The hook controls Claude's behavior through its output:

```bash
# Method 1: Exit code 2 blocks stopping, stderr becomes Claude's instruction
echo "Tests not passing yet. Run npm test and fix failures." >&2
exit 2

# Method 2: JSON output on exit 0
echo '{"decision": "block", "reason": "Tests not passing. Run npm test and fix failures."}'
exit 0

# Method 3: Allow stopping
exit 0  # (no output or {"decision": "allow"})
```

When blocked, the `reason` becomes Claude's next instruction **within the same
conversation**. This is the key difference from wrapper approaches: Claude never loses
context. Extended thinking chains on Opus persist. There is no session restart.

### Three Hook Types

**Command hooks** — Shell scripts. Fastest (~15ms), zero token cost, deterministic.
```json
{
  "type": "command",
  "command": "~/.claude/hooks/progress-gate.sh",
  "timeout": 10
}
```

**Prompt hooks** — Single LLM call (Haiku by default). Good for judgment calls.
```json
{
  "type": "prompt",
  "prompt": "Check if all tasks are complete. Respond {\"ok\": false, \"reason\": \"...\"} if not."
}
```

**Agent hooks** — Multi-turn subagent with tool access (Read, Grep, Glob). Most
powerful, but slowest and most expensive.
```json
{
  "type": "agent",
  "prompt": "Run the test suite and verify all tests pass. $ARGUMENTS",
  "timeout": 120
}
```

### Official Ralph Wiggum Plugin

Anthropic ships an official hooks-based Ralph implementation as a Claude Code plugin.

Location: `plugins/ralph-wiggum/` in the
[anthropics/claude-code](https://github.com/anthropics/claude-code) repo.

Its `stop-hook.sh` (~180 lines):
1. Checks `.claude/ralph-loop.local.md` state file for active loop config
2. Reads frontmatter: iteration count, max_iterations, completion_promise
3. Parses the JSONL transcript for `<promise>` tags matching the completion string
4. If max iterations reached or promise found: removes state file, exits 0 (allows stop)
5. Otherwise: increments counter, outputs `{"decision": "block", "reason": "..."}`

Usage: `/ralph-loop "Build a REST API" --max-iterations 50 --completion-promise "DONE"`

### Mid-Turn Control: PreToolUse and PostToolUse

Unlike wrapper approaches, hooks can intervene between individual tool calls:

**PreToolUse** — fires before every tool call, receives `tool_name` and `tool_input`:
```json
{
  "tool_name": "Bash",
  "tool_input": {"command": "rm -rf /workspace/src"},
  "tool_use_id": "toolu_01ABC..."
}
```

Can deny the call:
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "This command has been attempted 3 times. Try a different approach."
  }
}
```

**PostToolUse / PostToolUseFailure** — fires after tool execution, can inject context:
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUseFailure",
    "additionalContext": "WARNING: 5 consecutive failures. Reconsider your approach."
  }
}
```

### Hook Capabilities and Limitations

**What hooks CAN do**:
- Allow/deny/modify tool calls (PreToolUse)
- Block Claude from stopping and inject continuation instructions (Stop)
- Inject context messages (additionalContext on most events)
- Read the full conversation transcript via `transcript_path`
- Auto-approve or deny permissions (PermissionRequest)
- Run background tasks asynchronously (command hooks only)
- Use LLM judgment (prompt/agent hooks)
- Set session environment variables (SessionStart)

**What hooks CANNOT do**:
- Inject arbitrary user messages (Stop `reason` is the closest equivalent)
- Trigger slash commands or specific tool calls
- Modify or delete conversation history
- Undo tool actions after execution (PostToolUse is informational only)
- Communicate directly between hooks (must use filesystem)
- Track token consumption or API cost
- Distinguish "task complete" from "mid-task status update" in Stop hooks
  (must analyze transcript or use prompt/agent hooks for this)

**Known risks**:
- A bug in `stop_hook_active` checking creates an unrecoverable infinite loop
  (documented in GitHub issues #10205 and #3573)
- The UI shows "Stop hook error:" even for intentional blocking (issue #12667)
- Hook changes mid-session require review via `/hooks` or session restart

### Assessment

**Strengths**: Zero infrastructure overhead. Full context preservation (the primary goal).
Mid-turn intervention capability that wrappers lack. First-party supported API with
official plugin examples. Small scripts that are easy to understand and maintain.

**Weaknesses**: Must implement loop detection logic yourself (no built-in circuit breaker).
`stop_hook_active` is a boolean, not a counter — sophisticated counting requires state
files. Context window grows continuously; long runs will trigger compaction which loses
detail. No process-level timeout (if Claude hangs, the hook never fires). No built-in
cost tracking.

---

## Technical Deep Dive: How Each Handles Loops

### Scenario: Claude runs `npm test` and it fails. Claude runs it again. And again.

**snarktank/ralph**: Does nothing. Each iteration is a fresh process. If Claude runs
`npm test` 50 times within one iteration, the wrapper has no visibility. The iteration
either times out or Claude stops on its own. The only protection is `MAX_ITERATIONS`.

**frankbria/ralph-claude-code**: Cannot see individual `npm test` calls (no mid-turn
visibility). But between iterations, the circuit breaker detects "no progress" if
`git diff` shows no file changes. After 3 no-progress loops, it enters `HALF_OPEN`.
After one more, it opens the circuit and stops. Total waste before detection:
~4 iterations * 15 min timeout = up to 60 minutes.

**Native hooks**: A `PreToolUse` hook fires before every `npm test` call. It can hash
the command and track how many times it's been called:

```bash
#!/bin/bash
INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name')
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
SESSION=$(echo "$INPUT" | jq -r '.session_id')

STATE_FILE="/tmp/claude-dedup-${SESSION}"
HASH=$(echo "${TOOL}:${CMD}" | md5sum | cut -d' ' -f1)
COUNT=$(jq -r --arg h "$HASH" '.[$h] // 0' "$STATE_FILE" 2>/dev/null || echo 0)

if [ "$COUNT" -ge 3 ]; then
    jq -n '{
        hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: "This exact command has been run 3 times already. The output will not change. Try a different approach to fix the underlying issue."
        }
    }'
else
    # Increment counter
    NEW_COUNT=$((COUNT + 1))
    CURRENT=$(cat "$STATE_FILE" 2>/dev/null || echo '{}')
    echo "$CURRENT" | jq --arg h "$HASH" --argjson c "$NEW_COUNT" '.[$h] = $c' > "$STATE_FILE"
    exit 0
fi
```

Detection happens on the **3rd duplicate**, not after 60 minutes. The denial message
guides Claude toward a different approach.

### Scenario: Claude alternates between two failing approaches (A, B, A, B, ...)

**snarktank/ralph**: No detection. Each approach is a different command, so even if
there were per-command tracking, it wouldn't catch the oscillation pattern.

**frankbria/ralph-claude-code**: The no-progress detector catches this eventually. If
neither approach produces file changes, the circuit breaker opens after 3 iterations.
But if both approaches produce *different* file changes (just wrong ones), the circuit
breaker may not trigger at all.

**Native hooks**: A `PostToolUseFailure` hook counts consecutive failures regardless of
which command fails:

```bash
#!/bin/bash
INPUT=$(cat)
SESSION=$(echo "$INPUT" | jq -r '.session_id')
COUNTER_FILE="/tmp/claude-failures-${SESSION}"

COUNT=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
COUNT=$((COUNT + 1))
echo "$COUNT" > "$COUNTER_FILE"

if [ "$COUNT" -ge 5 ]; then
    jq -n '{
        hookSpecificOutput: {
            hookEventName: "PostToolUseFailure",
            additionalContext: "WARNING: 5 consecutive tool failures detected. You appear to be stuck in a loop. Stop, re-read the error messages carefully, and consider a fundamentally different approach."
        }
    }'
fi
```

A companion `PostToolUse` hook resets the counter on any success:

```bash
#!/bin/bash
INPUT=$(cat)
SESSION=$(echo "$INPUT" | jq -r '.session_id')
echo "0" > "/tmp/claude-failures-${SESSION}"
exit 0
```

### Scenario: Claude "completes" the task but tests are actually failing

**snarktank/ralph**: Claude emits `<promise>COMPLETE</promise>`, the loop exits. No
verification. If Claude hallucinated success, the user discovers broken code later.

**frankbria/ralph-claude-code**: The dual-condition gate requires 2+ completion
indicators over a rolling window, plus an EXIT_SIGNAL. This reduces premature exits
but still relies on Claude's self-report. The wrapper does not independently run tests.

**Native hooks**: A Stop hook can independently verify:

```bash
#!/bin/bash
INPUT=$(cat)

# Prevent infinite loop
if [ "$(echo "$INPUT" | jq -r '.stop_hook_active')" = "true" ]; then
    exit 0
fi

CWD=$(echo "$INPUT" | jq -r '.cwd')

# Run tests independently
cd "$CWD"
if npm test > /tmp/claude-test-output 2>&1; then
    exit 0  # Tests pass, allow stop
else
    FAILURES=$(tail -20 /tmp/claude-test-output)
    jq -n --arg reason "Tests are failing. Fix these before stopping:\n${FAILURES}" \
        '{"decision": "block", "reason": $reason}'
fi
```

Or use a prompt-based hook for judgment calls that aren't binary:

```json
{
  "hooks": {
    "Stop": [{
      "hooks": [{
        "type": "prompt",
        "prompt": "Analyze whether the task described in the conversation is truly complete. Check: Were all requirements addressed? Were tests written and passing? Is the code clean? Respond {\"ok\": true} or {\"ok\": false, \"reason\": \"what remains\"}."
      }]
    }]
  }
}
```

---

## Technical Deep Dive: How Each Detects Completion

### The Fundamental Tension

Completion detection has two failure modes:
1. **False positive** (stops too early): Work is incomplete, human must re-prompt
2. **False negative** (never stops): Infinite loop, burns API cost

Every approach trades off between these. More aggressive completion checking reduces
false positives but risks false negatives (and vice versa).

### snarktank: Text Matching

```bash
if echo "$OUTPUT" | grep -q '<promise>COMPLETE</promise>'; then
    exit 0
fi
```

- False positive rate: **High**. Claude can emit the string while explaining what it
  will do, or when it misunderstands its own progress. Issue #93 documents this.
- False negative rate: **Low**. If Claude produces the string, the loop exits.
- Verification: **None**. Trust-based.

### frankbria: Rolling Signal Window + Dual Gate

```
completion_indicators (rolling window of 5):
  - Increments when Claude sets EXIT_SIGNAL: true in RALPH_STATUS
  - Must reach >= 2

EXIT_SIGNAL (current iteration):
  - Extracted from RALPH_STATUS block via jq/regex
  - Must be "true"

Exit only when BOTH conditions are met simultaneously.
```

- False positive rate: **Medium**. Dual gate catches many premature signals. But both
  signals come from Claude's self-report, so a confidently wrong Claude can still exit.
- False negative rate: **Low-Medium**. The dual gate can delay exit when Claude is
  genuinely done but inconsistent in its signaling.
- Verification: **Indirect**. Progress detection via `git diff` adds a weak check.

### Native Hooks: Independent Verification

```
Stop hook fires → script/prompt/agent evaluates independently:
  - Run test suite (command hook)
  - Check git diff for changes (command hook)
  - Ask Haiku "is this task done?" with transcript context (prompt hook)
  - Spawn subagent to read code and verify (agent hook)
```

- False positive rate: **Low**. Independent test execution catches incomplete work.
  Prompt/agent hooks catch conceptual gaps.
- False negative rate: **Configurable**. The `stop_hook_active` guard ensures Claude
  can always stop on the second attempt, preventing infinite loops.
- Verification: **Independent**. The hook runs tests itself rather than trusting Claude.

---

## Alignment Analysis

### Goal: Maximize concentrated thought by minimizing required interactions

| Criterion | snarktank | frankbria | Native Hooks |
|-----------|-----------|-----------|-------------|
| **Context preservation** | None (fresh process) | Partial (`--resume`) | Full (same conversation) |
| **Extended thinking chains** | Destroyed every iteration | Partially preserved | Fully preserved |
| **Overhead per iteration** | ~2s sleep + process startup | ~5s sleep + status parsing | ~25ms per tool call |
| **Detection granularity** | Per-session only | Per-session only | Per-tool-call |
| **Independent verification** | None | `git diff` only | Tests, linting, LLM judgment |
| **Recovery from loops** | Manual restart | Auto-recovery after 30min cooldown | Immediate guidance injection |

### Goal: Effective loop detection

| Criterion | snarktank | frankbria | Native Hooks |
|-----------|-----------|-----------|-------------|
| **Duplicate command detection** | None | None | Yes (PreToolUse hash tracking) |
| **Consecutive failure detection** | None | Via output decline | Yes (PostToolUseFailure counter) |
| **No-progress detection** | MAX_ITERATIONS only | `git diff` + self-report | `git diff` in Stop hook |
| **Circuit breaker** | None | 3-state with auto-recovery | Must build yourself |
| **Time to detection** | Up to MAX_ITER * timeout | 3 iterations (~45 min worst case) | 3 duplicate commands (~seconds) |
| **Cost of undetected loop** | $50-200+ | $10-50 (circuit breaker limits) | $1-5 (per-call detection limits) |

### Goal: Low maintenance burden

| Criterion | snarktank | frankbria | Native Hooks |
|-----------|-----------|-----------|-------------|
| **Lines of code** | ~100 | ~4,850 | ~200-400 total |
| **Language** | Bash | Bash (complex) | Bash (simple scripts) |
| **Dependencies** | jq, claude CLI | jq, tmux, coreutils, claude CLI | jq, claude CLI |
| **Platform concerns** | Minimal | BSD/GNU differences throughout | Minimal (runs inside container) |
| **API surface** | Custom (PROMPT.md protocol) | Custom (RALPH_STATUS protocol) | First-party (Claude Code hooks API) |
| **Upgrade path** | Manual | Manual | Hooks API maintained by Anthropic |
| **Test coverage** | None | 484 BATS tests | Can test hooks independently |

---

## Recommendation

**Use native hooks, borrowing ideas from frankbria's circuit breaker.**

Neither Ralph repo should be adopted as-is. The reasons:

1. **snarktank/ralph** is a concept demo, not production tooling. Its simplicity is
   appealing but the complete absence of loop detection, error handling, and independent
   verification makes it unsuitable for autonomous runs where cost control matters.

2. **frankbria/ralph-claude-code** has genuinely excellent engineering in its circuit
   breaker. But 5,000 lines of bash wrapping an external process is the wrong abstraction
   layer. It fights against Claude Code's architecture rather than working with it. The
   maintenance burden is high and the wrapper approach fundamentally breaks concentrated
   thought by creating artificial session boundaries.

3. **Native hooks** preserve the full conversation, operate at tool-call granularity,
   and have near-zero overhead. The official Ralph Wiggum plugin proves the pattern works.
   The missing piece is frankbria's circuit breaker sophistication — which can be ported
   into hook scripts at a fraction of the code complexity.

### What to Build

A layered hook system (as designed in [loop-detection-design.md](./loop-detection-design.md)):

| Layer | Hook Event | Purpose | From |
|-------|-----------|---------|------|
| Command dedup | PreToolUse | Block after 3 identical commands | Original design |
| Failure counter | PostToolUseFailure + PostToolUse | Inject warning after 5 consecutive failures | Original design |
| Progress gate | Stop | Check `git diff` + optionally run tests before allowing stop | Borrows from frankbria's progress detection |
| Circuit breaker state | Stop | Track no-progress count across stop attempts, force-allow stop after threshold | Borrows from frankbria's 3-state circuit breaker |
| Iteration cap | Stop | Hard limit on total continuations per session | Borrows from snarktank's MAX_ITERATIONS |

The Stop hook combines multiple checks:

```
Stop hook fires:
  1. If stop_hook_active AND iteration >= max_iterations: allow stop (hard cap)
  2. If stop_hook_active AND no_progress_count >= 2: allow stop (genuinely stuck)
  3. If stop_hook_active: allow stop (simple guard)
  4. Run independent checks (git diff, test suite)
  5. If checks pass: allow stop
  6. If checks fail: block, inject reason, increment counters
```

This gives us:
- frankbria's circuit breaker logic (stop after repeated no-progress)
- snarktank's simplicity (hard iteration cap as safety net)
- Native hook advantages (context preservation, per-tool-call detection)
- Independent verification (actually run tests, not just trust Claude)

---

## Broader Ecosystem

### Other Orchestration Tools

| Tool | Approach | Notable Feature |
|------|----------|----------------|
| [oh-my-claudecode](https://github.com/Yeachan-Heo/oh-my-claudecode) | Multi-agent orchestration | Ecomode routes simple tasks to Haiku (30-50% token savings) |
| [Claude Flow](https://github.com/ruvnet/claude-flow) | 60+ agent swarms | "Queen" agents coordinate work, prevent drift |
| [Auto-Claude](https://github.com/AndyMik90/Auto-Claude) | Kanban UI + SDLC pipeline | Spec → Plan → Code → QA → Review workflow |
| [Claude Code GitHub Actions](https://github.com/anthropics/claude-code-action) | CI/CD integration | Responds to @claude in PRs/issues |

### MCP Servers for Autonomous Development

| Server | Purpose | Why It Matters |
|--------|---------|---------------|
| [Memory (official)](https://github.com/modelcontextprotocol/servers/tree/main/src/memory) | Persistent knowledge graph | Carry context across sessions/compactions |
| [mcp-memory-keeper](https://github.com/mkreyman/mcp-memory-keeper) | Work history preservation | Prevents re-explanation across sessions |
| [Sequential Thinking](https://github.com/modelcontextprotocol/servers) | Structured multi-step reasoning | Helps Claude plan before acting |
| [GitHub MCP](https://github.com/modelcontextprotocol/servers) | PR/issue management | Claude can manage its own PRs |

### Container Sandbox Approaches

| Tool | Isolation | Notable Feature |
|------|-----------|----------------|
| [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) | Firecracker microVMs | Official Docker product, ~125ms boot |
| [E2B](https://e2b.dev/) | Firecracker microVMs | Used by 88% of Fortune 100 |
| [Sprites.dev](https://sprites.dev/) (Fly.io) | Firecracker + checkpoint/rollback | 27-150ms cold start, persistent state |
| [Trail of Bits devcontainer](https://github.com/trailofbits/claude-code-devcontainer) | Docker + iptables | Security-first, `claude-yolo` alias |
| [centminmod devcontainer](https://github.com/centminmod/claude-code-devcontainers) | Docker + multi-AI | Claude + Codex + Gemini with cross-verification |
| [Anthropic reference devcontainer](https://github.com/anthropics/claude-code/tree/main/.devcontainer) | Docker + iptables | Official blessed sandbox approach |

### Cost Observability

| Tool | Approach | Open Source |
|------|----------|-------------|
| [Langfuse](https://langfuse.com/) | Self-hosted tracing + cost tracking | Yes |
| [Helicone](https://www.helicone.ai/) | Proxy-based, change API base URL only | Yes |
| `--max-turns N` (built-in) | Hard limit on autonomous tool calls | N/A |

### Claude Code Agent SDK

For programmatic orchestration beyond hooks:

```bash
# CLI headless mode
claude -p "Fix the failing tests" \
    --allowedTools "Read,Edit,Bash(npm test)" \
    --output-format stream-json \
    --max-turns 20 \
    --resume "$SESSION_ID"
```

```python
# Python SDK
from claude_agent_sdk import query, ClaudeAgentOptions

options = ClaudeAgentOptions(
    allowed_tools=["Read", "Write", "Bash"],
    max_turns=20
)

async for message in query(prompt="Fix the tests", options=options):
    print(message)
```

Native agent teams (experimental):
```bash
CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 claude
```

---

## References

### Ralph Implementations
- snarktank/ralph: https://github.com/snarktank/ralph
- frankbria/ralph-claude-code: https://github.com/frankbria/ralph-claude-code
- Geoffrey Huntley's original Ralph concept: https://ghuntley.com/ralph/
- Official Ralph Wiggum plugin: https://github.com/anthropics/claude-code (plugins/ralph-wiggum/)

### Claude Code Documentation
- Hooks reference: https://code.claude.com/docs/en/hooks
- Hooks guide: https://code.claude.com/docs/en/hooks-guide
- Headless / programmatic usage: https://code.claude.com/docs/en/headless
- Settings: https://code.claude.com/docs/en/settings
- Development containers: https://code.claude.com/docs/en/devcontainer
- Agent SDK overview: https://platform.claude.com/docs/en/agent-sdk/overview

### Community Resources
- Awesome Claude Code toolkit: https://github.com/rohitg00/awesome-claude-code-toolkit
- Claude Code hooks mastery: https://github.com/disler/claude-code-hooks-mastery
- Trail of Bits claude-code-config: https://github.com/trailofbits/claude-code-config

### Related GitHub Issues
- Infinite loop from stop hooks: https://github.com/anthropics/claude-code/issues/10205
- Stop hook infinite loop in CI: https://github.com/anthropics/claude-code/issues/3573
- Stop hook UX shows "error": https://github.com/anthropics/claude-code/issues/12667
