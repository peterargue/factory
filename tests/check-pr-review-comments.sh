#!/usr/bin/env bash
# Fixture-test pr-review-comments.sh as a cloud session sees it: GraphQL answers
# HTTP 403, so the thread state has to come from the ccr review_threads route.
#
# gh is a stub that serves fixture JSON per REST path and runs each `--jq` filter
# through REAL jq, so the filters and the ccr normalisation that ship are the ones
# tested. What must hold:
#   - an unresolved ccr thread is counted and listed, with its author and the
#     comment id that resolves it
#   - a failure of both thread routes exits non-zero, never "no open threads"
#
#   tests/check-pr-review-comments.sh

set -uo pipefail

here=$(cd -- "$(dirname -- "$0")/../plugins/factory/scripts" && pwd -P)
script="$here/pr-review-comments.sh"
[ -x "$script" ] || { echo "check-pr-review-comments: $script missing or not executable" >&2; exit 2; }

work=$(mktemp -d) || exit 2
trap 'rm -rf "$work"' EXIT
fix="$work/fix"; mkdir -p "$fix" "$work/bin" "$work/repo"
fails=0

cat >"$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = api ] || exit 2
shift
path='' jqf=''
while [ $# -gt 0 ]; do
  case $1 in
    -f|-F) shift 2 ;;
    --jq) jqf=$2; shift 2 ;;
    --paginate) shift ;;
    *) path=$1; shift ;;
  esac
done
if [ "$path" = graphql ]; then echo "HTTP 403: GitHub GraphQL is not available" >&2; exit 1; fi
path=${path//\{owner\}/acme}; path=${path//\{repo\}/widget}
f="$FIXDIR/$(printf '%s' "$path" | tr '/?&=' '____').json"
[ -f "$f" ] || { echo "stub: no fixture $f" >&2; exit 1; }
if [ -n "$jqf" ]; then jq -r "$jqf" "$f"; else cat "$f"; fi
STUB
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH" FIXDIR="$fix" FACTORY_REPO_ROOT="$work/repo"
touch "$work/repo/FACTORY.md"

p=repos_acme_widget
echo '{"full_name":"acme/widget"}' >"$fix/$p.json"
echo '{"number":7,"state":"open","merged_at":null,"title":"t"}' >"$fix/${p}_pulls_7.json"
echo '[{"id":11,"user":{"login":"claude[bot]"},"path":"a.sh","line":3,"body":"bug","html_url":"u"},
       {"id":12,"user":{"login":"claude[bot]"},"path":"b.sh","line":9,"body":"nit","html_url":"u"},
       {"id":13,"user":{"login":"peterargue"},"path":"b.sh","line":9,"body":"fixed","html_url":"u","in_reply_to_id":12}]' \
  >"$fix/${p}_pulls_7_comments.json"
echo '[]' >"$fix/${p}_pulls_7_reviews.json"
echo '[]' >"$fix/${p}_issues_7_comments.json"
echo '[{"resolved":false,"outdated":false,"path":"a.sh","line":3,"comment_ids":[11]},
       {"resolved":true,"outdated":true,"path":"b.sh","line":null,"comment_ids":[12,13]}]' \
  >"$fix/${p}_pulls_7_ccr_review_threads.json"

check() { # label pattern
  if grep -qF -- "$2" "$work/out"; then echo "ok   [$1]"; else
    echo "FAIL [$1] missing: $2"; sed 's/^/    /' "$work/out"; fails=$((fails + 1)); fi
}

"$script" 7 >"$work/out" 2>&1; code=$?
[ "$code" -eq 0 ] && echo "ok   [cloud path exits 0]" || { echo "FAIL [cloud path exits 0] got $code"; sed 's/^/    /' "$work/out"; fails=$((fails + 1)); }
check "title comes from REST" "#7 [OPEN] t"
check "the open thread is counted" "1 of 2 review thread(s) UNRESOLVED, 1 of those with no reply at all"
check "the open thread names its author" "a.sh:3  [claude[bot]]  NO REPLY"
check "the open thread names the comment that resolves it" "thread: comment 11"

rm "$fix/${p}_pulls_7_ccr_review_threads.json"
"$script" 7 >"$work/out" 2>&1; code=$?
if [ "$code" -ne 0 ] && ! grep -q "every thread is resolved" "$work/out"; then
  echo "ok   [no thread route fails loudly]"
else
  echo "FAIL [no thread route fails loudly] exit $code"; sed 's/^/    /' "$work/out"; fails=$((fails + 1))
fi

if [ "$fails" -gt 0 ]; then echo "check-pr-review-comments: $fails failure(s)" >&2; exit 1; fi
echo "check-pr-review-comments: all checks passed"
