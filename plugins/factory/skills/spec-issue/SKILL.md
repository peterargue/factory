---
name: spec-issue
description: >-
  Turn an agreed OpenSpec change into a well-specified Linear issue (or a decomposed
  set of issues) that an autonomous agent can execute with minimal back-and-forth.
  Use this whenever the user wants to define, scope, spec, or "write up" a piece of
  work as a Linear issue/ticket — phrases like "let's spec this", "create an issue
  for", "open the issue for this change", "I want to add X" where the intent is to
  DEFINE the work for an agent to process later, not build it now. This is
  define-only: the deliverable is the issue(s), never the implementation. Trigger
  even when Linear or OpenSpec isn't named explicitly, as long as the goal is
  capturing work to be done.
---

> **Factory skill.** Before anything else, read `FACTORY.md` at the repository root; if
> there is none, stop and say this repo has not joined the factory. Literal values below
> (commands, branch names, tracker keys, people) are `tsglobal-ca/platform`'s and are
> examples: use this repo's values from `FACTORY.md`, mapped in
> `${CLAUDE_PLUGIN_ROOT}/reference/repo-values.md`.

# OpenSpec change → Linear issue

This is **stage 4 of the loop in `CLAUDE.md`: open the issue.** The design dialogue
and the spec artifact happen upstream, in OpenSpec. This skill's job is to turn an
already-audited change into a Linear issue (or a chain of them) that a separate,
autonomous agent can pick up and execute **without coming back with questions**.

**Terminal state is the created issue(s).** Do NOT write implementation code,
scaffold, or invoke implementation skills (writing-plans, TDD, etc.). The work is
executed separately, at stage 5.

## Where the spec lives

**The OpenSpec change is the canonical spec.** `openspec/changes/<name>/` holds
`proposal.md` (what & why, with assumptions), `design.md` (how, with decisions) and
`tasks.md` (steps). Those get updated during implementation via `/opsx:update`.

**Do not copy the spec into a Linear Document.** Two copies drift, and the repo copy
is the one that stays true. The issue *references the change by name* and carries the
execution-facing summary. Someone reading only the issue should know what to build and
where the full design lives.

## Preconditions — check these before creating anything

### 1. Does the work need an OpenSpec change at all?

Per `CLAUDE.md`: skip OpenSpec for one-line fixes, copy changes and dependency bumps —
the ceremony costs more than it returns. For those, **write an inline spec in the issue
body** (Context / Proposal / Acceptance criteria) and stop reading here; no change is
needed.

Use OpenSpec for anything with real design content: new endpoints, schema changes, new
domain packages, cross-cutting behavior.

### 2. Does the change exist?

