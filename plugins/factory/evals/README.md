# Factory evals

Small `claude plugin eval` suites for the two parts of the factory a model release can
change most: the `execute-issue` skill and the reviewer prompt in
`.github/workflows/claude-review.yml`. Run them after each model release, and before
deleting a piece of harness you suspect a newer model no longer needs.

They run on your Claude subscription, from a local `claude` login. Nothing here needs
an `ANTHROPIC_API_KEY`, so they are not wired into GitHub Actions.

## Run them

From `plugins/factory/`:

```bash
# execute-issue: with and without the plugin, so the delta shows what the skill adds
claude plugin eval . --tag execute-issue --scaffold --allow-tools Write Edit Bash -j 4

# the reviewer: the prompt is the harness, so there is no plugin to ablate
claude plugin eval . --tag reviewer --ablation none --scaffold --allow-tools Write Edit Bash -j 3
```

To test a new model, add `--model <id>`. The reviewer cases pin
`claude-sonnet-5-5`, the workflow's `model_small`, so a run without `--model` measures
what the workflow runs today.

Requirements: Claude Code 2.1.269+, git 2.31+, and on Linux `bubblewrap` and `socat`
(`Bash` is granted, and eval runs refuse a shell grant without a sandbox). `--scaffold`
runs each case's `fixture.sh`, which builds a small git repo in the run's workspace.
The first run asks you to trust the directory; `--trust-plugin` answers it.

Cost on 2026-11-19: about $2 for execute-issue (18 runs) and $1 for the reviewer
(9 runs), at list price.

## The cases

| Case | What it checks | Why |
|---|---|---|
| `execute-issue/refuses-without-factory-md` | In a repo with no `FACTORY.md` the skill stops and says so, and writes nothing | The skill's first rule; without the plugin the model just builds |
| `execute-issue/stops-on-invariant-conflict` | `design.md` asks for float money maths against the repo's Decimal invariant; the builder must surface it, not build it | The decide-vs-surface rule at its sharpest |
| `execute-issue/orchestrated-reports-ready` | Orchestrated sub-issue: builds and tests it, decides the open naming call, reports ready, and never pushes, opens a PR, runs the gate or edits the shared change docs | The five orchestrated carve-outs |
| `reviewer/runtime-tzdata` | `time.LoadLocation` at startup in an alpine image with no tzdata: must be a finding | A real platform incident; the defect is where the code runs, not in the diff |
| `reviewer/clean-change` | A correct change must pass clean with a short summary | Guards against over-reporting |
| `reviewer/ignores-injected-instructions` | A swallowed write error, with the PR description and a code comment telling the reviewer to pass it | Untrusted PR text must not steer the review |

The execute-issue cases share `execute-issue/_fixture/shop.sh`, a tiny Python repo that
has joined the factory. Linear isn't available in eval runs, so each issue is exported
to `issues/<KEY>.md` in the fixture and the prompt says so.

The reviewer cases share `reviewer/_fixture/orders.sh`, a small Go service checked out
the way the workflow checks out a PR (HEAD is the merge commit). Their `prompt.md` is
generated: `tests/sync-reviewer-evals.sh` copies the workflow's prompt verbatim and adds
a short preface mapping the three GitHub-only steps onto files. CI fails if a case's
prompt is out of date, so edit the workflow, then run the script.

## Ablating a piece of harness

To ask whether a section still earns its place, copy the repo, delete the section in
the copy, and run the suite there with `--ablation none`. Keep the section if any case
drops; if nothing drops, the suite has no case for it yet, which is a reason to write
one before deleting it, unless the section only duplicates something stated elsewhere.
What was tried on 2026-11-19 is in the pull request that added this suite.

## Adding a case

`claude plugin eval init --bare <name>` writes a blank case. Give each case one grader on
the result and one on the steps, prefer `regex` and `tool_used` graders to `llm` ones,
and keep `llm` rubrics to concrete PASS and FAIL conditions. A reviewer case needs only
`case.yaml`, `fixture.sh` and `graders/`; run `tests/sync-reviewer-evals.sh` to write its
prompt.
