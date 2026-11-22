---
name: run-rollout
description: >-
  Use when a change's merged code needs production steps to go live: terraform apply,
  real job runs, backfills, trigger pauses, Grafana provisioning, installs on office,
  sheet imports. Gets the user's single approval for the whole plan and runs it on
  their Mac. Also use when resuming a rollout that stopped part-way.
---

> **Factory skill.** Before anything else, read `FACTORY.md` at the repository root; if
> there is none, stop and say this repo has not joined the factory. Literal values below
> (commands, branch names, tracker keys, people) are `tsglobal-ca/platform`'s and are
> examples: use this repo's values from `FACTORY.md`, mapped in
> `${CLAUDE_PLUGIN_ROOT}/reference/repo-values.md`.

# Run a production rollout

The code is merged and deployed; what remains is the rollout group in `tasks.md`
(usually the last one). This skill runs it with **one approval from the user per
plan**. The approval tiers are in `CLAUDE.md` → "Approvals"; this skill is how the
plan-grant tier works in practice.

**Why it exists.** Every rollout until 2026-11-14 stalled in the same place: the Mac's
auto-mode guard, which judged each production step against the user's wording and refused
many after they had approved (55 logged refusals in 2026-11). So rollouts now run in the
**rollout folder**, `~/dev/tsglobal-rollout`, made by `infra/rollout/setup.sh`. Its
`.claude/settings.local.json` holds fixed permission rules that allow the rollout tools,
and permission rules resolve before the guard, so nothing there is refused. The approval
is still the user's, once per plan, but it is for them, not for the guard: this skill puts
the whole plan in front of them once, before the first write, and then runs it without
asking again.

**That makes the approval a rule you keep, not one the guard checks.** Never start a
session in the rollout folder for anything but a plan the user approved, and never for
coding.

## 1. Read the plan

Read the change's rollout tasks and `design.md`. List every step, and mark each one:

- **standing**: prod reads, dry runs, `terraform init`/`plan`, merging your green PR. Do it
  without asking.
- **plan grant**: any production write. It goes in the approval line.
- **never**: secret values, destroys. If the plan needs one, the design is wrong or a
  human has to do it. Stop and say so.

A step that **reads Secret Manager values** is a plan-grant step even if it writes nothing
(`observability/grafana/provision.sh` reads two Grafana tokens). Name the read in the line.

## 2. Do every standing step first

Before asking anything, so the line you post is complete and final:

1. **Auth.** On the Mac, `gcloud auth print-access-token >/dev/null`. If it fails, the
   user must run `gcloud auth login` themselves (the guard refuses it from an agent). Say
   so in the same message as the approval line, not later.
2. **`terraform plan`** for any terraform step. Read the whole plan. Everything it would
   change goes in the line by name, including drift unrelated to this change (a sink
   filter line from another merged feature, say). If it destroys or replaces anything,
   name each resource, or stop if the design doesn't expect it.
3. **Dry runs** of every job, backfill and import the plan runs for real.
4. **Pre-flight reads** the tasks list. If one contradicts the design (a count, a SKU set,
   an account), stop. That is a spec problem: fix the design, re-audit if the change is
   substantial (per `CLAUDE.md`), then come back here.

## 3. Ask once

Post the plan as a numbered list of **the commands you will run**, in order, each with a
few words on what it does, and ask the user to approve it. Include everything the rollout
needs, the post-deploy reads and first-run checks too, so nothing comes back to them
later. Any reply that approves it ("approved", "go") is enough; it doesn't have to quote
anything.

1. `../.claude/scripts/tf-apply-saved.sh kyro.tfplan`: 2 IAM members, platform_logs sink
   filter adding lc-daily-kyro and licensee-sync
2. `gcloud scheduler jobs pause lc-daily-kyro-trigger --location us-central1`
3. `.claude/scripts/run-job.sh --creds lc:kyro lc-sales daily --account kyro`
4. `.claude/scripts/prod-read.sh -c "select …"`: confirm the rows landed

Rules for the plan:

- Use the wrapper scripts (`run-job.sh`, `prod-read.sh`, `tf-read.sh`, `tf-apply-saved.sh`)
  and the commands in `infra/rollout/settings.local.json`. Those run without a prompt. Any
  other command will prompt the user, so list it as a step they will tap through.
