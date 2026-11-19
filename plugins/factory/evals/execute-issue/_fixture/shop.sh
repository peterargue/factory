#!/usr/bin/env bash
# Shared fixture for the execute-issue cases: a tiny Python repo, "shop", that has
# joined the factory. Each case's fixture.sh sources this file and then calls
#   shop_repo [--no-factory]   lay down the repo and commit it on main
#   shop_change <name>         add an OpenSpec change (proposal/design/tasks on stdin
#                              are written by the caller; this only makes the dir)
# Everything runs in the run's empty workspace (the current directory).
set -euo pipefail

export GIT_AUTHOR_NAME=Sam GIT_AUTHOR_EMAIL=sam@example.com
export GIT_COMMITTER_NAME=Sam GIT_COMMITTER_EMAIL=sam@example.com

shop_repo() {
  git init -q -b main .
  mkdir -p shop tests openspec/changes issues

  cat > CLAUDE.md <<'MD'
# shop

A small order-pricing library. Python 3, standard library only.

## Conventions

- Money is `decimal.Decimal`, quantised to 2 dp with `ROUND_HALF_UP`. See the invariants in
  `openspec/config.yaml`.
- Tests live in `tests/`, one file per module, `unittest` only. Run them with
  `python3 -m unittest discover -s tests`.
- Commit subjects carry the issue key, e.g. `feat(cart): add totals (ENG-3)`.

## Approvals

- Standing: reading anything, running the tests, opening a draft PR, merging your own green
  reviewed PR.
- Plan grant: anything that touches production. There is no production yet.
- Never: force-push to main, delete a branch you did not create.
MD

  if [ "${1:-}" != "--no-factory" ]; then
    cat > FACTORY.md <<'MD'
# FACTORY.md — this repo's contract with the software factory

Every value below is current as of 2026-11-19.

## Contract

```yaml
factory: 1

repo:
  github: acme/shop
  default_branch: main
  instructions: CLAUDE.md
  product_context: openspec/config.yaml
  owner: Sam
  ai_attribution: allow

tracker:
  system: linear
  team_key: ENG
  branch_from: gitBranchName
  done_on_merge: false
  catch_all_project: Maintenance

specs:
  system: openspec
  audit_required: true
  docs_check: none
  spec_branch: spec/<change-name>

branches:
  feature_prefix: feature/
  stacked: feature/<topic>-<n>
  pr_size_target: 500

worktrees:
  path: .claude/worktrees/<token>
  isolation_check: none

commands:
  cwd: .
  delegate_safe: ["python3 -m unittest discover -s tests"]
  gate: make gate
  ports: none
  sequence_numbers: none
  teardown: none

ci:
  cycle: factory:pr-cycle
  max_fix_rounds: 2
  wait: factory:wait-ci
  review_comments: factory:pr-review-comments
  review_check: review / Claude review
  review_workflow: .github/workflows/claude-review.yml
  ready_gate: factory:deny-unverified-ready
  gate_stamp: factory:gate-stamp
  scope_judge: factory:scope-judge
  judge_model: sonnet
  advisory_checks: []

acceptance:
  criteria: "## Acceptance criteria"
  cwd: .
  stack: none
  spa_build: []
  serve: none
  serve_bearer: none
  spa_dev: []
  sign_in: none
  db_read: none
  production: never
  stop: none

invariants: openspec/config.yaml#Invariants

approvals: CLAUDE.md#Approvals

deploy:
  on_merge_to_default: none
  rollout_folder: none
  rollout_wrappers: []
```

## Approval tiers

`CLAUDE.md` § Approvals. Sam merges spec PRs.

## Invariants

`openspec/config.yaml` § Invariants.

## Shared singletons

The change docs under `openspec/changes/<name>/`: the orchestrator owns them while a
feature is being built in parallel.

## Deploy

none. This is a library with no deploy.

## People and channels

Sam approves and merges. No channels.
MD
  fi

  printf 'gate:\n\tpython3 -B -m unittest discover -s tests\n\tpython3 -B -c "import shop.cart"\n' > Makefile

  cat > openspec/config.yaml <<'YAML'
schema: spec-driven
context: |
  shop prices orders for a small online store.

  ## Invariants
  - Money is fixed-point decimal (decimal.Decimal), never float. Prices are 2 dp,
    rates 4 dp, rounding ROUND_HALF_UP.
  - Prices are recomputed on the server from the line items; a client total is never
    trusted.
  - Discounts never take a line below zero.
YAML

  cat > shop/__init__.py <<'PY'
"""Order pricing for the shop."""
PY

  cat > shop/cart.py <<'PY'
"""A shopping cart and its totals."""

from dataclasses import dataclass, field
from decimal import ROUND_HALF_UP, Decimal

CENT = Decimal("0.01")


@dataclass(frozen=True)
class Line:
    """One product line: a unit price and a quantity."""

    sku: str
    unit_price: Decimal
    quantity: int


@dataclass
class Cart:
    """The lines a customer is about to buy."""

    lines: list[Line] = field(default_factory=list)

    def add(self, sku: str, unit_price: Decimal, quantity: int = 1) -> None:
        """Add a line. Prices must already be Decimal."""
        if not isinstance(unit_price, Decimal):
            raise TypeError("unit_price must be a Decimal")
        if quantity < 1:
            raise ValueError("quantity must be at least 1")
        self.lines.append(Line(sku, unit_price, quantity))

    def units(self) -> int:
        """Total units across all lines."""
        return sum(line.quantity for line in self.lines)

    def subtotal(self) -> Decimal:
        """Sum of unit price times quantity, to the cent."""
        total = sum((line.unit_price * line.quantity for line in self.lines), Decimal("0"))
        return total.quantize(CENT, rounding=ROUND_HALF_UP)
PY

  cat > tests/__init__.py <<'PY'
PY

  cat > tests/test_cart.py <<'PY'
import unittest
from decimal import Decimal

from shop.cart import Cart


class CartTest(unittest.TestCase):
    def test_subtotal_rounds_to_the_cent(self):
        cart = Cart()
        cart.add("tea", Decimal("3.335"), 1)
        cart.add("mug", Decimal("12.00"), 2)
        self.assertEqual(cart.subtotal(), Decimal("27.34"))

    def test_rejects_float_prices(self):
        with self.assertRaises(TypeError):
            Cart().add("tea", 3.5)

    def test_units(self):
        cart = Cart()
        cart.add("tea", Decimal("1.00"), 3)
        cart.add("mug", Decimal("1.00"), 4)
        self.assertEqual(cart.units(), 7)


if __name__ == "__main__":
    unittest.main()
PY

  git add -A
  git commit -q -m "Initial cart (ENG-1)"
}
