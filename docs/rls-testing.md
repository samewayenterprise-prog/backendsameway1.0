# RLS test suite — how to run it

`supabase/tests/000_rls.test.sql` is a pgTAP test file that proves the
57 policies in `003_rls.sql` actually enforce the boundaries they claim
to — not just that they exist. 28 assertions across users, verification
documents, bookings, transactions, driver balances, messaging, reports,
follows/blocks, anonymous access, and column-level locks.

## Local (recommended — fast, safe, repeatable)

```bash
supabase start          # spins up the full local stack, pgTAP included
supabase test db
```

This runs against your local Postgres, wrapped in a transaction that
rolls back (`begin; ... rollback;` in the test file itself) — it never
touches real data, hosted or otherwise. Re-run after any RLS change.

## Hosted project

Two prerequisites, each needed once:

- pgTAP isn't enabled by default on hosted projects — enable it via
  Dashboard → Database → Extensions → pgtap, or:

  ```bash
  supabase link --project-ref gipmcjmhqvtfcsssaotn
  supabase db query --linked 'create extension if not exists pgtap with schema extensions;'
  ```

- `supabase test db --linked` does NOT work without Docker Desktop — the
  CLI runs pg_prove in a container even when targeting a remote database.
  If you have Docker, that command works. Without it, run the file
  directly with psql (verified working method):

```bash
PGPASSWORD='<db password>' psql \
  -h db.gipmcjmhqvtfcsssaotn.supabase.co -p 5432 -U postgres -d postgres \
  -X -tA -f supabase/tests/000_rls.test.sql \
  | grep -E '^(ok|not ok|1\.\.|#)'
```

The grep keeps only the TAP lines (`1..28`, per-assertion `ok`/`not ok`,
and `#` diagnostics for failures) and drops psql's INSERT/SET noise.
Expect `ok 1` … `ok 28` and no `not ok` lines; pgTAP prints a
`# Looks like you failed N tests of 28` trailer when anything fails.

Don't use `supabase db query --linked` to run the whole file — it only
returns the last statement's result set, which silently swallows every
assertion's output.

Same rollback safety applies — the test wraps itself in a transaction
and undoes all its fixture inserts, so running against the hosted
project never leaves data behind (even on failure: an aborted
transaction still ends at the file's `rollback`).

## Reading a failure

pgTAP prints `ok 1 - A can read own users row` / `not ok 12 - ...` per
assertion, plus a diff for `is()` failures showing expected vs actual.
A `not ok` means: either the RLS policy changed and the test needs
updating to match a deliberate decision, or the policy has a real hole
— read the assertion's description, it states the security property in
plain language.

## What's covered vs. not (be honest about the boundary)

Covered: cross-user reads on users/verifications/bookings/transactions
/driver_balances/messages/reports, insert spoofing on follows/blocks,
anonymous access, one column-lock example (driver_profiles counters),
and that bookings can't be written directly (RPC-only).

Not covered yet (add as separate test files when these areas grow):
storage bucket policies (`documents` private-bucket enforcement — pgTAP
can query `storage.objects` policies but wasn't included here to keep
the first pass focused on table RLS), the full column-lock list beyond
the one spot-check, and RPC-level authorization (e.g. that
`accept_booking_invite` can't be called with someone else's token).
