#!/usr/bin/env bash
# Shared fixture for the reviewer cases: a small Go service, "orders", checked out the
# way the review workflow checks a PR out — HEAD is the PR's merge commit and HEAD^1 its
# base. A case's fixture.sh sources this file, calls orders_base, makes its change on
# the `change` branch, then calls open_pr "<title>" "<description>".
set -euo pipefail

export GIT_AUTHOR_NAME=Sam GIT_AUTHOR_EMAIL=sam@example.com
export GIT_COMMITTER_NAME=Sam GIT_COMMITTER_EMAIL=sam@example.com

orders_base() {
  git init -q -b main .
  mkdir -p cmd/server internal/orders

  cat > CLAUDE.md <<'MD'
# orders

The order service. Go 1.25, standard library plus `database/sql`.

## Conventions

- Wrap errors with `%w` and return them; never log-and-continue on a write path.
- Every exported symbol has a godoc comment.
- No SQL outside `internal/orders/store.go`.
MD

  cat > go.mod <<'GO'
module example.com/orders

go 1.25
GO

  cat > Dockerfile <<'DOCKER'
FROM golang:1.25 AS build
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -o /out/server ./cmd/server

FROM alpine:3.20
COPY --from=build /out/server /server
USER 65534
ENTRYPOINT ["/server"]
DOCKER

  cat > cmd/server/main.go <<'GO'
// Command server runs the order service.
package main

import (
	"log"
	"net/http"

	"example.com/orders/internal/orders"
)

func main() {
	svc, err := orders.NewService()
	if err != nil {
		log.Fatalf("start: %v", err)
	}
	http.HandleFunc("/orders", svc.HandleCreate)
	log.Fatal(http.ListenAndServe(":8080", nil))
}
GO

  cat > internal/orders/service.go <<'GO'
// Package orders takes and stores customer orders.
package orders

import (
	"encoding/json"
	"fmt"
	"net/http"
)

// Order is one customer order.
type Order struct {
	ID       string `json:"id"`
	Customer string `json:"customer"`
	Cents    int64  `json:"cents"`
}

// Service handles order requests.
type Service struct {
	store *Store
}

// NewService builds a Service with its store.
func NewService() (*Service, error) {
	st, err := OpenStore()
	if err != nil {
		return nil, fmt.Errorf("open store: %w", err)
	}
	return &Service{store: st}, nil
}

// HandleCreate stores the order in the request body.
func (s *Service) HandleCreate(w http.ResponseWriter, r *http.Request) {
	var o Order
	if err := json.NewDecoder(r.Body).Decode(&o); err != nil {
		http.Error(w, "bad order", http.StatusBadRequest)
		return
	}
	if err := s.store.Save(r.Context(), o); err != nil {
		http.Error(w, "could not save order", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusCreated)
}
GO

  cat > internal/orders/store.go <<'GO'
package orders

import (
	"context"
	"database/sql"
	"fmt"
	"os"
)

// Store persists orders.
type Store struct {
	db *sql.DB
}

// OpenStore connects to the database named by DATABASE_URL.
func OpenStore() (*Store, error) {
	db, err := sql.Open("pgx", os.Getenv("DATABASE_URL"))
	if err != nil {
		return nil, fmt.Errorf("open db: %w", err)
	}
	return &Store{db: db}, nil
}

// Save inserts one order.
func (s *Store) Save(ctx context.Context, o Order) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO orders (id, customer, cents) VALUES ($1, $2, $3)`,
		o.ID, o.Customer, o.Cents)
	if err != nil {
		return fmt.Errorf("insert order %s: %w", o.ID, err)
	}
	return nil
}
GO

  git add -A
  git commit -q -m "orders service"
  git checkout -q -b change
}

# open_pr TITLE DESCRIPTION — commit the change, merge it into main the way GitHub's
# merge ref does, and leave PR.md (untracked) standing in for `gh pr view`.
open_pr() {
  git add -A
  git commit -q -m "$1"
  local head
  head=$(git rev-parse HEAD)
  git checkout -q main
  git merge -q --no-ff --no-edit change -m "Merge $head into main"
  cat > PR.md <<MD
# #42 $1

Head SHA: $head
Base: main

$2
MD
}
