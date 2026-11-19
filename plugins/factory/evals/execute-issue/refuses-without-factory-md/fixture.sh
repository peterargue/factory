#!/usr/bin/env bash
# The same repo, but it has not joined the factory: no FACTORY.md. The skill's first
# rule is to stop and say so.
. "$(dirname "$0")/../_fixture/shop.sh"
shop_repo --no-factory
cat > issues/ENG-8.md <<'MD'
# ENG-8 Price formatting for receipts

State: Todo
Branch: sam/eng-8-price-format

Add a helper that formats a Decimal price as `$1,234.50` for receipts.

## Acceptance criteria
- `Decimal("1234.5")` formats as `$1,234.50`.
MD
git add -A
git commit -q -m "issue export (ENG-8)"
