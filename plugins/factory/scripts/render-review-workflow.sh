#!/usr/bin/env bash
# Write a standalone Claude review workflow from the factory's reusable one, for a
# repo that cannot call it (a private reusable workflow only serves repos with the
# same owner).
#
#   ${CLAUDE_PLUGIN_ROOT}/scripts/render-review-workflow.sh [--branches "main, \"feature/**\""] \
#       [--input name=value ...] [--source <reusable.yml>] > .github/workflows/claude-review.yml
#
# The reusable workflow's `on: workflow_call` block becomes a pull_request trigger
# with the permissions and concurrency group its callers would supply, and every
# `inputs.<name>` is replaced by --input's value or the input's default. The job
# keeps its name, so the check reports as `Claude review`, not `review / Claude
# review`. The first line records the plugin version, which factory:doctor reads
# to say when the copy is behind.
#
# --source defaults to the reusable workflow as fetched from the factory repo at
# this plugin's version tag, falling back to main; pass a local path to skip the
# fetch. Exit 0 on success, 2 on usage or fetch errors.

set -uo pipefail

plugin=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
version=$(jq -r .version "$plugin/.claude-plugin/plugin.json")
branches='main, "feature/**"'
source=""
over=()
while [ $# -gt 0 ]; do
  case $1 in
    --branches) shift; branches=${1:-} ;;
    --input) shift; [[ ${1:-} == *=* ]] || { echo "render-review-workflow: --input wants name=value" >&2; exit 2; }
             over+=("$1") ;;
    --source) shift; source=${1:-} ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "render-review-workflow: unknown argument '$1'" >&2; exit 2 ;;
  esac
  shift
done

tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
if [ -n "$source" ]; then
  cp "$source" "$tmp" || exit 2
else
  for ref in "v$version" main; do
    gh api -H 'Accept: application/vnd.github.raw' \
      "repos/peterargue/factory/contents/.github/workflows/claude-review.yml?ref=$ref" > "$tmp" 2>/dev/null && break
    : > "$tmp"
  done
  [ -s "$tmp" ] || { echo "render-review-workflow: could not fetch the reviewer from peterargue/factory; pass --source" >&2; exit 2; }
fi
grep -q '^  workflow_call:' "$tmp" || { echo "render-review-workflow: source is not the reusable reviewer (no workflow_call)" >&2; exit 2; }

python3 - "$tmp" "$version" "$branches" "${over[@]}" <<'PY'
import sys, re
path, version, branches = sys.argv[1:4]
over = dict(a.split("=", 1) for a in sys.argv[4:])
lines = open(path).read().split("\n")

# Inputs, read from the workflow_call block: name -> (type, default).
inputs, cur, i = {}, None, lines.index("    inputs:") + 1
while i < len(lines) and (lines[i].startswith("      ") or not lines[i].strip()):
    l = lines[i]
    m = re.match(r"^      ([a-z_]+):\s*$", l)
    if m:
        cur = m.group(1); inputs[cur] = ["string", ""]
    m = re.match(r"^        (type|default):\s*(.*)$", l)
    if m and cur:
        v = m.group(2).strip()
        if m.group(1) == "default" and len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
            v = v[1:-1]
        inputs[cur][0 if m.group(1) == "type" else 1] = v
    i += 1
unknown = set(over) - set(inputs)
if unknown:
    print("render-review-workflow: unknown input(s): " + ", ".join(sorted(unknown)) + "; known: " + ", ".join(inputs), file=sys.stderr)
    sys.exit(2)
vals = {k: over.get(k, d) for k, (t, d) in inputs.items()}

start = next(n for n, l in enumerate(lines) if l == "on:")
end = next(n for n, l in enumerate(lines) if l == "jobs:")
head = [l for l in lines[:start] if not l.startswith("#")]
head = [l.replace("Claude PR Review (reusable)", "Claude PR Review") for l in head]
header = [
    f"# factory: rendered from claude-review.yml v{version} by render-review-workflow.sh",
    "# Do not edit by hand: re-render it, so factory:doctor can tell when it falls behind.",
] + [l for l in head if l.strip()] + [
    "",
    "on:",
    "  pull_request:",
    "    types: [opened, synchronize, ready_for_review]",
    f"    branches: [{branches}]",
    "",
    "permissions:",
    "  contents: read",
    "  pull-requests: write",
    "  id-token: write",
    "",
    "concurrency:",
    "  group: claude-review-${{ github.head_ref }}",
    "  cancel-in-progress: true",
    "",
]
body = "\n".join(lines[end:])

def literal(name):
    t, v = inputs[name][0], vals[name]
    return v if t == "number" else "'" + v.replace("'", "''") + "'"

# A whole `${{ inputs.x }}` becomes the plain value (it may sit inside a block
# scalar, such as the review prompt); inside a larger expression it becomes a literal.
def whole(m):
    name = m.group(1)
    v = vals[name]
    if "\n" in v:
        indent = re.match(r"\s*", m.string[m.string.rfind("\n", 0, m.start()) + 1:]).group(0)
        v = v.replace("\n", "\n" + indent)
    return v
body = re.sub(r"\$\{\{\s*inputs\.([a-z_]+)\s*\}\}", whole, body)
body = re.sub(r"\binputs\.([a-z_]+)\b", lambda m: literal(m.group(1)), body)
sys.stdout.write("\n".join(header) + "\n" + body)
PY
