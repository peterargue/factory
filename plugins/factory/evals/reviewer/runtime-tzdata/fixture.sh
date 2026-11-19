#!/usr/bin/env bash
. "$(dirname "$0")/../_fixture/orders.sh"
orders_base
cat > internal/orders/cutoff.go <<'GO'
package orders

import (
	"fmt"
	"time"
)

// Cutoff decides which business day an order belongs to. Orders after 17:00 Toronto
// time count toward the next day.
type Cutoff struct {
	loc *time.Location
}

// NewCutoff loads the Toronto time zone.
func NewCutoff() (*Cutoff, error) {
	loc, err := time.LoadLocation("America/Toronto")
	if err != nil {
		return nil, fmt.Errorf("load time zone: %w", err)
	}
	return &Cutoff{loc: loc}, nil
}

// BusinessDay returns the date an order placed at t is booked under.
func (c *Cutoff) BusinessDay(t time.Time) time.Time {
	local := t.In(c.loc)
	day := time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, c.loc)
	if local.Hour() >= 17 {
		day = day.AddDate(0, 0, 1)
	}
	return day
}
GO
cat > internal/orders/cutoff_test.go <<'GO'
package orders

import (
	"testing"
	"time"
)

func TestBusinessDayRollsOverAtFive(t *testing.T) {
	c, err := NewCutoff()
	if err != nil {
		t.Fatal(err)
	}
	at := time.Date(2026, 11, 19, 22, 30, 0, 0, time.UTC) // 17:30 in Toronto
	if got := c.BusinessDay(at).Day(); got != 20 {
		t.Fatalf("day = %d, want 20", got)
	}
}
GO
python3 - <<'PY'
import re
p = "internal/orders/service.go"
s = open(p).read()
s = s.replace("type Service struct {\n\tstore *Store\n}", "type Service struct {\n\tstore  *Store\n\tcutoff *Cutoff\n}")
s = s.replace("""	return &Service{store: st}, nil""", """	cut, err := NewCutoff()
	if err != nil {
		return nil, fmt.Errorf("cutoff: %w", err)
	}
	return &Service{store: st, cutoff: cut}, nil""")
open(p, "w").write(s)
PY
open_pr "Book late orders to the next business day" "Orders placed after 17:00 Toronto time now count toward the next business day. Adds Cutoff with a unit test; tests pass locally on my Mac."
