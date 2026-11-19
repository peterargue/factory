#!/usr/bin/env bash
# Check that a repo still conforms to the factory: its FACTORY.md against the
# plugin's template, the files the contract names, the workflows CI and review
# run from, and (with --remote) the branch ruleset and secrets on GitHub.
#
#   ${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh [--remote] [--dir <path>]
#
# One line per finding, `LEVEL check-id  message`, where LEVEL is
#   FAIL  the factory will misbehave in this repo until it is fixed
#   WARN  likely wrong, or drifting from the factory; read it
#   NOTE  could not be checked here, or worth knowing; nothing to fix
#   ok    passed (printed so a clean run shows what it covered)
# then a summary line. Exit 0 with no FAIL, 1 with any FAIL, 2 for usage or setup
# errors (not a git repo, no FACTORY.md). Reading only: it never writes a file or
# calls a GitHub endpoint that changes anything.
#
# The tracker (Linear team and project, GitHub project) is not checked here: the
# `factory:doctor` skill checks it through the tracker's own tools.
#
# Workflows are YAML; the script reads them with python3's yaml module, ruby's
# psych or mikefarah yq, whichever is present, and reports a NOTE if none is.

set -uo pipefail

# Associative arrays need bash 4; macOS ships 3.2 as /bin/bash. Use Homebrew's if present.
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do [ -x "$b" ] && exec "$b" "$0" "$@"; done
  echo "doctor: needs bash 4 or later (this is $BASH_VERSION). On macOS: brew install bash." >&2; exit 2
fi

remote=0
dir=${PWD}
while [ $# -gt 0 ]; do
  case $1 in
    --remote) remote=1 ;;
    --dir) shift; dir=${1:-} ;;
    --dir=*) dir=${1#--dir=} ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) echo "doctor: unknown argument '$1'" >&2; exit 2 ;;
  esac
  shift
done

plugin=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
template="$plugin/templates/FACTORY.md"
version=$(jq -r .version "$plugin/.claude-plugin/plugin.json" 2>/dev/null || echo unknown)

top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || {
  echo "doctor: $dir is not a git working copy." >&2; exit 2; }
factory="$top/FACTORY.md"
[ -f "$factory" ] || {
  echo "doctor: $top has no FACTORY.md, so it has not joined the factory. Run the factory:init skill." >&2; exit 2; }

fails=0 warns=0 notes=0 oks=0
say() { # <level> <id> <message>
  case $1 in FAIL) fails=$((fails+1)) ;; WARN) warns=$((warns+1)) ;; NOTE) notes=$((notes+1)) ;; ok) oks=$((oks+1)) ;; esac
  printf '%-4s %-28s %s\n' "$1" "$2" "$3"
}

# --- the contract -----------------------------------------------------------------

