---
name: verify-acceptance
description: >-
  Check finished work against its Linear acceptance criteria with a fresh-context
  verifier that has never seen the build: it reads the criteria word for word, drives
  the running app (browser, API, MCP, database, CLI) and reports pass, fail or blocked
  per criterion, before the PR is marked ready. execute-issue (standalone) and
  implement-feature (per sub-issue and on the merged feature) call it after the gate;
  also use it when Peter asks whether an issue or PR really does what its issue says.
---

> **Factory skill.** Before anything else, read `FACTORY.md` at the repository root; if
> there is none, stop and say this repo has not joined the factory. Literal values below
> (commands, branch names, tracker keys, people) are `tsglobal-ca/platform`'s and are
> examples: use this repo's values from `FACTORY.md`, mapped in
> `${CLAUDE_PLUGIN_ROOT}/reference/repo-values.md`.

# Verify acceptance criteria with a separate agent

The builder knows what it meant to build, so it checks its own intent. The reviewer
reads the diff, so it checks the code. Nothing checks **behaviour against the
contract**: the acceptance criteria in the Linear issue, which `CLAUDE.md` calls the
definition of done. This skill adds that check. A verifier agent that took no part in
the build reads the criteria as written, runs the app, tries each one, and returns a
verdict per criterion with the evidence it observed.

It sits after the gate and before the PR is marked ready (`pr-cycle.sh ship`):

```
build → gate (pr-cycle.sh gate) → verify-acceptance → PR body → pr-cycle.sh ship → CI + Claude review (as PR events)
```

It does not replace the builder's own "every acceptance criterion met" line in the
`execute-issue` checklist, the gate, the production dry run or the Claude review. Each
of those answers a different question.

## Who runs it

The caller is whoever is about to mark the PR ready, and **never the agent that wrote
the code being verified**:

| Flow | Caller | When |
|---|---|---|
| `execute-issue`, standalone | The session that built the issue | After `make ci-all` is green and `origin/<base>` is merged in, before the PR is marked ready |
| `execute-issue`, orchestrated | Nobody: the delegate skips it | The orchestrator runs it instead |
| `implement-feature`, per sub-issue | The orchestrator | Step 4, after the post-merge gate in the issue worktree, before `pr-cycle.sh ship` on the sub-PR |
| `implement-feature`, whole feature | The orchestrator | Step 7, on the merged feature branch, with the parent's criteria and every sub-issue's, before the umbrella PR is marked ready |

A standalone builder still calls it itself, because the verifier is a new agent with a
fresh context either way. What makes it independent is what the brief leaves out, below.

## What the verifier gets, and what it must not get

Fresh context is the point. **The verifier gets the contract and the means to test
it, and nothing about how the work was done.** Anything about the build steers it
towards confirming the builder's story instead of the issue's criteria.

Give it:

- **The issue keys.** It reads each issue's `## Acceptance criteria` section from
  Linear itself (`get_issue`), so no one paraphrases them on the way. If the verifier
  cannot reach Linear, paste each section **verbatim**, copied from `get_issue` output,
  with the key and title above it. Never summarise, merge, reorder or reword a
  criterion, even to fix a typo.
- **Where the work is:** the absolute checkout path, the branch, and the head SHA you
  are about to mark ready.
- **Where to write the report:** an absolute path **outside the repo** (the session's
  scratchpad, or `/tmp/acceptance-<key>-<sha7>.md`).
- **Who holds the browser.** Say whether it may start the dev stack and sign in, or
  that someone else holds the browser and it must use API, database and CLI checks
  only (see "One browser at a time").

Never give it:

