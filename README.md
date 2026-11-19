# factory

A private Claude Code plugin marketplace holding one plugin, `factory`: the
spec-to-production pipeline first built in `tsglobal-ca/platform`, made repo-agnostic.
Every fact about a particular repo lives in that repo's `FACTORY.md`; nothing here
knows which repo it is serving.

Everything runs as native Claude Code (CLI, cloud sessions, scheduled tasks and
`claude-code-action`), so it works on a Claude subscription. Nothing here needs an
`ANTHROPIC_API_KEY`.

## What's in it

| Path | What |
|---|---|
| `plugins/factory/skills/` | `spec-feature`, `spec-issue`, `execute-issue`, `implement-feature`, `verify-acceptance`, `run-rollout`, `review-sessions`, and `tend-pr` (one fix round on a PR the signal workflow flagged), invoked as `factory:<name>` |
| `plugins/factory/hooks/` | `deny-stale-pr` (no PR from a head behind its base), `advise-ci-watch` (after a push: ship, subscribe to the PR's events, `pr-cycle.sh status` on each; never a poll), `deny-ai-attribution` (on when `FACTORY.md` sets `ai_attribution: deny`), `deny-unverified-ready` (no PR marked ready without a green gate stamp on HEAD's tree and a scope-judge pass). Each hook does nothing in a repo without `FACTORY.md` |
| `plugins/factory/scripts/` | `pr-cycle.sh` (gate, open draft, ship, status, handoff, merge; REST-only), `gate-stamp.sh` (runs `commands.gate`, stamps HEAD's tree on green), `scope-judge.sh` (diff vs the PR and its spec, via `claude -p`), `wait-ci.sh` (legacy blocking watch, local CLI only), `pr-review-comments.sh` (all three review endpoints), and the two verdict helpers |
| `plugins/factory/templates/FACTORY.md` | The contract a new repo fills in |
| `plugins/factory/templates/factory-signal.yml` | The signal workflow a repo copies: labels a PR on red CI or review findings |
| `MEMORY-MAP.md` | Which store owns which fact: the repo, the knowledge base, project memory, codev, `~/.agents` |
| `.github/workflows/claude-review.yml` | The reviewer, as a reusable workflow |
| `tests/` | Fixture tests for the scripts and the review workflow's backstop, run by this repo's CI |

## Join a repo to the factory

1. Copy `plugins/factory/templates/FACTORY.md` to the repo root and fill in every value.
   Its presence is what turns the hooks and scripts on.
2. Enable the plugin. Project threads get it only from **Project settings → Plugins**;
   local sessions get it from the repo's `.claude/settings.json`:

   ```json
   {
     "extraKnownMarketplaces": {
       "factory": { "source": { "source": "github", "repo": "peterargue/factory" } }
     },
     "enabledPlugins": { "factory@factory": true }
   }
   ```

3. Add the review caller, `.github/workflows/claude-review.yml`:

   ```yaml
   name: Claude PR Review
   on:
     pull_request:
       types: [opened, synchronize, ready_for_review]
       branches: [main, "feature/**"]
   permissions: { contents: read, pull-requests: write, id-token: write }
   concurrency:
     group: claude-review-${{ github.head_ref }}
     cancel-in-progress: true
   jobs:
     review:
       uses: peterargue/factory/.github/workflows/claude-review.yml@v0.1.0
       secrets: inherit   # CLAUDE_CODE_OAUTH_TOKEN, from `claude setup-token`
   ```

   GitHub only lets a private reusable workflow be called from repos with the same
   owner, so this works for repos under `peterargue`, and only after this repo's
   **Settings → Actions → Access** allows it. A repo under another owner, such as
   `tsglobal-ca/platform`, keeps its own copy of the workflow instead. The called check
   reports as `review / Claude review`, so a ruleset that required `Claude review`
   must be updated to the new name.

4. Copy `plugins/factory/templates/factory-signal.yml` to `.github/workflows/` and set
   its two workflow names to this repo's CI and review workflows. Then set up the PR
   tender (next section).

## Event-driven PRs

Nothing in the factory polls GitHub. Two paths cover every PR:

- **Attended.** The session that built a PR ships it with `pr-cycle.sh ship <n>`, which
  marks it ready and labels it `factory:attended`, then subscribes to the PR's activity
  and ends its turn. CI results and reviews arrive as events, and the session runs
  `pr-cycle.sh status <n>` once per event; exit `7` means "not settled, end the turn".
  A local CLI session, which has no event channel, uses `ship <n> --wait` instead.
- **Unattended.** When no session holds a PR (it ran `pr-cycle.sh handoff <n>`, or a
  person opened it), the repo's signal workflow labels it `factory:ci-red` or
  `factory:review-findings` when CI goes red on its head or a review of its head has
  findings (the bot's marker, or a person's "request changes"). That label starts a
  scheduled task with a GitHub trigger, which runs `factory:tend-pr`: one root-caused fix
  round, recorded as a `factory:tend-round-<k>` label and a PR comment. Past
  `ci.max_fix_rounds` the PR is labelled `factory:needs-human` and left alone. The tender
  never merges.

Labels are the only shared state. `factory:attended` and `factory:needs-human` keep the
signal workflow off a PR; removing `factory:attended` hands a PR to the tender.

### Set up the tender (once per repo)

Scheduled-task GitHub triggers fire on pull request, issue and release events only, which
is why the signal workflow turns CI and reviews into labels. The Claude GitHub App must be
installed on the repo. At [claude.ai/code/routines](https://claude.ai/code/routines),
**New task**:

- **Name**: `<repo>: tend flagged PRs`
- **Prompt**: `A pull request in this repository was labelled for the factory. Use the
  factory:tend-pr skill on the pull request named in the GitHub event that started this
  run, and follow it exactly.`
- **Repository**: the repo (its `.claude/settings.json` enables the plugin). The default
  environment is enough unless the gate needs more.
- **Trigger**: GitHub event, *Pull request → labeled*, filters *Labels is one of*
  `factory:ci-red`, `factory:review-findings`, and *Is draft* `false`.
- **Connectors**: none.

Then set `ci.tender: factory:tend-pr` in the repo's `FACTORY.md`.

## Changing the factory

Change machinery here and repo facts in that repo's `FACTORY.md`. Bump `version` in
`plugins/factory/.claude-plugin/plugin.json` and tag the release; a repo moves to it by
updating its plugin and its workflow `@<tag>`.