# contract <file> — `section.key<TAB>value` for every key in the first ```yaml block
# under `## Contract`; a top-level key prints as `key<TAB>value`. Comments that start
# with whitespace then `#` are dropped, so `CLAUDE.md#Approvals` keeps its anchor.
contract() {
  awk '
    /^## Contract/ { inc = 1; next }
    inc && /^```yaml/ { iny = 1; next }
    iny && /^```/ { exit }
    iny {
      line = $0
      if (match(line, /^[a-z_]+:/)) {
        sec = substr(line, 1, RLENGTH - 1); val = substr(line, RLENGTH + 1); key = sec
      } else if (match(line, /^  [a-z_]+:/)) {
        key = sec "." substr(line, 3, RLENGTH - 3); val = substr(line, RLENGTH + 1)
      } else next
      sub(/^[ \t]+/, "", val); sub(/[ \t]+#.*$/, "", val); sub(/[ \t]+$/, "", val)
      print key "\t" val
    }' "$1"
}
headings() { grep -E '^## ' "$1" | sed 's/^## //'; }

declare -A have want
while IFS=$'\t' read -r k v; do have[$k]=$v; done < <(contract "$factory")
while IFS=$'\t' read -r k v; do want[$k]=$v; done < <(contract "$template")
val() { printf '%s' "${have[$1]:-}"; }
unset_or_none() { local v; v=$(val "$1"); [ -z "$v" ] || [ "$v" = none ] || [ "$v" = "[]" ]; }

if [ ${#have[@]} -eq 0 ]; then
  say FAIL contract.block "FACTORY.md has no \`## Contract\` heading with a \`\`\`yaml block under it; nothing else can be read."
  echo "doctor: $fails FAIL, $warns WARN, $notes NOTE, $oks ok (factory plugin $version)"; exit 1
fi

if [ "$(val factory)" = "${want[factory]}" ]; then
  say ok contract.version "contract version ${want[factory]}"
else
  say FAIL contract.version "FACTORY.md says \`factory: $(val factory)\`, the plugin's template is \`factory: ${want[factory]}\`. Bring the file up to the template: compare its keys and headings with $template."
fi

missing=() extra=()
for k in "${!want[@]}"; do [ -n "${have[$k]+x}" ] || missing+=("$k"); done
for k in "${!have[@]}"; do [ -n "${want[$k]+x}" ] || extra+=("$k"); done
if [ ${#missing[@]} -eq 0 ]; then say ok contract.keys "all ${#want[@]} template keys present"
else say FAIL contract.keys "missing key(s): $(printf '%s\n' "${missing[@]}" | sort | paste -sd' ' -). Add them, with \`none\` where the repo does not use the slot."; fi
[ ${#extra[@]} -eq 0 ] || say WARN contract.extra-keys "key(s) the template does not have: $(printf '%s\n' "${extra[@]}" | sort | paste -sd' ' -). Nothing reads them; a typo, or a key the template should gain."

mapfile -t th < <(headings "$template")
mapfile -t rh < <(headings "$factory")
miss_h=()
for h in "${th[@]}"; do printf '%s\n' "${rh[@]}" | grep -qxF -- "$h" || miss_h+=("$h"); done
if [ ${#miss_h[@]} -gt 0 ]; then
  say FAIL contract.headings "missing heading(s): $(printf '## %s; ' "${miss_h[@]}")keep every heading and write \`none\` under it."
else
  order=$(printf '%s\n' "${rh[@]}" | grep -xF -f <(printf '%s\n' "${th[@]}"))
  if [ "$order" = "$(printf '%s\n' "${th[@]}")" ]; then say ok contract.headings "all ${#th[@]} headings, in order"
  else say WARN contract.headings "headings are out of the template's order: ${th[*]}"; fi
fi

# A value still holding a template placeholder. Patterns the skills fill per use
# (<change-name>, <topic>, <n>, <token>, <pr>) are part of the value, not gaps.
ph=()
for k in "${!have[@]}"; do
  v=${have[$k]}
  v=${v//<change-name>/}; v=${v//<topic>/}; v=${v//<n>/}; v=${v//<token>/}; v=${v//<pr>/}
  [[ $v == *'<'*'>'* ]] && ph+=("$k")
done
if [ ${#ph[@]} -eq 0 ]; then say ok contract.placeholders "no template placeholders left"
else say FAIL contract.placeholders "still a placeholder: $(printf '%s\n' "${ph[@]}" | sort | paste -sd' ' -)"; fi

# factory:init's templates mark gaps as {{name}}; GitHub expressions are ${{ }}.
left=$(cd "$top" && grep -lE '(^|[^$]){{[a-z]' FACTORY.md CLAUDE.md openspec/config.yaml .github/workflows/*.y*ml 2>/dev/null | paste -sd' ' -)
if [ -n "$left" ]; then say FAIL init.placeholders "factory:init placeholders ({{...}}) still in: $left"
else say ok init.placeholders "no factory:init placeholders left"; fi

asof=$(grep -oE 'current as of [0-9]{4}-[0-9]{2}-[0-9]{2}' "$factory" | head -1 | awk '{print $4}')
if [ -z "$asof" ]; then
  say WARN contract.as-of "no \"current as of <date>\" line; add one so a reader knows how old the values are"
else
  now=$(date -u +%s)
  then=$(date -u -d "$asof" +%s 2>/dev/null || date -u -j -f %Y-%m-%d "$asof" +%s 2>/dev/null || echo "$now")
  age=$(( (now - then) / 86400 ))
  if [ "$age" -gt 90 ]; then say WARN contract.as-of "values last confirmed $asof ($age days ago); re-check them and bump the date"
  else say ok contract.as-of "values confirmed $asof"; fi
fi

# --- the repo itself ----------------------------------------------------------------

origin=$(git -C "$top" remote get-url origin 2>/dev/null || true)
slug=$(printf '%s' "$origin" | sed -E 's#^(https?://[^/]+/|git@[^:]+:|ssh://git@[^/]+/)##; s#\.git$##')
# Cloud sessions clone through a local proxy (http://local_proxy@127.0.0.1:port/git/<owner>/<repo>).
slug=${slug#git/}
if [ -z "$origin" ]; then
  say NOTE repo.github "no origin remote; cannot compare with repo.github ($(val repo.github))"
elif [ "$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')" = "$(val repo.github | tr '[:upper:]' '[:lower:]')" ]; then
  say ok repo.github "$(val repo.github) is origin"
else
  say FAIL repo.github "repo.github is $(val repo.github) but origin is $slug. Every script resolves PRs through repo.github."
fi

head_ref=$(git -C "$top" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
if [ -n "$head_ref" ]; then
  if [ "${head_ref#origin/}" = "$(val repo.default_branch)" ]; then say ok repo.default_branch "$(val repo.default_branch)"
  else say FAIL repo.default_branch "repo.default_branch is $(val repo.default_branch) but origin's HEAD is ${head_ref#origin/}"; fi
fi

# path_exists <key> [--anchor] — the value is a path relative to the repo root,
# optionally with #<heading>. `none` and empty pass.
slugify() { tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9 _-]//g; s/[ ]+/-/g'; }
check_path() {
  local key=$1 v file anchor
  v=$(val "$key"); [ -n "$v" ] && [ "$v" != none ] || return 0
  v=${v#\"}; v=${v%\"}
  v=${v%% *}          # `factory:wait-ci <pr>` and the like: the path is the first word
  case $v in factory:*) return 0 ;; '~'*|/*) say NOTE "path.$key" "$v is outside the repo; not checked"; return 0 ;; esac
  file=${v%%#*}; anchor=; [[ $v == *'#'* ]] && anchor=${v#*#}
  if [ ! -e "$top/$file" ]; then say FAIL "path.$key" "$key names $file, which does not exist"; return; fi
  if [ -n "$anchor" ]; then
    local want_a; want_a=$(printf '%s' "$anchor" | slugify)
    if grep -E '^[[:space:]]*#{1,6}[[:space:]]+' "$top/$file" | sed -E 's/^[[:space:]]*#{1,6}[[:space:]]+//' | slugify | grep -qxF -- "$want_a"; then
      say ok "path.$key" "$file has a \"$anchor\" heading"
    else
      say FAIL "path.$key" "$file has no heading matching #$anchor"
    fi
  else
    say ok "path.$key" "$file"
  fi
}
for k in repo.instructions repo.product_context invariants approvals specs.docs_check \
         ci.review_workflow ci.signal_workflow deploy.on_merge_to_default acceptance.sign_in; do check_path "$k"; done
for k in commands.cwd acceptance.cwd; do
  v=$(val "$k"); [ -z "$v" ] || [ -d "$top/$v" ] || say FAIL "path.$k" "$k is $v, which is not a directory"
done
wr=$(awk '/^  rollout_wrappers:/{f=1} f{print} f&&/\]/{exit}' "$factory" | grep -oE '[A-Za-z0-9_./-]+\.sh' || true)
for w in $wr; do [ -e "$top/$w" ] || say FAIL path.deploy.rollout_wrappers "$w does not exist"; done

# factory:<name> values must name something the plugin ships.
for k in "${!have[@]}"; do
  for ref in $(printf '%s' "${have[$k]}" | grep -oE 'factory:[a-z0-9-]+' || true); do
    n=${ref#factory:}
    if [ -e "$plugin/scripts/$n.sh" ] || [ -e "$plugin/hooks/$n.sh" ] || [ -d "$plugin/skills/$n" ]; then :
    else say FAIL "plugin.$k" "$k names $ref, which this plugin ($version) does not ship"; fi
  done
done

# --- specs --------------------------------------------------------------------------

if [ "$(val specs.system)" = openspec ]; then
  if [ ! -f "$top/openspec/config.yaml" ]; then
    say FAIL specs.openspec "specs.system is openspec but openspec/config.yaml is missing"
  else
    grep -qE '^schema:' "$top/openspec/config.yaml" && say ok specs.openspec "openspec/config.yaml" \
      || say WARN specs.openspec "openspec/config.yaml has no \`schema:\` line"
    [ -d "$top/openspec/specs" ] && [ -d "$top/openspec/changes" ] \
      || say WARN specs.openspec-dirs "openspec/specs or openspec/changes is missing; run \`openspec init\`"
    if [ -d "$top/.claude/commands/opsx" ] || compgen -G "$top/.claude/skills/openspec-*" >/dev/null; then
      say ok specs.opsx "OpenSpec commands are installed"
    else
      say WARN specs.opsx "no .claude/commands/opsx or .claude/skills/openspec-*; the spec skills call /opsx:*. Run \`openspec init --tools claude\`"
    fi
  fi
fi

# --- workflows ----------------------------------------------------------------------

yaml_to_json() { # <file> — JSON on stdout, or exit 1
  if python3 -c 'import yaml' 2>/dev/null; then
    python3 -c 'import sys,yaml,json
d=yaml.safe_load(open(sys.argv[1]))
if isinstance(d,dict) and True in d: d["on"]=d.pop(True)
print(json.dumps(d,default=str))' "$1"
  elif command -v ruby >/dev/null 2>&1; then
    ruby -ryaml -rjson -e 'd=YAML.safe_load(File.read(ARGV[0]), aliases: true); d["on"]=d.delete(true) if d.is_a?(Hash) && d.key?(true); puts JSON.generate(d)' "$1"
  elif command -v yq >/dev/null 2>&1 && yq --version 2>&1 | grep -q mikefarah; then
    yq -o=json '.' "$1"
  else
    return 1
  fi
}

wfdir="$top/.github/workflows"
declare -A wf
yaml_ok=1
for f in "$wfdir"/*.yml "$wfdir"/*.yaml; do
  [ -f "$f" ] || continue
  j=$(yaml_to_json "$f" 2>/dev/null) || { yaml_ok=0; break; }
  wf[${f#"$top/"}]=$j
done

default=$(val repo.default_branch)
fprefix=$(val branches.feature_prefix)
review_check=$(val ci.review_check)

# covers <json> <branch-or-glob> — does the workflow's pull_request trigger run on PRs
# into that branch? No pull_request trigger: no. No branches filter: yes.
covers() {
  jq -e --arg b "$2" '
    (.on // {}) as $on
    | if ($on|type) == "string" then $on == "pull_request"
      elif ($on|type) == "array" then any($on[]; . == "pull_request")
      elif ($on|has("pull_request")|not) then false
      else ($on.pull_request // {}) as $pr
        | if ($pr|type) != "object" or ($pr|has("branches")|not) then true
          else any($pr.branches[]; . == $b or (endswith("**") and ($b|startswith(.[:-2])))) end
      end' <<<"$1" >/dev/null
}

if [ $yaml_ok = 0 ]; then
  say NOTE workflows "no YAML reader (python3 with PyYAML, ruby, or mikefarah yq); workflow checks skipped"
elif [ ${#wf[@]} -eq 0 ]; then
  say FAIL workflows "no .github/workflows; the repo has neither CI nor the Claude review"
else
  # Every check context a workflow can report: `name // id` per job; a job calling
  # the factory reviewer reports `<caller> / Claude review`; `${{ }}` parts match anything.
  contexts=$(for f in "${!wf[@]}"; do
    jq -r '.jobs // {} | to_entries[] | (.value.name // .key) as $n
      | if ((.value.uses // "") | test("factory/\\.github/workflows/claude-review\\.yml@")) then "\($n) / Claude review"
        elif (.value.uses // "") != "" then "\($n) / *"
        else $n end' <<<"${wf[$f]}"
  done | sed -E 's/\$\{\{[^}]*\}\}/*/g' | sort -u)

  # The review workflow.
  rw=$(val ci.review_workflow)
  if [ -n "${wf[$rw]+x}" ]; then
    j=${wf[$rw]}
    covers "$j" "$default" || say FAIL review.trigger "$rw does not run on PRs into $default"
    if [ -n "$fprefix" ] && [ "$fprefix" != none ]; then
      covers "$j" "${fprefix}x" || say FAIL review.trigger "$rw does not run on PRs into ${fprefix}**"
    fi
    jq -e '(.on.pull_request.types // ["opened","synchronize","reopened"]) | index("ready_for_review")' <<<"$j" >/dev/null \
      || say WARN review.ready "$rw does not run on ready_for_review, so a PR opened as a draft is never reviewed"
    uses=$(jq -r '[.jobs[]? | .uses // empty | select(test("claude-review\\.yml@"))][0] // ""' <<<"$j")
    if [ -n "$uses" ]; then
      ref=${uses##*@}
      [ "$ref" = "v$version" ] && say ok review.version "calls the factory reviewer at $ref" \
        || say WARN review.version "calls the factory reviewer at $ref; this plugin is v$version. Move the caller to @v$version."
    else
      rendered=$(grep -oE '^# factory: rendered from claude-review\.yml v[0-9.]+' "$top/$rw" | awk '{print $NF}')
      if [ -z "$rendered" ]; then
        say NOTE review.copy "$rw is a hand-kept copy of the factory reviewer; compare it with the factory's claude-review.yml whenever the factory's reviewer changes"
      elif [ "$rendered" = "v$version" ]; then say ok review.copy "standalone copy rendered from $rendered"
      else say WARN review.copy "$rw was rendered from the reviewer at $rendered; this plugin is v$version. Re-render it with scripts/render-review-workflow.sh"; fi
    fi
    if grep -qxF -- "$review_check" <<<"$contexts"; then say ok review.check "a job reports \"$review_check\""
    else say FAIL review.check "ci.review_check is \"$review_check\" but no job in .github/workflows reports that name"; fi
  else
    say FAIL review.workflow "ci.review_workflow ($rw) is not a workflow file"
  fi

  # CI on feature PRs: some workflow other than the review must cover both bases.
  ci_main=0 ci_feat=0
  for f in "${!wf[@]}"; do
    [ "$f" = "$rw" ] && continue
    covers "${wf[$f]}" "$default" && ci_main=1
    covers "${wf[$f]}" "${fprefix}x" && ci_feat=1
  done
  [ $ci_main = 1 ] && say ok ci.main "CI runs on PRs into $default" || say FAIL ci.main "no workflow besides the review runs on PRs into $default"
  if [ -n "$fprefix" ] && [ "$fprefix" != none ]; then
    [ $ci_feat = 1 ] && say ok ci.feature "CI runs on PRs into ${fprefix}**" \
      || say FAIL ci.feature "no workflow besides the review runs on PRs into ${fprefix}**; stacked and sub-PRs get no CI"
  fi

  # The gate should be what CI runs. Heuristic: its last command appears in a workflow.
  gate=$(val commands.gate); last=${gate##*&&}; last=$(printf '%s' "$last" | sed -E 's/^ +| +$//g')
  if [ -n "$last" ] && [ "$last" != none ]; then
    if grep -rqF -- "$last" "$wfdir"; then say ok ci.gate "\`$last\` appears in a workflow"
    else say NOTE ci.gate "commands.gate ends with \`$last\`, which no workflow runs verbatim; make sure CI checks at least what the gate does"; fi
  fi

  # Advisory checks are real jobs.
  adv=$(val ci.advisory_checks | sed -E 's/^\[|\]$//g' | grep -oE '"[^"]*"|[^,"]+' | sed -E 's/^ +| +$//g; s/^"|"$//g' | grep -v '^$' || true)
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    grep -qxF -- "$a" <<<"$contexts" || say WARN ci.advisory "ci.advisory_checks names \"$a\", which no job reports"
  done <<<"$adv"
fi

# --- plugin enablement --------------------------------------------------------------

if jq -e '.enabledPlugins["factory@factory"] == true' "$top/.claude/settings.json" >/dev/null 2>&1; then
  say ok plugin.enabled ".claude/settings.json enables factory@factory"
else
  say WARN plugin.enabled ".claude/settings.json does not enable factory@factory, so local sessions run without the hooks. Project threads take it from Project settings → Plugins instead."
fi

# --- GitHub (only with --remote) ----------------------------------------------------

if [ $remote = 1 ]; then
  repo=$(val repo.github)
  if ! command -v gh >/dev/null 2>&1; then
    say NOTE remote "gh is not installed; remote checks skipped"
  else
    ids=$(gh api "repos/$repo/rulesets" --jq '.[] | select(.target == "branch") | .id' 2>/dev/null) || ids=ERR
    if [ "$ids" = ERR ]; then
      say NOTE remote.ruleset "could not list rulesets for $repo (no access?)"
    else
      rs=""
      for id in $ids; do
        r=$(gh api "repos/$repo/rulesets/$id" 2>/dev/null) || continue
        jq -e --arg d "$default" '.enforcement == "active" and ((.conditions.ref_name.include // []) | any(. == "~DEFAULT_BRANCH" or . == "~ALL" or . == "refs/heads/\($d)"))' <<<"$r" >/dev/null && rs+="$r"$'\n'
      done
      if [ -z "$rs" ]; then
        say FAIL remote.ruleset "no active branch ruleset covers $default. Nothing stops a red PR merging. factory:init can create one from templates/ruleset.json"
      else
        rules=$(jq -rs '[.[].rules[].type] | unique | join(" ")' <<<"$rs")
        for t in deletion non_fast_forward required_status_checks; do
          [[ " $rules " == *" $t "* ]] || say WARN remote.ruleset "the $default ruleset has no \`$t\` rule"
        done
        req=$(jq -rs '[.[].rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context] | unique[]' <<<"$rs")
        if grep -qxF -- "$review_check" <<<"$req"; then say ok remote.review-required "\"$review_check\" is required"
        else say FAIL remote.review-required "the ruleset does not require \"$review_check\", so a PR can merge unreviewed"; fi
        if [ $yaml_ok = 1 ] && [ ${#wf[@]} -gt 0 ]; then
          while IFS= read -r c; do
            [ -n "$c" ] || continue
            hit=0
            while IFS= read -r p; do [[ $c == $p ]] && { hit=1; break; }; done <<<"$contexts"
            [ $hit = 1 ] || say FAIL remote.required-exists "the ruleset requires \"$c\", which no job in .github/workflows reports; every PR will wait on it forever"
          done <<<"$req"
          while IFS= read -r a; do
            [ -n "$a" ] && grep -qxF -- "$a" <<<"$req" && say WARN remote.advisory "\"$a\" is in ci.advisory_checks but the ruleset requires it"
          done <<<"${adv:-}"
        fi
      fi
    fi
    secrets=$(gh api "repos/$repo/actions/secrets" --jq '.secrets[].name' 2>/dev/null) || secrets=ERR
    if [ "$secrets" = ERR ]; then say NOTE remote.secret "could not list Actions secrets for $repo (needs admin); check CLAUDE_CODE_OAUTH_TOKEN by hand"
    elif grep -qx CLAUDE_CODE_OAUTH_TOKEN <<<"$secrets"; then say ok remote.secret "CLAUDE_CODE_OAUTH_TOKEN is set"
    else say FAIL remote.secret "no CLAUDE_CODE_OAUTH_TOKEN Actions secret; the review cannot run. Create it from \`claude setup-token\`"; fi
  fi
fi

say NOTE tracker "the tracker ($(val tracker.system), $(val tracker.team_key), project $(val tracker.catch_all_project)) is checked by the factory:doctor skill, not this script"
echo "doctor: $fails FAIL, $warns WARN, $notes NOTE, $oks ok (factory plugin $version)"
[ $fails -eq 0 ]
