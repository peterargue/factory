---
name: review-sessions
description: >-
  Weekly workflow review: read the past week's guard refusals, saved lessons, PRs and
  project threads, find friction that happened more than once, and turn it into one
  small PR to the skills or CLAUDE.md, plus exact autoMode rule text for Peter. Runs
  from a scheduled task every Monday; also use when Peter asks to review sessions or
  improve the workflow.
---

> **Factory skill.** Before anything else, read `FACTORY.md` at the repository root; if
> there is none, stop and say this repo has not joined the factory. Literal values below
> (commands, branch names, tracker keys, people) are `tsglobal-ca/platform`'s and are
> examples: use this repo's values from `FACTORY.md`, mapped in
> `${CLAUDE_PLUGIN_ROOT}/reference/repo-values.md`.

# Review the week's sessions

The loop that keeps the workflow improving. **Capture** happens all week without this
skill: `log-guard-denial` (a `PermissionDenied` hook from peterargue/codev-memory)
records every auto-mode refusal, and sessions save lessons to project memory and
codev. This skill is the **review** and the **change**. It runs once a week, and its
output is something Peter can accept in a minute: one PR and a short message.

## Rules that hold every run

- **Change only through a PR.** Never edit skills, CLAUDE.md or settings directly on
  `main`. The PR is Peter's review of the change; merge it yourself only once its
  checks are green and its review is read, as for any PR you open.
- **Never touch `~/.claude/settings.json`.** A guard fix is rule *text* that Peter
  pastes himself. Never propose loosening a Never-tier item (CLAUDE.md, Approvals).
- **Two occurrences or it waits.** A one-off goes in the report as "watching", not
  into a change. Something that happened twice in one session counts as one.
- **Elise's skills stay hers.** The skills under `src/.claude/skills/` encode her
  process. A change there is labelled in the PR as a change from her process, says
  how it differs and why, and needs Peter's explicit yes before merge: leave that PR
  open for him, even when green.
- **Small.** One PR, aim for under ~150 changed lines. If the week found more, take
  the highest-cost items and list the rest as "next week".
- **No secrets in the report.** Quote rule names and command shapes, never values.

## 1. Gather the week (last 7 days, standing-tier reads only)

| Source | How | What to pull out |
|---|---|---|
| Guard refusals | `git -C ~/codev-memory pull` (cloud: `/home/user/codev-memory`), then read `logs/guard-denials/*-<month>.jsonl` | Count by `reason` (the rule in brackets) and by command shape. Mark each as *should have passed* (Peter had approved it, or it is standing-tier) or *correct refusal* |
| Saved lessons | Project memory files modified this week (`/tmp/claude/memory/team/silo`); codev entries of type `lesson` (`git log --since` on the codev-memory repo) | Recurring traps, workarounds, "next time do X" |
| PRs | Merged and open PRs on tsglobal-ca/platform from the week: review markers (`outcome=findings` vs `clean`), pushes after ready, red CI runs and why | Findings of the same kind on several PRs; CI red for reasons outside the diff |
| Reviewer misses | Each `fix(...)` PR merged this week: find the PR that introduced the bug (`git log` on the fixed lines) and its review marker for the merged head | A **miss** is a fix for a bug introduced by a PR reviewed `clean`. Group misses by kind (runtime image, deploy args, real data shapes, first boot, plain logic). A kind seen twice goes into the reviewer prompt's Phase 2 checklist in `claude-review.yml` |
| Threads | `list_threads` with `since` a week ago; read the ones that were `blocked` or ran long | Each time a session asked Peter for something: could it have done it itself? did it ask twice? how long did it wait? |

If a source is unreachable, say so in the report and carry on with the rest.

## 2. Find the friction

Group what you found into patterns and give each a cost: Peter's time first (an ask, a
re-ask, a command he had to run), then wall-clock waiting, then tokens. For each
pattern with two or more occurrences, decide its fix:

