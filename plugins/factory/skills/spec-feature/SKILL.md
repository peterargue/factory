---
name: spec-feature
description: >-
  Use when the user wants a whole feature defined from scratch — "spec out X",
  "let's build X", "I want a feature that…", "design the Y flow" — and the
  deliverable is an agreed, committed spec plus the Linear issues an implementing
  agent will pick up. Also use when resuming a partly-specced feature. This is
  define-only: it never writes implementation code. For a single already-agreed
  change that needs one ticket, use spec-issue instead; to build issues that
  already exist, use implement-feature.
---

> **Factory skill.** Before anything else, read `FACTORY.md` at the repository root; if
> there is none, stop and say this repo has not joined the factory. Literal values below
> (commands, branch names, tracker keys, people) are `tsglobal-ca/platform`'s and are
> examples: use this repo's values from `FACTORY.md`, mapped in
> `${CLAUDE_PLUGIN_ROOT}/reference/repo-values.md`.

# Spec a feature end to end

Carry a feature from a rough idea to **a merged spec plus a dependency-ordered set of
Linear issues** an implementing agent can execute unattended. This is stages 1–4 of the
loop in `CLAUDE.md`, wrapped with two review gates: the user agrees the shape before any
artifact exists, and reads the finished spec, with its issues, as a PR before it merges.

**Terminal state:** the spec is on `main`, the issues exist, and `proposal.md` names the
parent issue. **Never write implementation code here** — not a migration, not a stub,
not "while the spec is in review". The spec PR touches only `openspec/`; zero files
under `src/`.

## What this adds over the building blocks

`/opsx:explore`, `/opsx:propose`, `/opsx:update` and `spec-issue` already exist —
**invoke them and keep driving** (they are steps in this flow, not exits from it). This
skill sequences them and adds two things, both of which an agent working without it
skipped:

1. **The spec ships as a reviewable PR, not a direct commit to `main`.** The user reads
   the design as a diff and comments on it. Do not merge it yourself.
2. **The issues exist before the PR merges**, and the same PR writes the parent issue key
   into `proposal.md`, so the spec and its link land on `main` together.

## The shape this skill always produces

**Always a parent tracking issue plus sub-issues** — even for a change one agent could
manage. The `blockedBy` graph across sub-issues is what lets `implement-feature` schedule
them in parallel, so the shape *is* the input the orchestrator reads. A genuinely
indivisible change gets a parent plus one sub-issue, so `implement-feature` always sees the
same shape.

**This is consistent with `spec-issue`.** Its "Decomposing into multiple issues" section
states the rule — **decompose only when something owns the change docs** — and names
`implement-feature` as the owner here. Its one-issue-per-change default is for work *nobody*
is orchestrating. Read the reasoning there rather than restating it here.

**One PR, carrying its own link.** The issues are created once the spec is audited and
before the spec PR opens, so `proposal.md` lands with `Issue: TAI-<parent>` already in it.
While that PR is open the issues point at a change `main` does not have yet; that is safe
because `execute-issue` stops when the change directory is missing, so nothing can be
built from them before the merge. `CLAUDE.md` describes this directly.

## Step 0. Resume check

Never assume you're starting clean. Establish state first, and skip to the right step:

```bash
git fetch origin
openspec list
git cat-file -e origin/main:openspec/changes/<name>/design.md   # merged? exit 128 if not
gh pr list --state all --head spec/<name>                       # spec PR?
```

Use `git cat-file -e`, **not** `git ls-tree` — `ls-tree` exits 0 with empty output for a
path that doesn't exist, so it passes silently and tells you nothing. Match PRs by `--head`,
not `--search`: GitHub tokenizes a path query and returns unrelated PRs while missing the
one you want.

Then check Linear for existing issues — `list_issues` filtered by the change's project (or
`query: <change-name>`). Without this you cannot tell "no issues yet" from "already created",
and resuming blind double-creates them.

| State | Resume at |
|---|---|
| No change directory | Step 1 |
| Change directory incomplete (fewer than the five artifacts in step 3 — delta specs are the usual omission) | Step 3 |
| All five artifacts present, no `## Audit` entry | Step 4 |
| Audited, no issues | Step 5 |
| Issues exist, `proposal.md` still says `Issue: none yet` | End of step 5 (write the key) |
| Issues exist, `proposal.md` names the parent, no spec PR | Step 6 |
| Spec PR open | Wait / fold in feedback (step 6) |
| Merged on `origin/main`, `proposal.md` names the parent | Done |
| Merged on `origin/main`, no issues (an older two-PR spec) | Step 5, then a docs-only PR for the key |

