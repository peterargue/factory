---
name: init
description: >-
  Join a repository to the software factory: scaffold its FACTORY.md, OpenSpec config,
  CI and Claude review workflows, the branch ruleset, the plugin settings and the
  tracker project, then prove it with factory:doctor. Use when someone wants a new or
  existing repo to "use the factory", "set up like platform", "add FACTORY.md", or run
  the spec-to-production skills somewhere they have not run before.
---

# Join a repo to the factory

The factory's machinery knows nothing about any repo. A repo joins by holding the
values the machinery needs (`FACTORY.md`) and the things it relies on existing: CI and
a review that run on default-branch and feature-branch PRs, a ruleset that makes them
required, OpenSpec, the plugin enabled, and a tracker to file work in. This skill
builds those, fills every value it can find, asks for the rest, and ends with a clean
`factory:doctor` run.

Templates are in `${CLAUDE_PLUGIN_ROOT}/templates/`: `FACTORY.md` (the contract) and
`init/` (`ci.yml`, `claude-review-caller.yml`, `ruleset.json`, `openspec-config.yaml`,
`approvals.md`). Gaps in the `init/` templates are `{{name}}`; gaps in `FACTORY.md` are
`<name>`. `factory:doctor` fails on either if one is left behind.

## 0. Look before writing

Work in a checkout of the target repo, on a new branch (`factory/init`). Never on the
default branch: everything this skill writes to the repo goes through one PR.

Read, and keep notes for step 1:

- `git remote get-url origin` → `repo.github`; `gh api repos/<o>/<r> --jq .default_branch`.
- `CLAUDE.md`, `AGENTS.md`, `README.md`, `Makefile`/`justfile`/`package.json` scripts,
  `go.mod`, `pyproject.toml`, `Cargo.toml`: how it builds, tests and lints. The full
  check CI should run is `commands.gate`; the fast, side-effect-free ones a delegate may
  run are `commands.delegate_safe`.
- `.github/workflows/`: existing CI (keep it; add triggers rather than replace), any
  existing review, deploy-on-merge workflows (`deploy.on_merge_to_default`).
- `gh api repos/<o>/<r>/rulesets` and each one's rules: what is already required.
- `openspec/`: already initialised?
- `FACTORY.md`: if it exists, this is a re-run. Run `factory:doctor` instead and fix
  what it reports; do not overwrite a filled contract.

If the repo is empty (no code yet), say so and fill only what does not depend on code:
the contract with `none` for commands, the review, the ruleset with the review alone.

## 1. Ask once, for what the repo cannot tell you

Collect everything you could not read into ONE question to the person (a decision card
where there are options). Typically:

- **Owner/approver** (`repo.owner`) and whether **AI attribution** is allowed
  (`repo.ai_attribution`).
- **Tracker**: Linear team key, or GitHub issues, or none; the catch-all project name
  (default `Maintenance`); does a merged PR close its issue.
- **What the product is and its invariants**, for `openspec/config.yaml`. Offer a
  draft from the README and code; they correct it. Do not invent invariants.
- **Merging to the default branch deploys?** and which steps a merge does not do
  (plan-grant steps). These become `## Approvals` and `## Deploy`.

Everything else, choose and say what you chose. Defaults: `feature/` prefix,
`spec/<change-name>`, `pr_size_target: 500`, `worktrees.path: .claude/worktrees/<token>`,
`specs.system: openspec`, `audit_required: true`, `ci.max_fix_rounds: 2`,
`judge_model: sonnet`, `acceptance.production: never`.

## 2. Write the files

Each from its template, every placeholder filled:

1. **`FACTORY.md`** from `templates/FACTORY.md`. Every key stays, in order; `none` for
   unused slots. Point at homes rather than copying (`approvals: CLAUDE.md#Approvals`,
   `invariants: openspec/config.yaml#Invariants`). Set "current as of" to today.
   `ci.review_check` is `review / Claude review` when the repo calls the reusable
   reviewer, `Claude review` when it carries a rendered copy (step 3).
2. **OpenSpec.** If `openspec/` is missing, run
   `npx -y @fission-ai/openspec@latest init --tools claude --scope project --no-animation --no-copilot-cloud`
   from the repo root (it writes `openspec/`, `.claude/commands/opsx/` and
   `.claude/skills/openspec-*`). Then replace `openspec/config.yaml` with
   `templates/init/openspec-config.yaml`, filled from step 1. Without network access,
   write the config alone and tell the person to run that command.
