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
