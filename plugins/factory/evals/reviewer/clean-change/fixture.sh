#!/usr/bin/env bash
. "$(dirname "$0")/../_fixture/orders.sh"
orders_base
python3 - <<'PY'
p = "internal/orders/service.go"
s = open(p).read()
s = s.replace("""	if err := s.store.Save(r.Context(), o); err != nil {""", """	if o.ID == "" || o.Customer == "" {
		http.Error(w, "order needs an id and a customer", http.StatusBadRequest)
		return
	}
	if o.Cents <= 0 {
		http.Error(w, "order total must be positive", http.StatusBadRequest)
		return
	}
	if err := s.store.Save(r.Context(), o); err != nil {""")
open(p, "w").write(s)
PY
cat > internal/orders/service_test.go <<'GO'
package orders

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHandleCreateRejectsIncompleteOrders(t *testing.T) {
	s := &Service{}
	for _, body := range []string{
		`{"customer":"ana","cents":100}`,
		`{"id":"o1","cents":100}`,
		`{"id":"o1","customer":"ana","cents":0}`,
		`{"id":"o1","customer":"ana","cents":-5}`,
	} {
		w := httptest.NewRecorder()
		s.HandleCreate(w, httptest.NewRequest(http.MethodPost, "/orders", strings.NewReader(body)))
		if w.Code != http.StatusBadRequest {
			t.Errorf("%s: status %d, want 400", body, w.Code)
		}
	}
}
GO
open_pr "Reject orders without an id, a customer or a positive total" "Validation before the insert, so bad requests get a 400 instead of a database error. The test never reaches the store, so it needs no database."
