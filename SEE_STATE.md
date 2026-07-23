# SEE — Execution State (backend)

GOAL: Backend repo ready — migrations, schema deltas, SMS-skip dev auth.

## Checkpoint log
- CP-1 · P1 done — repo skeleton, base migrations copied to
  supabase/migrations/ with CLI timestamp naming (…000001–000003).
- CP-2 · P2 done — 20260723000004_product_deltas.sql: booking fee
  (fee_amount + record_booking_fee() + refund-queue trigger), parcel
  delivery_code (accept-time trigger), routes.selected_polyline +
  toll_route, rides.boost_enabled, rides.return_of_ride_id.
  Additive-only; 001–003 untouched.
- CP-3 · P3 done — docs/dev-auth-skip-sms.md + config.toml test OTPs.
- CP-4 · P4 done — README, state file, handoff zip.

## Decisions in force
- Fee: flat per-seat, built now, launch value 0 ₼ (dormant).
- KYC: manual admin review at launch; vendor later.
- SMS: deferred; test OTPs until provider chosen (Twilio vs local AZ).
- Delivery code verified client-side in v1.

## Remaining (owner: Huseyn unless noted)
1. Push this repo (short-lived PAT scoped to backendsameway1.0 → Claude
   pushes, then revoke; or push manually).
2. Apply migrations to hosted project — SQL Editor, run 0001→0004 in
   order (or `supabase link` + `supabase db push`).
3. Dashboard: enable Phone provider + add the two test numbers.
4. Re-test mobile onboarding end-to-end with +994501234567 / 123456.
5. Later: pick SMS provider; Epoint Edge Functions (charge/refund
   watchers) — next backend milestone.

## CP-7 · Services layer (2026-07-23)
- Migration 0005: notifications.sent_at + unsent index; routes parcel
  prefs; generate_recurring_rides() (28-day horizon, watermark,
  idempotent via one_per_route_slot) + pg_cron 03:00; refund-queue index.
- Edge Functions: payments-watcher (parcel charges 90/10 split, booking
  fees via record_booking_fee, refund queue), notify-dispatch (FCM,
  log-only without key, original push copy per type), admin-kyc
  (secret-header manual review). Shared: service client + payment
  provider abstraction — sandbox default, Epoint slots marked TODO.
- Follow loop now complete on paper: generator → rides insert →
  fan-out trigger → notifications → notify-dispatch → FCM.

## Remaining after CP-7
1. Apply migrations 0001–0005 (SQL Editor, filename order).
2. Dashboard: Phone provider + test OTPs (docs/dev-auth-skip-sms.md).
3. Deploy the 3 functions + secrets + minute schedules
   (docs/edge-functions.md).
4. E2E: onboarding → publish weekly route → run generator once
   (`select generate_recurring_rides();`) → follower notification row.
5. Later: Epoint live (checkout + webhook), payouts, FCM v1, SMS vendor.

## CP-8 · Admin panel (2026-07-23)
- admin/ — single-file Express server (service-role key server-side
  only): password login (timing-safe, signed cookie), ops dashboard,
  KYC queue with 10-min signed previews from the private documents
  bucket (selfie via {uid}/selfie.jpg convention), Approve/Reject,
  reports queue (Uphold → resolved → penalty trigger; Dismiss), user
  search. Trust-zone light styling per DESIGN.md.
- Deploy kit: .env.example, systemd unit, docs/admin-deploy-vps.md —
  one-paste install for 46.224.137.253; default exposure = SSH tunnel
  (HOST=127.0.0.1), public mode documented with caveats.
- Clarified scope: VPS hosts ONLY the admin panel. Backend = hosted
  Supabase; mobile = TestFlight/APK.
- Gaps logged: app lacks a "KYC rejected — please redo" state.
- Process note: first commit attempt failed (git identity unset) and
  the clone was deleted before verification — rebuilt from session
  sources; rule going forward: verify pushed hash BEFORE cleanup.

## Remaining after CP-8
1–4. unchanged from CP-7 (migrations, test OTPs, function deploys, e2e).
5. VPS: run docs/admin-deploy-vps.md one-paste block; log in via tunnel.
6. Mobile: commit the local compile fixes from the Mac (const
   FileOptions removals + supabase_flutter imports) — repo is behind
   the working copy.
7. Revoke the PAT when this session's pushes are done.

## CP-9 · Admin deploy fix (2026-07-23)
- VPS deploy crash-looped (86 restarts): supabase-js always constructs a
  Realtime client, which needs a WebSocket impl; Node 20 has none native.
  Fix: add `ws` dep + pass `realtime: { transport: ws }` in server.js.
  Works on Node 20 and 22. Boot verified before push.