Also confirm your **working copy is a safe place to work**: a clean tree with no
unrelated in-flight work. If `git branch --show-current` shows an unrelated branch with
changes, use the main checkout or add a fresh worktree — never drag a busy worktree onto
a new branch.

## 1. Explore — no artifacts yet

Run `/opsx:explore <topic>`. Investigate what exists, what the feature's nouns actually
map to, and where the request collides with reality. Ground every schema claim in
`src/migrations/` — **trust migrations over docs and comments** when they disagree.

**Do not draft `proposal.md` before step 2.** A confidently-wrong design is the expensive
failure this stage prevents.

Expect to find the feature doesn't map cleanly onto the data model. That mismatch **is**
the finding — carry it to step 2 rather than papering over it.

**Look at the real thing before designing for it.** If the feature reads or writes data
that already exists anywhere (a production table, a vendor report, a board file, the
workbook, a Slack channel), pull a real sample now: a read-only production query (standing
approval), the actual report or file, a few real rows. Record in the explore notes what you
looked at and what surprised you. Nearly every post-merge fix in 2026-11 came from a shape
nobody had looked at: stray and doubled spaces in store and product names (five digest
fixes), historic LDB report layouts (two), five Kyro SKUs where the spec assumed one, a
holiday run date. Look for the edges deliberately: the oldest and newest record, blanks,
duplicates, odd whitespace and casing, a second province, a non-business day.

