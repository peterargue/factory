# Reading a factory skill in any repo

The factory skills were first written in `tsglobal-ca/platform`, and their examples
still use that repo's literal values. Those literals are examples, not rules. In any
repo, including that one, the value to use is the one in the repo's own `FACTORY.md`.
When a skill names one of the literals on the left, read the key on the right.

| A skill says | Use `FACTORY.md` |
|---|---|
| `make ci-all`, "the gate" | `commands.gate` |
| `make test`, `make lint`, `make db-up`, `make test-integration` | `commands.delegate_safe` |
| "from `src/`" | `commands.cwd` |
| `make ports` | `commands.ports` |
| `make migrate-next`, migration numbers | `commands.sequence_numbers` |
| `make db-destroy`, teardown | `commands.teardown` |
| `make ports && docker compose config` | `worktrees.isolation_check` |
| `.claude/worktrees/<token>` | `worktrees.path` |
| `feature/<name>`, `feature/<topic>-<n>` | `branches.feature_prefix`, `branches.stacked` |
| `spec/<change-name>` | `specs.spec_branch` |
| ~500 changed lines | `branches.pr_size_target` |
| Linear, `TAI-<n>`, `gitBranchName`, `Maintenance` | `tracker.*` |
| OpenSpec, `/opsx:*`, the stage-3 audit | `specs.system`, `specs.audit_required` |
| `.claude/scripts/check-change-docs.sh` | `specs.docs_check` |
| `openspec/config.yaml` and its invariants | `repo.product_context`, `invariants` |
| the three SPAs and their `CLAUDE.md` briefs | `FACTORY.md` § Invariants |
| `Claude review`, the advisory SPA or guard checks | `ci.review_check`, `ci.advisory_checks` |
| Peter, "the user" as approver | `repo.owner` |
| the approval tiers, "standing" and "plan grant" | `approvals` |
| merging to `main` deploys | `repo.default_branch`, `deploy.on_merge_to_default` |
| `~/dev/tsglobal-rollout`, `run-job.sh`, `prod-read.sh`, `tf-read.sh`, `tf-apply-saved.sh` | `deploy.rollout_folder`, `deploy.rollout_wrappers` |
| office, Grafana, terraform, sheet imports | `FACTORY.md` § Deploy |
| codev-memory, `log-guard-denial` | `FACTORY.md` § People and channels |
| the authenticated browser, the change docs as singletons | `FACTORY.md` § Shared singletons |

A slot set to `none` means the step does not apply in this repo: skip it rather than
inventing an equivalent. A literal that is missing from this table and from `FACTORY.md`
is a gap in the contract. Say so in your report instead of guessing, so the contract
gets the key.

The CI scripts are the plugin's own, not the repo's:

- `.claude/scripts/wait-ci.sh` is `${CLAUDE_PLUGIN_ROOT}/scripts/wait-ci.sh`
- `.claude/scripts/pr-review-comments.sh` is `${CLAUDE_PLUGIN_ROOT}/scripts/pr-review-comments.sh`

Run them from inside the repository: they find it from the current directory and refuse
one without `FACTORY.md`.