- the diff, the PR body, the commit list or a summary of what changed;
- the builder's report, assumptions, decisions or its own criteria check;
- hints about where to look or what should pass ("the new filter is on the orders
  page");
- the change docs as reading matter. It may open `proposal.md` or `design.md` only to
  learn **how to reach** a surface the criteria name, never to decide whether a
  criterion is met.

## How to dispatch it

Dispatch **one new `general-purpose` subagent**, in the foreground, since your next
step depends on its result. Some hosts (Projects threads among them) run it in the
background anyway; then wait for its completion notice, and do not touch the checkout,
its database or the browser until it arrives. Never reuse an agent that has seen the build, and never use
`SendMessage` to an earlier verifier for a re-check: it now remembers the last round.
The prompt is this, with the four values filled in and nothing added:

```
You are an acceptance verifier. Read
${CLAUDE_PLUGIN_ROOT}/skills/verify-acceptance/verifier-brief.md and follow it exactly.

Issues: <TAI-n>[, <TAI-m> …]
Checkout: <absolute path>   Branch: <branch>   Head: <full sha>
Report file: <absolute path outside the repo>
Browser: <"you may start the dev stack and use the browser" | "API, database and CLI only; another agent holds the browser">
```

A subagent starts with no repo context (`CLAUDE.md` → Execution), which is why the
brief is a file it reads rather than rules you restate. Subagents do not work in a
headless `claude -p` run (`.claude/rules/review-workflow.md`), so this runs in an interactive session,
a Projects thread, or a Remote Control session, never in CI.

## Reading the result

The verifier writes the report file and ends its final message with the same report,
so a lost file loses nothing. Read the file, check that its marker carries the SHA you
gave it, then act on its outcome:

| Outcome | Means | Do |
|---|---|---|
| `pass` | Every criterion PASS | Paste the report into the PR body and mark ready |
| `blocked` | No FAIL, at least one BLOCKED | Read each reason. **production** and **external** criteria go in the PR body as open items for the dry run or the first real run, and keep the issue In Progress after merge until someone checks them. **stack** means the verifier could not start the app: fix that and re-verify. **ambiguous** means the criterion cannot be tested as written: surface it to Peter, since a criterion change is a scope change; do not reword it yourself. **human** means it needs a person's judgment: list it for Peter. Mark ready only when every BLOCKED reason is production, external or human |
| `fail` | At least one FAIL | Do not mark ready. Fix it in the build, re-run the gate, then dispatch a **new** verifier on the new head |

**Two failing rounds, then stop.** If the second fresh verifier still reports a FAIL,
stop and surface it to Peter with both reports: either the build cannot meet the
criterion or the criterion is wrong, and both are his call. Do not argue with a FAIL by
re-running until one passes; a verdict you went looking for is not evidence.

A FAIL you believe is wrong (the verifier misread the app, or tested the wrong
checkout) still counts as a round. Say why in the PR body, with your own evidence, and
dispatch a new verifier with a corrected brief, not a hint.

## What goes in the PR body

Paste the report under a `## Acceptance verification` heading, marker included:

```
<!-- acceptance-verify v1 outcome=pass|blocked|fail sha=<head sha> -->
```

The marker is SHA-scoped like the review marker: a verification of an earlier commit
does not cover this one. **A push after verifying makes the report stale.** If you push
again (a merge from the base, a review fix), re-verify the new head before marking ready
again, or say in the PR body which criteria the push could not have touched and why.
Nothing checks the marker yet; it is there so a hook or script can.

## One browser at a time

The verifier may sign in through `/auth/dev-login` or a magic link, so it holds the
shared browser session (`FACTORY.md` → Shared singletons). Session cookies are
host-scoped and the browser ignores the port, so a second sign-in on `localhost` evicts
the first. When another agent might be using the browser, tell the verifier "API,
database and CLI only": it marks browser-only criteria BLOCKED (stack), and you re-run it
for those when the browser is free. `implement-feature` runs one verifier at a time for
this reason.

## Cost

A verifier is a native Claude Code subagent on the subscription, so no API key is
involved. It costs one agent's context per issue plus one per feature, and it counts
against the usage window like any other agent. Skip it, and say so in the PR body, only
when the issue has no acceptance criteria (a one-line fix with an inline spec) or the
change has no behaviour to observe (docs only).