3. **Claude review**, `.github/workflows/claude-review.yml`:
   - Repo owner is `peterargue` (same owner as the factory): fill
     `templates/init/claude-review-caller.yml` with the plugin's version from
     `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json`. The factory repo's
     **Settings → Actions → General → Access** must allow repos of that owner; say so.
   - Any other owner: render a standalone copy, so the private reusable workflow is not
     needed:
     `${CLAUDE_PLUGIN_ROOT}/scripts/render-review-workflow.sh --branches '<default>, "<prefix>**"' [--input extra_allowed_tools="Bash(go vet:*)"] [--input allowed_bots=...] > .github/workflows/claude-review.yml`.
     Never hand-edit the output; re-render it.
   - An existing review workflow: leave it, and point `ci.review_workflow` and
     `ci.review_check` at it. Doctor will call it a hand-kept copy.
4. **CI.** If no workflow runs the gate on PRs: fill `templates/init/ci.yml`. Choose
   `{{toolchain_steps}}` from what the repo builds with (`actions/setup-go` with
   `go-version-file: go.mod`, `actions/setup-node` with `node-version-file` and
   `cache`, `astral-sh/setup-uv`, ...), indented as steps. If CI exists, keep it and
   make sure its `pull_request.branches` covers the default branch and
   `"<prefix>**"`, its `types` include `ready_for_review`, and its jobs skip drafts
   only if the review does too. The jobs that must pass become the ruleset's required
   checks.
5. **`CLAUDE.md` § Approvals.** If `CLAUDE.md` has no `## Approvals`, append
   `templates/init/approvals.md` filled from step 1 (create `CLAUDE.md` with a one-line
   title if it has none).
6. **`.claude/settings.json`**: merge in, keeping what is there,

   ```json
   {
     "extraKnownMarketplaces": { "factory": { "source": { "source": "github", "repo": "peterargue/factory" } } },
     "enabledPlugins": { "factory@factory": true }
   }
   ```

Commit (respecting `repo.ai_attribution`), push, and open the PR as a **draft** with
`${CLAUDE_PLUGIN_ROOT}/scripts/pr-cycle.sh open` (or the REST pulls API in a cloud
session). Body: what was scaffolded, every value you chose rather than read, and the
GitHub steps below with their status.

## 3. GitHub and the tracker

These change the repo's settings or another system, not files, so list them in one
message and get the person's go-ahead once for the set. Then do them:

- **Ruleset.** Fill `templates/init/ruleset.json` (`{{review_check}}`, and replace
  `Gate` with the real required job names) and
  `gh api -X POST repos/<o>/<r>/rulesets --input <file>`. If a default-branch ruleset
  already exists, `PUT` that one with the union of its rules and these instead of adding
  a second. Create it **after** the init PR's checks have reported at least once, or
  required checks that never ran will block the init PR itself; until then leave the
  PR in draft. A 403 means the token lacks admin: give the person the JSON and the
  **Settings → Rules → Rulesets** link.
- **Secret.** The review needs `CLAUDE_CODE_OAUTH_TOKEN`. Only the person can make it:
  `claude setup-token` on their machine, then **Settings → Secrets and variables →
  Actions**. Never ask them to paste the token into the conversation.
- **Tracker.** Linear: check the team key exists (`list_teams`), and find or create
  the catch-all project (`list_projects`, then `save_project`). GitHub issues: the
  catch-all is a label or milestone; `gh project create` needs GraphQL, which cloud
  sessions cannot reach, so ask the person to create a project there if they want one.
- **Plugin in project threads.** Project threads read plugins from **Project settings
  → Plugins**, not from the repo; if this repo will be worked from a project, ask the
  person to add `factory@factory` there.

## 4. Prove it

Run `${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh --remote` on the branch (or the
`factory:doctor` skill, which also checks the tracker). Fix every FAIL. Each WARN is
either fixed or named in the PR body with why it stays. Then mark the PR ready through
the normal gate (`pr-cycle.sh ship`); the repo's own new CI and review run on it, which
is the first real test that they work.

Report: the PR link, the doctor summary line, and what is still the person's to do
(secret, plugin in Project settings, Actions access, ruleset if it was refused).
