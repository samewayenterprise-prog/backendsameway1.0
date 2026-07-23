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
