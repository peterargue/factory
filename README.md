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
| `plugins/factory/skills/` | `spec-feature`, `spec-issue`, `execute-issue`, `implement-feature`, `run-rollout`, `review-sessions`, invoked as `factory:<name>` |
| `plugins/factory/hooks/` | `deny-stale-pr` (no PR from a head behind its base), `advise-ci-watch` (watch CI with `wait-ci.sh`, never a poll loop), `deny-ai-attribution` (on when `FACTORY.md` sets `ai_attribution: deny`). Each hook does nothing in a repo without `FACTORY.md` |
| `plugins/factory/scripts/` | `wait-ci.sh` (exit code is the CI verdict), `pr-review-comments.sh` (all three review endpoints), and the two verdict helpers they call |
| `plugins/factory/templates/FACTORY.md` | The contract a new repo fills in |
| `.github/workflows/claude-review.yml` | The reviewer, as a reusable workflow |
| `tests/` | Fixture tests for the scripts and the review workflow's backstop, run by this repo's CI |

## Join a repo to the factory

1. Copy `plugins/factory/templates/FACTORY.md` to the repo root and fill in every value.
   Its presence is what turns the hooks and scripts on.
2. Enable the plugin for everyone working in the repo, in its `.claude/settings.json`:

   ```json
   {
     "extraKnownMarketplaces": {
       "factory": { "source": { "source": "github", "repo": "<owner>/factory" } }
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
       uses: <owner>/factory/.github/workflows/claude-review.yml@v0.1.0
       secrets: inherit   # CLAUDE_CODE_OAUTH_TOKEN, from `claude setup-token`
   ```

   GitHub only lets a private reusable workflow be called from repos with the same
   owner, and only after this repo's **Settings → Actions → Access** allows it. The
   check then reports as `review / Claude review`, so a ruleset that required
   `Claude review` must be updated to the new name.

## Changing the factory

Change machinery here and repo facts in that repo's `FACTORY.md`. Bump `version` in
`plugins/factory/.claude-plugin/plugin.json` and tag the release; a repo moves to it by
updating its plugin and its workflow `@<tag>`.