- Diagnostic note: the env file was fine all along (key present, 41
  chars); the "Missing env" hypothesis was wrong — journalctl gave the
  real cause. Rule: read journalctl BEFORE theorising about config.

## CP-10 · Migrations applied + repo fix (2026-07-23)
- Live database (gipmcjmhqvtfcsssaotn): all 5 migrations applied via
  Claude Code + supabase CLI (`db push`). 34 tables, RLS enabled on all,
  5 core RPCs present, ranks(30)/badges(10) seeded, both cron jobs
  active (expire-bookings, generate-recurring-rides).
- Repo fix pushed (0860016) so the migration file matches what's live:
  uuid_generate_v4() -> gen_random_uuid() (21×), gen_random_bytes(16) ->
  extensions.gen_random_bytes(16) (1×) in 20260723000001_schema.sql.
  Root cause: `supabase db push` runs migrations under a restricted
  search_path where unqualified extension functions don't resolve, even
  with the extension installed — pg_catalog functions (gen_random_uuid)
  always resolve; pgcrypto needed explicit schema-qualification instead.
- Database is now genuinely live. Admin panel should show real counts
  once refreshed. Mobile onboarding can now write real rows.

## CP-11 · RLS test suite + payouts (2026-07-23)
- supabase/tests/000_rls.test.sql: pgTAP, 28 assertions. Proves (not
  claims) cross-user isolation on users/verifications/bookings/
  transactions/driver_balances/messages/reports; insert-spoofing
  blocked on follows/blocks; anonymous access boundary; bookings
  RPC-only (direct INSERT denied); one column-lock spot check
  (driver_profiles counters). docs/rls-testing.md has run instructions
  (local via `supabase test db`, hosted via pgTAP extension + linked).
  Caught 2 real fixture bugs while writing it: follows_insert requires
  a driver_profiles row to exist (policy-level existence check), and
  driver_profiles has column-level grants on top of RLS.
- Migration 0006 (payouts): driver_balances had ZERO writers before
  this — a real gap. Added: trg_credit_driver_balance (+ an insert
  variant, since sandbox settles same-transaction) credits `pending`
  on settled charges, debits symmetrically on settled refunds with
  amount_driver>0, floored at 0 with a reconciliation note rather than
  going negative. batch_driver_payouts(min=5 AZN) sweeps pending into
  payouts rows weekly (Mon 04:00 UTC, after the nightly generator).
- payments-watcher extended with pass 4: executes pending payouts via
  the provider abstraction (sandbox default), flips sent/failed.
  Known gap flagged in docs: no stuck-processing recovery yet if the
  function crashes mid-payout — fine at test volume.
- _shared/payments.ts: added payout() to the provider interface;
  Epoint TODOs updated to include payout wiring.

## Remaining after CP-11
1. Push (needs a token or manual push — not yet pushed this round).
2. Run the RLS suite for real (`supabase test db --linked` after
   enabling pgTAP) — everything above is written+reasoned-through but
   UNVERIFIED against the live database. Say so plainly until it's run.
3. Everything from CP-9/CP-10 still open: Phone provider + test OTPs,
   Edge Function deploys + secrets + schedules, mobile onboarding e2e,
   mobile local-fix commit.
4. Revoke the PAT if/when used again for this push.

## CP-12 · Fee toggle (2026-07-23)
- Migration 0007 (platform_settings): singleton row (id=1) with
  fees_enabled + booking_fee_azn + parcel_platform_pct. Seeded with
  fees_enabled=FALSE (launch state = free for 3 months).
- create_booking updated to read fees_enabled fresh on every call —
  mid-day flip takes effect on the very next booking. Fee scales per
  seat (v_fee * p_seat_count), capping handled by admin.
- payments-watcher updated to read the same setting for parcel cut;
  when OFF, platform takes 0% (driver keeps 100% of parcel price).
- Admin panel: new Settings tab. One-click ON/OFF toggle, editable
  fee/pct amounts, plain-language explainer of what the toggle
  actually does to in-flight vs. new charges.
- Client-readable via RLS (public select) so the mobile app can show
  "SameWay is free right now" copy without needing a service call.

## Remaining after CP-12
1. Run migration 0006 + 0007 on hosted project (Claude Code or
   Supabase Dashboard SQL Editor).
2. VPS: git pull + systemctl restart sameway-admin to pick up the
   Settings page.
3. Redeploy payments-watcher (`supabase functions deploy
   payments-watcher`) so it reads the new setting.
4. Run the RLS suite for real — still WRITTEN NOT VERIFIED.
5. Phone provider + test OTPs, mobile e2e, revoke PAT.
