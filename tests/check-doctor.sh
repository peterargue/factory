#!/usr/bin/env bash
# doctor.sh passes a repo built from factory:init's templates, and names the
# breakage when one is introduced. Offline: no --remote.
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
plugin="$here/plugins/factory"
doctor="$plugin/scripts/doctor.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0

# A repo as factory:init would leave it.
make_repo() {
  local r=$1
  git init -q -b main "$r"
  git -C "$r" remote add origin https://github.com/acme/widget.git
  sed -e 's#invariants: <path>\#<heading>#invariants: openspec/config.yaml\#Invariants#' \
      -e 's#<owner>/<repo>#acme/widget#; s#product_context: <path>#product_context: openspec/config.yaml#' \
      -e 's#owner: <name>#owner: Pat#; s#team_key: <KEY>#team_key: WID#; s#catch_all_project: <name>#catch_all_project: Maintenance#' \
      -e 's#delegate_safe: \[<test>, <lint>\]#delegate_safe: [make test]#; s#gate: <full check>#gate: make check#' \
      -e 's#serve: <command>#serve: make run#' \
      -e "s#current as of <date>#current as of $(date -u +%Y-%m-%d)#" \
      "$plugin/templates/FACTORY.md" > "$r/FACTORY.md"
  printf '# widget\n\n## Approvals\n\nStanding: merges.\n' > "$r/CLAUDE.md"
  mkdir -p "$r/openspec/specs" "$r/openspec/changes" "$r/.claude/commands/opsx" "$r/.github/workflows"
  printf 'schema: spec-driven\ncontext: |\n  ## Invariants\n\n  - none yet\n' > "$r/openspec/config.yaml"
  printf '{"enabledPlugins":{"factory@factory":true}}\n' > "$r/.claude/settings.json"
  sed -e 's/{{default_branch}}/main/g; s#{{feature_prefix}}#feature/#g; s/{{cwd}}/./; s/{{gate}}/make check/' \
      -e '/{{toolchain_steps}}/d' "$plugin/templates/init/ci.yml" > "$r/.github/workflows/ci.yml"
  sed -e 's/{{default_branch}}/main/g; s#{{feature_prefix}}#feature/#g; s/{{version}}/'"$(jq -r .version "$plugin/.claude-plugin/plugin.json")"'/' \
      "$plugin/templates/init/claude-review-caller.yml" > "$r/.github/workflows/claude-review.yml"
  cp "$plugin/templates/factory-signal.yml" "$r/.github/workflows/factory-signal.yml"
}
run() { (cd "$1" && "$doctor" 2>&1) ; }
expect() { # <label> <want-exit> <want-substring> <repo>
  local out rc=0
  out=$(run "$4") || rc=$?
  if [ "$rc" = "$2" ] && [[ $out == *"$3"* ]]; then echo "ok   [$1] exit $rc"
  else echo "FAIL [$1] exit $rc, want $2 containing '$3':"; echo "$out" | sed 's/^/     /'; fail=1; fi
}

make_repo "$tmp/good"
expect "an init-shaped repo conforms" 0 "0 FAIL, 0 WARN" "$tmp/good"

cp -r "$tmp/good" "$tmp/nokey"; sed -i.bak '/^  judge_model:/d' "$tmp/nokey/FACTORY.md"
expect "a missing contract key fails" 1 "missing key(s): ci.judge_model" "$tmp/nokey"

cp -r "$tmp/good" "$tmp/ph"; sed -i.bak 's/team_key: WID/team_key: <KEY>/' "$tmp/ph/FACTORY.md"
expect "a placeholder left fails" 1 "still a placeholder: tracker.team_key" "$tmp/ph"

cp -r "$tmp/good" "$tmp/curly"; sed -i.bak 's/make check/{{gate}}/' "$tmp/curly/.github/workflows/ci.yml"
expect "an init placeholder left fails" 1 "placeholders ({{...}}) still in: .github/workflows/ci.yml" "$tmp/curly"

cp -r "$tmp/good" "$tmp/feat"; sed -i.bak 's#branches: \[main, "feature/\*\*"\]#branches: [main]#' "$tmp/feat/.github/workflows/ci.yml"
expect "CI that skips feature PRs fails" 1 "no workflow besides the review runs on PRs into feature/**" "$tmp/feat"

cp -r "$tmp/good" "$tmp/anchor"; printf '# widget\n' > "$tmp/anchor/CLAUDE.md"
expect "a missing anchor heading fails" 1 "CLAUDE.md has no heading matching #Approvals" "$tmp/anchor"

cp -r "$tmp/good" "$tmp/origin"; git -C "$tmp/origin" remote set-url origin git@github.com:acme/other.git
expect "a different origin fails" 1 "but origin is acme/other" "$tmp/origin"

cp -r "$tmp/good" "$tmp/check"; sed -i.bak 's#review_check: review / Claude review#review_check: Claude review#' "$tmp/check/FACTORY.md"
expect "a review check no job reports fails" 1 "no job in .github/workflows reports that name" "$tmp/check"

cp -r "$tmp/good" "$tmp/ref"; sed -i.bak 's/^  cycle: factory:pr-cycle/  cycle: factory:no-such-script/' "$tmp/ref/FACTORY.md"
expect "a factory: value the plugin lacks fails" 1 "which this plugin" "$tmp/ref"

cp -r "$tmp/good" "$tmp/old"; sed -i.bak 's#claude-review.yml@v[0-9.]*#claude-review.yml@v0.0.1#' "$tmp/old/.github/workflows/claude-review.yml"
expect "an old reviewer tag warns" 0 "Move the caller to" "$tmp/old"

mkdir "$tmp/none"; git init -q "$tmp/none"
expect "no FACTORY.md is a setup error" 2 "has not joined the factory" "$tmp/none"

[ "$fail" = 0 ] && echo "check-doctor: all cases passed." || exit 1
