#!/usr/bin/env bash
# Turn saved scorecard.sh outputs into the two files the scorecard dashboard reads.
#
#   scorecard-dataset.sh weeks <week.json>...   one row per week, oldest first
#   scorecard-dataset.sh prs   <week.json>...   one row per merged PR, newest first
#
# Each file is one `scorecard.sh` output. Prints `{rows, meta}` JSON: `meta` says
# which script made the rows, so a reader of the dashboard can trace the numbers.
# A week whose `until` is later than the run's own start is marked partial.
set -euo pipefail
mode=${1-}; shift || true
case $mode in weeks|prs) ;; *) echo "usage: scorecard-dataset.sh weeks|prs <week.json>..." >&2; exit 2 ;; esac
[ $# -gt 0 ] || { echo "scorecard-dataset: no week files given" >&2; exit 2; }

jq -s --arg mode "$mode" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  def wk: .since[0:10];
  if $mode == "weeks" then
    { rows: (sort_by(.since) | map(.metrics as $m | {
        week: wk, week_end: .until[0:10], partial: (.partial // false), repo,
        prs_merged: $m.prs_merged, into_default: $m.into_default,
        first_pass_rate: $m.first_pass_ci.rate, first_pass_passed: $m.first_pass_ci.passed, first_pass_of: $m.first_pass_ci.of,
        findings_total: $m.review_findings.total, findings_per_pr: $m.review_findings.per_pr,
        prs_with_findings: $m.review_findings.prs_with_findings,
        rework_total: $m.rework_pushes.total, rework_per_pr: $m.rework_pushes.per_pr,
        prs_with_rework: $m.rework_pushes.prs_with_rework,
        asks: $m.asks_of_owner.asks, ask_median_wait_hours: $m.asks_of_owner.median_wait_hours,
        threads_read: $m.asks_of_owner.threads_read,
        usage_hits: $m.usage_window_hits.total })),
      meta: [{label: "Made by", value: "peterargue/factory plugins/factory/scripts/scorecard.sh, one run per week"},
             {label: "Definitions", value: "scorecard.sh --help"}] }
  else
    { rows: ([.[] | wk as $w | .prs[] | {
        week: $w, number, title, base, merged_at,
        first_pass, failed_first: (.failed_first | join(", ")), rework_pushes, findings, findings_rounds }]
        | sort_by(.merged_at) | reverse),
      meta: [{label: "Made by", value: "peterargue/factory plugins/factory/scripts/scorecard.sh, one run per week"}] }
  end' "$@"