| Fix | When | Output |
|---|---|---|
| Skill or CLAUDE.md edit | Agents did the wrong thing, or the right thing slowly, because the instructions were missing, wrong or stale | Edit in the PR |
| autoMode rule | The guard refused something Peter had approved, or something standing-tier | Exact rule text, naming the default rule it overrides, for Peter to paste |
| Script or hook | A check agents keep doing by hand, or a guard that should be mechanical (as `tf-apply-saved.sh` was) | Linear issue in `Maintenance`, or a small script in the PR if it is under the size limit and has its check script |
| Nothing | Correct refusals, one-offs, external outages | Listed in the report only |

Also check **last week's changes**: for each, did the pattern it targeted recur? If it
did, say so, and fix or revert it rather than piling a second change on top.

## 3. Record the numbers

Append one row to `/mnt/project-files/workflow/review-metrics.md` (create it with this
header if missing), so trends are visible across weeks:

| Week ending | Guard refusals (should have passed / total) | Asks to Peter | Re-asks | PRs merged | PRs with review findings | Reviewer misses | Red CI runs on PRs | Hours threads sat blocked on Peter |

Count the same way every week; if you change a definition, note it under the table.

### The scorecard

The scorecard is the factory's weekly numbers on one dashboard: PRs merged, first-pass
CI, review findings and rework pushes per PR, asks of Peter, and usage-window hits.
`scorecard.sh` computes them; you only gather what it cannot reach and publish.

1. **Save the threads.** For every thread with activity in the week (`list_threads`
   with `since` = the week's Monday), save its `read_thread` result (all pages, oldest
   first, merged into one `messages` list) as `<scratch>/threads/<thread_id>.json`. When
   a page is too big to return and lands in a file, take the JSON line from that file.
   Bodies may be cut to their first 300 characters, but keep `id`, `author`,
   `created_at`, and status and activity bodies whole: decision cards are activities.
2. **Add limit events.** If the project keeps a usage ledger with `rate_limit_event`
   records, add one line per session that was refused for the window in the week to
   any saved thread as `{"author":"agent","created_at":…,"body":"usage limit reached (ledger)"}`.
3. **Run it** from the repo checkout, for the Monday-to-Monday UTC week that just ended:
   `"${CLAUDE_PLUGIN_ROOT}"/scripts/scorecard.sh --since <Mon> --until <next Mon> --logs --threads <scratch>/threads > <Mon>.json`.
   Definitions are in `scorecard.sh --help`; never count by hand.
4. **Store the week** at `/mnt/project-files/workflow/scorecard/<Mon>.json`, beside the
   earlier weeks.
5. **Publish.** `scorecard-dataset.sh weeks <all week files>` and `scorecard-dataset.sh
   prs <all week files>` make the two dashboard files. Upload each as an asset of the
   scorecard dashboard (the scheduled task's prompt names it, or else `FACTORY.md`'s
   People and channels section), point datasets `weeks` and `prs` at the new urls with a fresh
   `updated`, then delete the old assets. Read the dashboard's `check` document after.
6. In the message to Peter, give the week's six numbers against the previous week and
   the baseline, in one line each, and the dashboard link.

## 4. Deliver

1. Write the report to `/mnt/project-files/workflow/reviews/<YYYY-MM-DD>.md`: the
   numbers, each pattern with its evidence (thread links, PR numbers, refusal
   counts), the fix chosen, last week's changes and whether they worked, and the
   "watching" list.
2. Open the PR, if there is one, on a branch `workflow-review/<YYYY-MM-DD>`, opened as
   a draft and marked ready after the last push. The body links the report and lists
   each change with the pattern it fixes.
3. Post **one** message to Peter in the "Streamline our agent workflow and approvals"
   thread: the two or three changes that matter most, the PR link, any autoMode rule
   text as a quote he can paste, and anything that needs his decision. If the week
   found nothing worth changing, say so in one line and post the numbers.

## Red flags

| Thought | Reality |
|---|---|
| "This happened once but it was painful" | Watch it. Two occurrences or it waits |
| "I'll just add the autoMode rule to his settings" | Never. Rule text goes to Peter |
| "The refusal was wrong, loosen the rule" | First check whether Peter's own words named the action. Often the fix is the ask, not the rule |
| "Several small fixes, several PRs" | One PR a week. Peter reviews one thing |
| "Last week's change didn't help, add another" | Fix or revert it first |