If the work has real design content and no OpenSpec change exists yet, **say so and
direct to `/opsx:propose`** (or `/opsx:explore` first if the shape isn't settled).
Do not run the spec dialogue here and do not write a competing spec in the issue body —
that is exactly the duplication this workflow removes.

Confirm with `openspec list` / `openspec show <name>` and `openspec validate --all`.

### 3. Has the stage-3 audit happened?

`CLAUDE.md` requires a **fresh-context `general-purpose` subagent** to audit the change
artifacts before any code — one that was *not* part of the drafting conversation.

**Check `design.md` for an `## Audit` section.** That's the record: date, what was
checked, findings or "clean". No section means unaudited — treat an absent record as
absent work, not as an oversight to wave through.

If it hasn't run: dispatch it now against every artifact in the change — `proposal.md`,
`design.md`, `tasks.md` and the delta specs under `specs/` —
checking clarity, internal conflicts, gaps, unstated assumptions, and consistency with
the invariants in `openspec/config.yaml`. Have it **report, not fix**, then fold real
findings in with `/opsx:update` and append the record to `## Audit`.

**Do not create the issue against an unaudited change.**

### 4. Will the change reach `main` with its link?

An implementing agent starts from a **fresh branch** off `main`, so it can only build once
the change docs are **merged**. The issue may be created before that, while the change is
committed on a branch or open in its PR — `execute-issue` stops when
`openspec/changes/<name>/` is missing, so an early issue cannot be built against nothing.
A change sitting only in an uncommitted working copy or a worktree is not enough: commit
and push it first.

Write the back-reference in the **same PR as the change**: once the issue key exists, set
`Issue: TAI-xx` in `proposal.md` via `/opsx:update` and commit it to the change's branch
before it merges, so the link runs both ways without a docs-only follow-up PR. For a
decomposed set that is the **parent's** key — one change maps to many issues, and
`execute-issue` accepts a sub-issue's parent key as satisfying the check.

Keep the key out of that PR's branch name and title, and mention it in the body only as
`ref TAI-xx`: the spec PR builds nothing, so it should not be linked as the issue's
implementation (see `CLAUDE.md`). If the change's PR is closed unmerged, cancel the issue.

## Create the issue(s)

Run the **Definition of Ready** checklist below. If any relevant item is still unknown,
resolve it — most belong in the change docs, so fold the answer in with `/opsx:update`
rather than only into the issue.

Then use the Linear MCP (`save_issue`). Defaults (see Config): **the change's own
project, state Todo, unassigned, one type label, a priority.**

The body **must open with the literal line `OpenSpec change: <name>`** — that exact
form is what `execute-issue` reads to find the change, so don't reword it into a
heading or prose. Body structure:

```
OpenSpec change: `add-landed-cost-breakdown`

Full design in `openspec/changes/add-landed-cost-breakdown/` (proposal.md, design.md,
tasks.md). Read it before planning. Keep it truthful with `/opsx:update` if
implementation invalidates it.

## Context / Problem
Why this matters; current state; what's already there.

## Proposal in brief
The agreed approach, enough to act on. Not a re-transcription of design.md.

## Out of scope        (include when it prevents scope creep)
What this issue deliberately does NOT cover, and where it lives instead.
Mirror the proposal's non-goals.

## Assumptions that bear on implementation
Only the ones an implementer will trip over, each with its implication.
Point to proposal.md / design.md for the full set — do not restate them all.

## Codebase anchors
Target package path, binary/command, reference file to mirror.

## Acceptance criteria
- [ ] Concrete, checkable bullets an executing agent can verify against.
- [ ] One per real requirement; testable, not vague.
- [ ] Observable by someone who only runs the app: name the role, the surface (page,
      endpoint, MCP tool, command, table) and what they should see or be refused.
      `verify-acceptance` checks them word for word and marks vague ones BLOCKED.
```

Wire **Depends on / find answers upstream** when the issue follows another: link the
upstream issue ID and say what answers to look for there.

**One change may map to several issues.** See "Decomposing" below.

## Definition of Ready — pre-answer what agents actually ask

**The bar:** an agent should go from issue → plan → execution **without coming back to
the requester**. Mid-work questions are the exception, not the norm. For every item
*relevant* to this issue, either the answer is already in the issue or the change docs,
or you resolve it now and write it in.

A subtle but important line: **specify access, targets, and seams — not the discovery
itself.** For a spike or research task, the unknowns the work exists to resolve stay
open (that's the point). Give the agent everything it needs to *start*; don't pre-empt
what it's meant to *find*.

**Access & secrets** (any issue touching an external/credentialed system):
- **Supporting docs** the work depends on are **attached as files** (below), not just
  linked — an unsynced Dropbox/Drive folder is unreachable to a headless agent. (Real
  failure: an agent spent ~40 turns hunting for a handoff doc before giving up and
  asking.) The OpenSpec change itself doesn't need attaching — it's in the repo.
- **Credentials/secrets**: state the **location and format**, gitignored, never
  committed. *Convention here:* a gitignored `.env` whose values are `op://` 1Password
  references the app resolves at runtime (dev), and Google Secret Manager for the Cloud
  Run job (prod). Name the exact keys (e.g. `CW_USER`, `CW_PASS`) and which values are
  secrets vs config (a customer number is config).
- **External login**: state **MFA / human-in-the-loop** status. If a login needs a human
  for every code, the agent must know before choosing an approach.

**Concrete target & execution:**
- **Name the concrete target** — the specific date / record / account / scope — and a
  **rule to pick it safely** if it varies (e.g. "most recent business day with both
  reports posted; mind the posting lag"). "Single-date" left abstract forces a question.
- **Execution method** when it affects how the agent drives a system or whether secrets
  can be shared (e.g. "drive the portal with Playwright MCP from a clean session").

**Real data** (any issue that parses, ingests or reports on existing data):
- **Point at the real sample** the change was designed against (the fixture path, or the
  production query and what it returned), and the edge cases it showed. If the change has
  none, pull one now and fold what it shows into the change with `/opsx:update`, as
  `spec-feature` step 1 describes.
- **The production dry run** the agent runs before marking the PR ready, if one applies:
  the exact command, and what output passes.

**Codebase anchors** — the **target package/module path** (e.g. `internal/containerworld`),
the **binary/command name** (e.g. `cmd/bc-sales verify`), and a **reference file or
pattern to mirror** (e.g. "follow `internal/apiclient/client.go`: godoc on exports,
`New()` constructor, `%w` error wrapping"). Otherwise the agent infers them and may
guess differently than you'd want.

The `design` rules in `openspec/config.yaml` already require the change to name which
`internal/` packages and migrations it touches, any new `internal/authz` role, whether
per-province variation applies, and whether an MCP tool is needed alongside REST.
**Cross-reference `design.md` for those rather than duplicating them**; the anchors above
are the execution-entry hints, not a second copy of the design.

**Decomposition seams** (when the issue is one sub-task of a chain — these caused every
residual question on an otherwise-strong issue):
- **Who owns shared scaffolding** — name which sub-task creates the shared CLI binary /
  entrypoint / package, so two issues don't both try (or both skip) it.
- **The exact handoff interface** — give the concrete type and method signatures the
  downstream issue consumes (e.g. `Session{ HTTPClient() *http.Client; SessionID() string;
  IsAuthenticated() bool }`), not "an authenticated session".
- **Boundary-straddling helpers**: if an upstream spike recommended an approach touching
  both sides of a seam, **assign it to exactly one side** in the dependent issue ("the
  download-frame helper is fetch logic — TAI-10 owns it; do NOT build it here").

**Handoff outputs.** For any issue whose findings the *next* issue depends on (spikes,
discovery, anything upstream in a chain), add an acceptance criterion that it **document
its answers where the downstream agent will look** (issue comment, or the change docs via
`/opsx:update`). This is what makes a chain runnable with low back-and-forth: e.g.
"Handoff (for #3): document the session interface, its lifetime, and re-auth contract."

If you can't tick the relevant boxes, the issue isn't ready — resolve the gap first.

## Decomposing into multiple issues — the exception here, the norm under an orchestrator

**Default to one issue per change — when nobody is orchestrating the change.** That
is the flow this skill and `execute-issue` serve: one agent owns the whole change, so
there is no ambiguity about who checks off which task, who owns an `/opsx:update`, and
no two agents editing the same `tasks.md` at once. Reach for decomposition only when
the change is genuinely too big for one agent to execute cleanly.

**Those three costs are all costs of an *unowned* shared document, so an orchestrator
removes them rather than paying them.** `implement-feature` makes itself the sole
writer of `design.md` and the append-only `## Audit`, and hands each sub-issue a
disjoint slice of `tasks.md`, so nothing is contended — while the `blockedBy` graph
across sub-issues is precisely what lets it build them in parallel. That is why
`spec-feature` always creates a parent plus sub-issues, even for a change one agent
could manage: the shape is the input the orchestrator schedules from. So the rule is
not "decompose only when forced" but **"decompose only when something owns the change
docs"** — and for single-issue work nothing does, which is what makes one issue the
default here.

When you do decompose, the numbered groups in `tasks.md` are the seam — each
sub-issue states which groups it owns. Then:
- Create a **parent tracking issue** (scope, decisions, sub-issue roadmap, deferred items)
  — usually `Backlog`. Name the OpenSpec change in it.
- Create each piece as a **sub-issue** (`parentId` = parent), in execution order. Each
  sub-issue names the same change and the slice of `tasks.md` it owns.
- Chain them with `blockedBy` so the dependency is visible in Linear (an agent opening #3
  before #2 is done sees it's blocked).
- Put them all in the **change's project** so the set is filterable; don't add a
  per-change label.
- In the parent's body, list the sub-issues in order with their dependencies, and a
  **Deferred** section for everything intentionally pushed beyond the current set.
- Create them in order; later issues can be thinner and point upstream for decisions not
  yet resolved — but still call out the open questions explicitly.

## Config — the Linear target

Current defaults (adjust per repo / confirm if unsure):
- **Team:** TAInvestments (key `TAI`)
- **Project:** one per OpenSpec change, named for it. Create it with `save_project`
  (team `TAI`, state `Planned`, the matching initiative via `addInitiatives`) or reuse
  it if it exists. Work with no change and no feature home goes in `Maintenance`.
- **Labels:** exactly one type label: `Feature`, `Bug` or `Tech debt`.
- **Priority:** always set one (1 Urgent to 4 Low).
- **State:** Todo · **Assignee:** unassigned
- **GitHub:** repo connected, so a branch name containing the issue token (e.g. `tai-12`)
  auto-links PRs and drives state transitions.

Name the issue key in commits: `feat(pricing): add landed-cost breakdown (TAI-42)`.

If working in a different repo/workspace, list teams/projects first (`list_teams`,
`list_projects`) and confirm the target rather than assuming.

## Linear MCP mechanics

The Linear MCP tools are named `mcp__<server>__<tool>` (the server id is session-specific;
find them with ToolSearch, e.g. `select:...save_issue`). Logical tools you'll use:

- `save_issue` — create/update. Create needs `title` + `team`. Useful args: `project`,
  `state`, `assignee` (null = unassigned), `labels`, `parentId`, `blockedBy`
  (append-only), `description` (Markdown — use literal newlines, not `\n`).
- `save_project` — create/update the change's project (`name`, `addTeams`, `state`,
  `addInitiatives`, `priority`).
- `list_teams` / `list_projects` / `list_issue_statuses` — discover the target + states.

`save_document` exists but is **not** used for the spec — see "Where the spec lives".

### Attaching files (the 60-second gotcha)
For *external* source docs the work depends on. Three steps per file, per issue:
1. `prepare_attachment_upload(issue, filename, contentType, size)` → returns a signed
   `uploadRequest.url` + `headers`, and an `assetUrl`.
2. **PUT the raw bytes** to that URL with the signed headers sent **verbatim**
   (`curl -X PUT --data-binary @file -H ...`). Get the exact byte size first
   (`stat -f%z file`).
3. `create_attachment_from_upload(issue, assetUrl, title, subtitle)` to link it.

**The signed URL expires in 60 seconds.** Do NOT batch many `prepare` calls and then one
big upload script — composing a long multi-URL script blows the window and the earliest
URLs return HTTP 400. Instead: `prepare` → PUT **immediately** in the next step, in small
batches (or one issue at a time). Each issue needs its own prepare+upload.

Attach the file to **every issue that needs it**, including the parent. Download a source
doc with `curl -sL -o <file> "<url>"` (follows redirects; e.g. a Dropbox `...&dl=1` link).
For markdown the contentType is `text/markdown`.

## Guardrails

- **Define, don't build.** No code, no plans, no implementation skills. The output is
  issues.
- **Don't re-run the spec dialogue.** That's `/opsx:explore` and `/opsx:propose`. If the
  design isn't settled, send it back there.
- **Permission for side effects.** Creating Linear issues and the change's project is the expected output
  and fine to do once the change is audited and committed. Don't take *other*
  side-effectful actions (sending messages, changing settings) without asking.
- **Don't invent issues the requester didn't ask for.** Surface candidate follow-ups and
  let them decide whether to create them now or leave them as notes.
- **Save durable decisions to memory** as you go — scope decisions, why things were cut,
  gotchas. Design reasoning belongs in the change's `design.md`, not only in memory.
