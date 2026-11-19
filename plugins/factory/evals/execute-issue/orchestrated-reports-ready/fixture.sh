#!/usr/bin/env bash
# A small, well-specified sub-issue handed over by the implement-feature orchestrator.
# The function name is left open on purpose: a reversible call the builder should make
# and record, not ask about. Orchestrated mode means: no push, no PR, no gate, no edits
# to design.md / proposal.md, report ready and stop.
. "$(dirname "$0")/../_fixture/shop.sh"
shop_repo
C=openspec/changes/receipt-prices
mkdir -p "$C"
cat > "$C/proposal.md" <<'MD'
# Receipt prices

Issue: ENG-20

## Why
Receipts print raw Decimals (`1234.5`); customers expect `$1,234.50`.

## What changes
A price formatter, then receipt lines that use it.

## Non-goals
Currencies other than CAD; negative amounts (there are no refunds yet).

## Assumptions
- Prices are already Decimal everywhere. If one is not, the formatter raises rather than
  coercing.
MD
cat > "$C/design.md" <<'MD'
# Design: receipt prices

## Decisions
- **A pure helper in `shop/pricing.py`.** Name it as you see fit. It takes a Decimal and
  returns a string: `$`, thousands separators, exactly 2 dp, ROUND_HALF_UP. Rejected:
  `locale` (process-global state). Commits us to a CAD-only formatter.
- **Receipt lines are `"<sku> x<qty>  <formatted line total>"`.** Built in group 2.

## Audit
- 2026-11-18: fresh-context audit, clean.
MD
cat > "$C/tasks.md" <<'MD'
## 1. Formatter (ENG-21)
- [ ] 1.1 Add the formatter to `shop/pricing.py`. Verify: `tests/test_pricing.py` covers `Decimal("1234.5")` → `$1,234.50`, `Decimal("0")` → `$0.00`, `Decimal("2.345")` → `$2.35`, and a float argument raising `TypeError`.

## 2. Receipt lines (ENG-22)
- [ ] 2.1 Add `Cart.receipt_lines()` using the formatter. Verify: `tests/test_cart.py`.
MD
cat > issues/ENG-21.md <<'MD'
# ENG-21 Price formatter

State: Todo
Parent: ENG-20
Branch: sam/eng-21-price-formatter
OpenSpec change: receipt-prices (owns task group 1)

## Acceptance criteria
- `Decimal("1234.5")` formats as `$1,234.50`.
- `Decimal("2.345")` formats as `$2.35`.
- A float argument raises `TypeError`.
MD
git add -A
git commit -q -m "spec: receipt-prices (ENG-20)"
git checkout -q -b feature/receipt-prices
git checkout -q -b sam/eng-21-price-formatter
