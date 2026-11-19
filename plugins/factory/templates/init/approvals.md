## Approvals

Side effects fall into three tiers. Ask {{owner}} only for the second, and once per plan.

| Tier | Covers | Granted by |
|---|---|---|
| **Standing** | Reads, dry runs, merging a PR you opened once its required checks are green and its review is read{{merge_deploys}} | Always on |
| **Plan grant** | Production writes and any step outside the merge: {{list them}} | One approval from {{owner}} of the listed commands, per plan. See `factory:run-rollout` |
| **Never** | Printing, logging or committing a secret, deleting production data outside a plan, `--admin` merges, force pushes | Not grantable in conversation |

A spec PR is the exception to the merge rule: {{owner}} merges it, as their review of intent.
