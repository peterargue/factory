---
description: Orchestrated sub-issue. Build it, decide the open naming call yourself, and report ready without pushing, opening a PR, running the gate or editing the shared change docs.
tags: [execute-issue]
max_turns: 40
timeout_seconds: 1200
allowed_tools: [Read, Glob, Grep, Skill, TodoWrite, Bash, Write, Edit]
---

You are building ENG-21 for the implement-feature orchestrator, which is the gate for this feature. Orchestrated mode: do not push and do not open a PR — build it, leave it uncommitted (I commit the merged result), then report ready and stop. Base branch is `feature/receipt-prices`; you are already on the issue branch `sam/eng-21-price-formatter`. You own task group 1 of the `receipt-prices` change only. Linear isn't connected in this session; the issue is exported at `issues/ENG-21.md`.