- Name targets as they appear in the commands: job, trigger and resource names.
- Ask in a plain message or a decision card, either works now.

## 4. Run it in the rollout folder

Start the Remote Control session with `folder` set to the rollout folder as
`list_devices` lists it (`~/dev/tsglobal-rollout`) and `message_id` set to the user's
approval message. If the folder isn't listed, ask the user to run
`infra/rollout/setup.sh` from their platform checkout and allow the folder, in the same
message as the plan, so it is still one ask.

Put this in the brief, word for word: "Send no Slack messages, emails or comments to
anyone, and commit or push nothing. Report results back to this thread only." The cloud
thread owns every message and every repo write; a Mac session that posts on its own
duplicates or breaks the group-chat-only rule. Findings for the knowledge base come back
in the report, and the thread writes them through GitHub: the guard refuses a push from
the Mac, which leaves the user a command to run.

In the session:

1. `git fetch origin main`, then `git checkout --detach origin/main`. The folder holds no
   work of its own; it always runs the merged code.
2. Run the steps in the order of the plan. Between steps, check the command against the
   one the plan listed. A changed terraform plan or a different job argument is a new step.
3. **Run every command bare**: no env prefix, `&&` chain, pipe, `>` or `$(…)`. A permission
   rule matches each part of a compound command separately, so one unlisted part makes
   the whole command prompt. The wrappers fetch tokens and secrets themselves and take
   their own output flags, so there is nothing to wrap them for.

**Terraform applies go through `tf-apply-saved.sh <file>.tfplan`**, run from `terraform/`
on the plan saved with `tf-read.sh plan`, never a bare `terraform apply` (the folder's
settings send any direct `terraform` call to a prompt). It refuses a plan that destroys or
replaces a resource (exit 3); that plan is the user's to apply.

**Tailscale.** `ssh office` may print a `login.tailscale.com` link and block. Background
it with output to a file, then send the user **only the link**. Don't ask them to run the
command.

## 5. When something changes or is refused

- **The plan grew** (a pre-flight found more rows, a SKU, a resource): finish what was
  approved and still applies, then ask for **one new line covering only the new steps**.
  Never re-ask for steps already approved.
- **A step prompted or was refused in the rollout folder:** the command isn't covered by
  `infra/rollout/settings.local.json`, or it was wrapped. Don't reword and retry. Rerun it
  bare if it was wrapped; otherwise say which command and why in your report, and if it
  will recur, open a PR adding it to the settings file (the user re-runs `setup.sh` to
  pick it up). The weekly review reads these.
- **A step failed:** stop, report what ran, what didn't, and the state it left, before
  any retry that writes.

## 6. Finish

- **Run the change's `First-run checks` group**, if it has one, once the steps have run
  and again after the first scheduled run if the group says so. They are reads, so standing.
  If the change has infrastructure, a deploy, a scheduled job or an office service and no
  such group, check the first real run yourself anyway: the execution and its flags, the
  service answering, the VM booting. Seven first runs failed in one week of 2026-11 (CI
  runner boot three times, deploy args twice, the triage bot twice). A failed check is
  fixed before the rollout is reported done.
- Tick each rollout task in `tasks.md` with the evidence: counts, run ids, the plan
  summary.
- Report to the user in one message: what ran, the numbers, anything left for a person.
- Then sync and archive the change (see `execute-issue` step 8), and move the Linear issue
  to Done only when nothing in it is left.

## Red flags

| Thought | Reality |
|---|---|
| "The rollout folder lets it through, so I can start a session there early" | The folder trusts your discipline. Only an approved plan starts a session there. |
| "I'll do this coding fix in the rollout folder, it's quicker" | Never. Coding runs in the cloud or the user's normal checkout. |
| "I'll ask for terraform now and the jobs later" | One ask per plan. Do the plan and the dry runs first so the list is complete. |
| "I'll start `gcloud auth login` for them" | The guard refuses it. The user runs it. Check the login with `gcloud auth list`, never by printing a token. |
| "This step is a one-off script, or needs `< file`" | The folder allows only the commands in its rules, run bare. Make it a wrapper call or a listed command. A script with no wrapper is not covered: say so in the plan, so the approval names it and the user knows it may prompt. |
| "The plan has one extra step, it's harmless" | The user didn't approve it. Ask for it, once, with anything else new. |
