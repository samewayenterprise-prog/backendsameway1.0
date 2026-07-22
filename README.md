# SameWay — Backend (Supabase)

Database schema, functions/triggers, RLS, and auth configuration for
SameWay. The Flutter client lives in `flutterpackmobile`; full product
context in the project doc set (tech doc, screen map, DESIGN.md).

## Layout
```
supabase/
  config.toml                  local-dev config (incl. test OTPs)
  migrations/
    20260723000001_schema.sql               35 tables, enums, seeds (ranks/badges)
    20260723000002_functions_triggers.sql   RPCs, gamification engine, penalties
    20260723000003_rls.sql                  57 policies, column grants, views
    20260723000004_product_deltas.sql       fee · delivery code · boost · return-ride · polyline
docs/
  dev-auth-skip-sms.md         phone sign-in with no SMS provider (test OTPs)
SEE_STATE.md                   execution state & remaining steps
```

## Applying to the hosted project
Fastest (no CLI): Dashboard → SQL Editor → paste & run each migration
**in filename order**. Then Table Editor should list users, rides,
bookings, ranks, … (35 tables).

CLI: `supabase link --project-ref gipmcjmhqvtfcsssaotn && supabase db push`.

## Auth (current phase)
SMS is intentionally skipped — see `docs/dev-auth-skip-sms.md`. Enable
the Phone provider and add the two test numbers; the mobile flow then
works end-to-end with fixed codes.

## Services layer (built)
`supabase/functions/` — payments-watcher, notify-dispatch, admin-kyc,
plus the SQL ride generator in migration 0005. Deploy, secrets,
schedules and the sandbox test recipe: `docs/edge-functions.md`.

## Next backend milestone
Epoint live integration (checkout flow + webhook function, payouts) —
slots marked in `supabase/functions/_shared/payments.ts`.
