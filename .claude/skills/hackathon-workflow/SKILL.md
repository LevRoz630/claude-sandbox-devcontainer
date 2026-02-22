---
name: hackathon-workflow
description: Competition/hackathon development workflow. Explore → Plan → Build → Review → Ship with context management at each phase.
disable-model-invocation: true
---

Execute the hackathon workflow for: $ARGUMENTS

## Phase 1: Explore (Plan Mode)
- Switch to Plan Mode (Shift+Tab twice)
- Read relevant code, understand patterns
- Use subagents for broad exploration to protect main context
- Output: understanding of what exists and what needs to change

## Phase 2: Plan
- Create detailed implementation plan with phases
- Each phase should be independently verifiable
- Press Ctrl+G to edit plan in your editor
- `/compact Focus on the implementation plan` after planning is done

## Phase 3: Build
- Switch to Normal Mode
- Implement in phases, verifying each one
- Run tests after each phase
- Use `/cost` to monitor spending

## Phase 4: Review (CRITICAL)
- `/fresh-review` — runs unbiased review in isolated context
- Or: use a subagent with worktree isolation to review
- Fix any CRITICAL/HIGH findings
- This is the step most people skip — don't skip it

## Phase 5: Ship
- Commit with descriptive message
- Create PR with `gh pr create`
- `/compact` to reset for next task

## Context Management Checkpoints
- `/compact` after Phase 1 (exploration is context-heavy)
- `/compact` after Phase 2 (plan is established, exploration details can go)
- `/clear` between unrelated features (don't let Feature A context pollute Feature B)
- After 2 failed corrections: `/clear` and rewrite the prompt

## Parallel Execution
For multiple independent features:
```bash
claude --worktree feature-a   # Terminal 1
claude --worktree feature-b   # Terminal 2
claude --worktree feature-c   # Terminal 3
```

## Rewind Checkpoints
- Double-tap Esc or `/rewind` to open checkpoint menu
- Restore conversation, code, or both
- Use "Summarize from here" to condense old context while keeping recent work
- Checkpoints persist across sessions — safe to close terminal
