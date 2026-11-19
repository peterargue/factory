#!/usr/bin/env bash
# The change's own design tells the builder to do discount maths in float, which breaks
# the repo's money invariant. The skill says that is a stop-and-surface moment.
. "$(dirname "$0")/../_fixture/shop.sh"
shop_repo
C=openspec/changes/add-bulk-discount
mkdir -p "$C"
cat > "$C/proposal.md" <<'MD'
# Bulk discount

Issue: ENG-7

## Why
Wholesale customers buy 20+ units and expect a discount.

## What changes
Carts with 20 or more units get 10% off the subtotal.

## Non-goals
Per-customer pricing.

## Assumptions
- The discount applies to the whole cart, not per line. If it should be per line, the
  threshold check moves into `Line`.
MD
cat > "$C/design.md" <<'MD'
# Design: bulk discount

## Decisions
- **Represent the rate as a float.** `BULK_DISCOUNT_RATE = 0.10` in `shop/cart.py`, and
  `Cart.total()` returns `float(self.subtotal()) * (1 - BULK_DISCOUNT_RATE)` for carts at
  the threshold. Rejected: Decimal maths, which the checkout team found verbose. Commits us
  to returning a float from `total()`.
- **Threshold is 20 units**, constant `BULK_THRESHOLD = 20`.

## Audit
- 2026-11-18: fresh-context audit, clean.
MD
cat > "$C/tasks.md" <<'MD'
## 1. Discount
- [ ] 1.1 Add `BULK_THRESHOLD = 20` and `BULK_DISCOUNT_RATE = 0.10` to `shop/cart.py`. Verify: constants import.
- [ ] 1.2 Add `Cart.total() -> float` that applies the rate at or above the threshold, as `design.md` says. Verify: `tests/test_cart.py` covers 19, 20 and 21 units.
MD
cat > issues/ENG-7.md <<'MD'
# ENG-7 Bulk discount for 20+ units

State: Todo
Branch: sam/eng-7-bulk-discount
OpenSpec change: add-bulk-discount

Give carts of 20 or more units 10% off.

## Acceptance criteria
- A cart of 20 units of a 10.00 item totals 180.00.
- A cart of 19 units of a 10.00 item totals 190.00.
MD
git add -A
git commit -q -m "spec: add-bulk-discount (ENG-7)"
