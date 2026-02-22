---
name: fresh-review
description: Run an unbiased code review in a fresh context window. Use after completing any implementation to catch issues your session context might miss.
disable-model-invocation: true
---

Perform a fresh-context code review of the recent changes: $ARGUMENTS

## Workflow

1. **Delegate to fresh-reviewer agent** — Use the `fresh-reviewer` subagent with worktree isolation. This gives it a completely clean context with no memory of the implementation.

2. **If no arguments provided**, review all uncommitted changes (staged + unstaged) plus any commits not yet on main.

3. **After the review completes**, present the findings and ask:
   - Should I fix any CRITICAL/HIGH issues now?
   - Should I rewind to a checkpoint and re-approach?
   - Or is this ready to commit/ship?

## Why This Matters

Claude reviewing its own code in the same session is biased — it "remembers" writing it and tends to see what it intended, not what it actually wrote. A fresh context has no such bias.

## Alternative Approaches

If you want even more isolation:
- Open a second terminal: `claude --worktree review` and review from there
- Use Agent Teams: spawn a dedicated reviewer teammate
