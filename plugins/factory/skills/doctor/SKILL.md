---
name: doctor
description: >-
  Check that a repo still conforms to the software factory: FACTORY.md against the
  plugin's current template, every file and heading it names, the CI and review
  workflows and their triggers, the branch ruleset's required checks, the review
  secret, OpenSpec, and the tracker team and project. Use when asked "is this repo
  set up right", after upgrading the factory plugin, after renaming a CI job or
  workflow, when a factory skill fails on a missing value, or as the last step of
  factory:init.
---

# Check a repo against the factory

`factory:doctor` answers one question: will the factory's skills, hooks and scripts
work in this repo as it is now? It reads and reports. It changes nothing unless the
person asks for fixes, and then each fix is an ordinary PR.

## 1. Run the script

From inside the repo:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh --remote
```

`--remote` adds the GitHub checks (ruleset, required checks, review secret) and needs
`gh`; leave it off to check files only. Each line is `FAIL`, `WARN`, `NOTE` or `ok`
with a check id; the exit is 1 when anything FAILs. The script covers:

| Area | Checks |
|---|---|
| Contract | `## Contract` block present; `factory:` version and every key match `templates/FACTORY.md`; headings present and in order; no `<placeholder>` or `{{placeholder}}` left; "current as of" within 90 days |
| Repo | `repo.github` is `origin`; `repo.default_branch` is origin's HEAD |
| Paths | every path the contract names exists, and `file#Heading` anchors have that heading; `factory:<name>` values name something this plugin ships |
| Specs | `openspec/config.yaml`, `openspec/specs`, `openspec/changes`, the `/opsx` commands |
| Workflows | the review runs on PRs into the default branch and the feature prefix, on `ready_for_review`, and reports `ci.review_check`; a caller is on this plugin's version, a rendered copy is current; some other workflow runs CI on both bases; the gate's command appears in CI; every `ci.advisory_checks` name is a real job |
| GitHub (`--remote`) | an active ruleset covers the default branch with deletion, non-fast-forward and required checks; it requires `ci.review_check`; every required check is a job some workflow reports; advisory checks are not required; `CLAUDE_CODE_OAUTH_TOKEN` exists |
| Plugin | `.claude/settings.json` enables `factory@factory` |

A NOTE is something it could not check where it ran (no YAML reader, no admin access
to list secrets) or a heuristic worth a look. Say which; do not count it as a problem.

## 2. Check what the script cannot

- **Tracker.** `tracker.system: linear`: with the Linear tools, confirm the team
  `tracker.team_key` exists and `tracker.catch_all_project` is a project of that team.
  `github`: the repo has issues enabled (`gh api repos/<o>/<r> --jq .has_issues`).
  No tracker tools in this session: say the tracker was not checked.
- **Plugin in project threads.** If you are running in a project thread and the
  `factory:` skills loaded, the plugin is enabled there; say so. Nothing in the repo
  can show this.
- **Values that are wrong, not missing.** Skim the contract for values that no longer
  match the repo: a `commands.gate` whose targets are gone from the Makefile, a
  `serve` command that no longer exists, an `owner` who has left. Read, do not run,
  the commands: running the gate is `gate-stamp.sh`'s job.

## 3. Report

Lead with the verdict: **conforms**, **conforms with warnings**, or **does not
conform**, then the FAILs, each with the fix in one line, then WARNs. Skip the `ok`
lines unless asked. Where a fix is a repo change (a missing key, a trigger, a
re-rendered review workflow), offer to make it as one PR. Where it is a setting
(ruleset, secret, Project settings plugin, Actions access), say who has to do it and
link the settings page.

When the plugin itself is wrong (a check that fails on a correct repo, a template
key no skill reads), the fix belongs in `peterargue/factory`, not the repo: say so.
