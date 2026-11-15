# FACTORY.md — this repo's contract with the software factory

The factory is the repo-agnostic machinery that takes work from an idea to production:
the `factory` plugin's skills, hooks and scripts, and its reusable review workflow.
**The machinery knows nothing about this repo.** Every fact it needs about *this* repo is
in this file, under the fixed headings below.

Rules for this file:

- **One fact, one home.** A value lives here only if the factory needs it and no other
  file already owns it. Where a fact has a home (`CLAUDE.md`, a product-context file, a
  script), name the home instead of copying it, and the home wins.
- **Values, not method.** How the factory works belongs in its skills. If you are writing
  a paragraph of reasoning here, it belongs in a skill or `CLAUDE.md`.
- **If a value is wrong, fix it here**, not in a delegate's brief.
- Headings are the contract. Keep every heading and key, in order; write `none` for a
  slot this repo does not use rather than deleting it.

Every value below is current as of <date>.

## Contract

```yaml
factory: 1                       # contract version; bump when a heading is added or renamed

repo:
  github: <owner>/<repo>
  default_branch: main
  instructions: CLAUDE.md        # how we build; read before any work
  product_context: <path>        # what we build, and the invariants
  owner: <name>                  # who approves plan grants and merges spec PRs
  ai_attribution: allow          # `deny` turns on the plugin's attribution hook

tracker:
  system: linear                 # linear | github | none
  team_key: <KEY>                # issues are <KEY>-<n>
  branch_from: gitBranchName     # how a work branch is named so the PR auto-links
  done_on_merge: false           # does a merged PR close its issue?
  catch_all_project: <name>      # where work with no feature home goes

specs:
  system: openspec               # openspec | none
  audit_required: true           # fresh-context audit before any code
  docs_check: none               # script CI runs over the change docs, if any
  spec_branch: spec/<change-name>

branches:
  feature_prefix: feature/       # CI and review must trigger on PRs into this prefix
  stacked: feature/<topic>-<n>   # a sub-PR that depends on an unmerged one
  pr_size_target: 500            # changed lines, excluding generated files and lockfiles

worktrees:
  path: .claude/worktrees/<token>
  isolation_check: none          # command proving two worktrees don't share state

commands:
  cwd: .                         # where the commands below run
  delegate_safe: [<test>, <lint>]   # what a delegate may run in its worktree
  gate: <full check>             # orchestrator only, post-merge; must match CI
  ports: none                    # the source of truth for dev ports, if any
  sequence_numbers: none         # how to take the next migration number, if any
  teardown: none                 # what to run before removing a worktree

ci:
  wait: factory:wait-ci          # the plugin's scripts/wait-ci.sh <pr>
  review_comments: factory:pr-review-comments
  review_check: review / Claude review   # caller job / reusable job name
  review_workflow: .github/workflows/claude-review.yml   # the thin caller
  advisory_checks: []            # run but not required; still real

invariants: <path>#<heading>     # re-walk at every integration gate

approvals: CLAUDE.md#Approvals   # standing / plan grant / never

deploy:
  on_merge_to_default: none      # workflow that deploys on merge, if any
  rollout_folder: none           # where plan-grant steps run, if anywhere special
  rollout_wrappers: []
```

## Approval tiers

Name where the tiers are defined and any repo-specific rule on top of them, such as who
merges a spec PR.

## Invariants

Name where the invariants live. Add only what has no other home, such as trust
boundaries between surfaces.

## Shared singletons

Things only one agent may hold at a time: the change docs, a browser session, a global
lock, a shared database. Write `none` if there are none.

## Deploy

What a merge deploys, and which steps a merge does not do and so need a plan grant.

## People and channels

Who approves, who agents may message, and where guard refusals and lessons are logged.