**Read the ops process the feature touches.** If it automates or changes something Elise or
Zoe do, read the matching skill in `src/.claude/skills/` (and its references) before
designing, and design to it. Stay true to that process; a departure is a step-2 question,
labelled as a change from the original with the reason. Specs revised after merge to match
an ops skill or a later ops decision (#665, #679, #815) are the cost of skipping this.

## 2. Refine with the user — the primary gate

Put the open decisions to the user in **as few rounds as possible** — batch everything
currently known into one round, and only open another round if the answers surface
something new. Use `AskUserQuestion`; if it isn't available, ask as a short numbered
list in your reply. Lead each with a recommendation and your reasoning.

Ask only what you can't answer from the codebase — and always ask about anything that:

- crosses a **trust boundary** (staff / retail buyer / supplier / agent), especially
  anything that could leak one tenant's data to another;
- produces a **number a user will act on** (a rollup, a total, a derived quantity);
- turns on a **production side effect** (real email, a live feed, a deploy);
- would touch a **product invariant** in `openspec/config.yaml`;
- has **schema lock-in** — guessing wrong costs a migration plus a backfill.

Non-material calls (naming, file layout, DTO shapes, route paths) you make yourself and
record as assumptions.

Questions only Elise or Zoe can answer (how a report is used, which rows count, what a
status means to ops) go in the **same round**, marked "for Elise/Zoe", so the user can
post them to the group chat with them. Never message them directly. Don't open the spec
PR while one is open; an answer that arrives after merge is a post-merge revision.

## 3. Propose

Run `/opsx:propose <change-name>`. This repo is `schema: spec-driven`, so a change is
**five artifacts**, not three:

- **`.openspec.yaml`** — change metadata.
- **`proposal.md`** — why; explicit **non-goals**; which users it's for; `Issue: none yet`;
  an **Assumptions** section where each assumption carries its **implication** (what
  breaks if it's wrong). Write "None" rather than omitting it — an absent section is
  indistinguishable from an overlooked one.
- **`design.md`** — which `internal/` packages and which migrations; any new
  `internal/authz` role/atom (**"none, and here's why"** is a valid answer — suppliers,
  for instance, aren't authz principals); whether per-province variation applies;
  whether an MCP tool is needed alongside REST — **and if deliberately not, the
  reasoning**, so it doesn't read as an oversight; a **Decisions** section giving
  chosen / rejected / why / what it commits us to; **assumptions carried forward from
  the proposal** plus any new ones; and an `## Audit` section.
- **`specs/<capability>/spec.md`** — the **delta specs**, in `Requirement` + `Scenario`
  form. Easy to forget and the most consequential omission: `/opsx:sync` folds these
  into `openspec/specs/` as the permanent spec of record. Every change in this repo has
  them.
- **`tasks.md`** — **numbered groups**, because those groups are the seam sub-issues are
  cut along in step 5. Each task names its files and how to verify it. Three kinds of task
  are required where they apply:
  - **Real-sample fixtures.** A parser, feed, importer or report gets at least one test
    built from the real sample pulled in step 1 (trimmed, with personal and credential
    data removed), beside the synthetic edge cases.
  - **A production dry run before ready.** Anything with a `--dry-run` mode, or that reads
    production data, gets a task to run it against production and check its output against
    the acceptance criteria before the PR is marked ready.
  - **A `First-run checks` group** for a change that adds or alters infrastructure, a
    deploy, a scheduled job or a service on office: what to look at on the first real run
    (the job's first execution and its flags, the VM booting and registering, the service
    answering), each with the command and the expected result. `run-rollout` runs it.

**Name migration files, but never their numbers.** Numbers collide across in-flight
branches, and a pinned number rots quietly. Write it as
`src/migrations/<next>_supplier_reorder_thresholds.sql — number re-derived at
implementation time`, which satisfies the "name the files" rule without pinning.
`migrations/embed_test.go` catches the rest.

Then `openspec validate --all`. Note it checks **structure only** — it will not tell you
whether non-goals, assumptions-with-implications, Decisions or `## Audit` are actually there.
`.claude/scripts/check-change-docs.sh` covers three of those mechanically (a dated `## Audit`
entry, a `## Assumptions` section, and, run as
`CHANGE_DOCS_BASE=origin/main .claude/scripts/check-change-docs.sh`, a **Rejected** and a
**Commits us to** line on every decision of each design you changed; it is what CI runs).
Everything else — non-goals, whether each assumption carries its implication, whether the
Decisions are real — only step 4 catches. **Re-run `validate` and the script after every
`/opsx:update`**, including in steps 4, 5 and 7: a decision added by a fix is the one that
usually lands without its rejected options.

## 4. Audit — a hard gate

Dispatch a **fresh-context `general-purpose` subagent** that took no part in drafting. A
drafting agent reads its own intent into the gaps; a cold reader sees only what's on the
page, which is what the implementing agent will face.

Scope it to **all five artifacts including the delta specs**, checking clarity, internal
conflicts, gaps, unstated assumptions, and consistency with the invariants in
`openspec/config.yaml` — **verifying every schema and code claim against source** — and
have it **report, not fix**. Have it also check that every assumption about the shape of
existing data cites the sample it came from (an uncited one is a finding), that the
`tasks.md` items required in step 3 are present, and that a feature touching an ops process
names the skill it follows.

Fold real findings in with `/opsx:update`, re-validate, then append a dated entry to
`## Audit` (what was checked, findings or "clean"). Append-only; never rewrite an earlier
entry.

**The dated entry is now enforced by CI**, so a spec PR missing it fails rather than merging
quietly: the audit-record step of `CI / Detect what changed, run guards` runs `.claude/scripts/check-change-docs.sh`,
which fails any non-archived change whose `design.md` has no `## Audit` section with a line
carrying an ISO date under it, or whose `proposal.md` has no `## Assumptions` section. Run the
script locally before pushing. Be clear about what that buys, though: **it confirms the record
exists, not that a review happened or was any good.** Writing a dated line to satisfy the
check without dispatching the subagent passes CI and defeats the entire point of step 4.

**Re-run the audit if the revision was substantial** — meaning the approach changed,
packages or migrations moved in or out of scope, a decision was reversed, or a stated
assumption turned out false. Renames and rewording don't count; prefer re-running when
genuinely unsure.

No `## Audit` entry means unaudited, which blocks step 5.

## 5. Issues — once the audit is recorded

Use `spec-issue` for issue-body structure, the Definition of Ready, and the Linear MCP
mechanics. Its file-attachment procedure (and the 60-second signed-URL window) applies
**only if there are external docs to attach** — for an all-in-repo feature there are
none. Defaults: team `TAI`, unassigned, **parent in `Backlog`, sub-issues in `Todo`**,
all in **one Linear project named for the change** (create it with `save_project`, state
`Planned`, under the matching initiative; reuse it if it exists), each with a type label
(`Feature`, `Bug` or `Tech debt`) and a priority. `Todo` is safe before
the merge: an agent that picks one up early finds no change directory on `main` and stops.

Each sub-issue must state:

- **`OpenSpec change: <name>`** as its literal opening line — that exact form is what
  `execute-issue` parses. Not a heading, not prose.
- **Which task groups it owns.**
- **`blockedBy`** for every real dependency. `implement-feature` schedules its waves off
  this graph: an unstated dependency becomes a build failure, and a spurious one
  needlessly serializes the work.
- **Who owns shared scaffolding** — name the one sub-issue that creates a shared binary,
  package or helper, so two agents don't both build it or both skip it.
- **The concrete handoff interface** it consumes or produces: real type and method
  signatures, not "an authenticated session".
- **Acceptance criteria** — the contract. Tasks are the route and may be re-planned;
  criteria may not change without surfacing.
- **How it will be invoked**: `implement-feature` delegates each sub-issue to `execute-issue`
  **in orchestrated mode, with PR base `feature/<name>`**. Name the mode and stop there —
  the mode defines the consequences (no PR of its own, no integration gate, the shared
  change docs left to the orchestrator, a parent key in `proposal.md` accepted as the
  two-way link); restating them in the issue body creates a copy that goes stale.

Add a handoff acceptance criterion to any sub-issue others are `blockedBy`: it must
document its answers where the downstream agent will look.

The parent carries scope, the decisions, the sub-issue roadmap with its dependency
graph, and a **Deferred** section. It is a tracking issue — **no code of its own.**

Then `/opsx:update` to set `Issue: TAI-<parent>` in `proposal.md` — the **parent's** key,
since one change now maps to many issues — and re-validate.

## 6. Spec PR — then stop

Docs-only, from a verified clean working copy (step 0):

```bash
git fetch origin && git switch -c spec/<change-name> origin/main
git add openspec/changes/<change-name>
git commit -m "docs(openspec): add <change-name> (ref TAI-<parent>)"
git push -u origin spec/<change-name>
gh pr create --base main --title "docs(openspec): <feature>" --body-file <path>
```

**Keep the issue keys out of the branch name and title**, and name them in the body only
as `ref TAI-<key>`. This PR builds none of the issues, so it should not be linked as
their implementation (see `CLAUDE.md`).

The body: what the feature is, the decisions with their reasoning, the assumptions with
their implications, and **the parent + sub-issue split with its dependency graph and
issue keys**.

The guard (`deny-stale-pr.sh`) measures **`origin/<head>`**, not your local branch, because
`gh pr create` pushes nothing on your behalf. So push before you open, and push again after
every revision — an unpushed commit is invisible to it, and it fails closed rather than
guessing.

**Then stop and hand over the URL.** Do not merge.

- **Feedback on the design** → fold in with `/opsx:update`, re-validate, re-audit if
  substantial, update any issue whose body or acceptance criteria it changes, push, wait
  again.
- **Feedback on the decomposition** → revise the split in `tasks.md`'s groups, the PR body
  and the issues to match: edit, add, or cancel sub-issues and fix their `blockedBy`.
- **"Don't build this"** → confirm, then close the PR, leave the branch unmerged and
  **cancel the parent and every sub-issue**. Don't delete anything else.

Once the user merges, report the issue keys. There is no second PR.

## Red flags

| Thought | Reality |
|---|---|
| "I'll commit the spec straight to main, it's just docs" | The PR **is** the review gate. Step 6 exists so the user reads the design as a diff. |
| "proposal, design, tasks — that's the change" | Five artifacts. Missing delta specs ship unaudited and break `/opsx:sync`. |
| "One issue is simpler here" | Always parent + sub-issues — the `blockedBy` graph is what `implement-feature` schedules from. `spec-issue` agrees: decompose whenever something owns the change docs. |
| "I'll open the spec PR now and add the issue key in a follow-up PR" | That second PR is the churn this flow removes. Create the issues first; the key rides in the spec PR. |
| "I'll put the issue key in the branch name so Linear links it" | Linear then treats the spec PR as the implementation. `spec/<name>` and `ref TAI-<key>` only. |
| "`openspec validate --all` passed, so the artifacts are complete" | It checks structure only. Non-goals, implications and real Decisions are unchecked by it — and CI's spec check only confirms the audit *record* exists. |
| "The audit is a formality, the design is clearly fine" | You drafted it, so you're least able to see what it fails to say. Absent `## Audit` entry = stop. |
| "I'll note the migration as 00073" | Numbers collide across in-flight branches, and a pinned one rots. Name the file, not the number; `make migrate-next` resolves it at build time. |
| "This is obviously supplier-only, MCP doesn't apply" | Probably right — write the reasoning down, or it reads as overlooked. |
| "I'll start scaffolding while the spec is in review" | Define-only. No implementation code, ever, in this skill. |
| "I'm mid-flow, so I'll just start at step 1" | Run step 0 first. Resuming blind double-creates issues and PRs. |

## Guardrails

- **No implementation code.** The output is a merged spec and issues.
- **One docs-only PR, merged by the user** — not by you.
- Creating Linear issues and the change's project is the expected output. Other side effects
  (messages, settings, deploys) follow the harness's permission rules.
- **Don't invent scope the user didn't ask for.** Surface candidate follow-ups; let them
  decide.
- Save durable decisions and root-caused gotchas to memory (codev) as you go. Design
  reasoning belongs in `design.md`, not only in memory.
