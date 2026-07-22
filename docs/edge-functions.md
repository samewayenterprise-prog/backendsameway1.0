# Edge Functions — deploy, secrets, scheduling

Three functions ship in `supabase/functions/`:

| Function | Job | Trigger |
|---|---|---|
| `payments-watcher` | Charges accepted parcels (prepaid rule), charges booking fees via `record_booking_fee()`, executes the refund queue | Schedule: every minute |
| `notify-dispatch` | Delivers undelivered `notifications` rows via FCM (log-only without a key) | Schedule: every minute |
| `admin-kyc` | Manual KYC review: flips `id_verified_at` / `selfie_verified_at` | Called by you (secret header) |

The nightly **ride generator** is *not* an Edge Function — it's pure SQL
(`generate_recurring_rides()`, migration 0005) scheduled with pg_cron at
03:00 UTC, following the existing `expire-bookings` pattern. Generated
rides fire the existing follower fan-out trigger, so the follow loop is:
generator → rides insert → notifications rows → `notify-dispatch` → push.

## Deploy

```bash
supabase link --project-ref gipmcjmhqvtfcsssaotn   # once
supabase functions deploy payments-watcher
supabase functions deploy notify-dispatch
supabase functions deploy admin-kyc --no-verify-jwt
```

`admin-kyc` uses its own secret header instead of user JWTs, hence
`--no-verify-jwt`. The two watchers are invoked by the scheduler with the
project's authorization automatically.

## Secrets

```bash
supabase secrets set \
  PAYMENTS_MODE=sandbox \
  PARCEL_PLATFORM_PCT=10 \
  ADMIN_SECRET=<long random string>
# later, when push is wired:
supabase secrets set FCM_SERVER_KEY=<firebase cloud messaging server key>
# later, when Epoint is wired:
supabase secrets set PAYMENTS_MODE=epoint EPOINT_PUBLIC_KEY=... EPOINT_PRIVATE_KEY=...
```

`SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY` are injected automatically —
don't set them.

## Scheduling the two watchers

Dashboard → **Edge Functions → (function) → Schedules** (or the Cron
section, depending on dashboard version): add `* * * * *` for both
`payments-watcher` and `notify-dispatch`. If you prefer keeping schedules
in SQL, the pg_cron + `net.http_post` pattern works too — it needs the
`pg_net` extension enabled and the function URL + anon key; the dashboard
route is simpler and is what we assume.

## Sandbox mode — test the whole money flow today

With `PAYMENTS_MODE=sandbox` (default), charges/refunds settle instantly
with deterministic ids (`sbx_parcel:<id>` …), and the
`(provider, provider_txn_id)` unique index makes retries idempotent.

End-to-end recipe (two test users from `docs/dev-auth-skip-sms.md`):

1. Driver account publishes a ride with parcels enabled; sender account
   requests a parcel on it (`create_parcel`).
2. Driver accepts → 004's trigger stamps a 4-digit `delivery_code`.
3. Invoke the watcher once by hand:
   `curl -X POST https://<ref>.functions.supabase.co/payments-watcher`
   → response `{"parcels":1,...}`; the parcel flips to
   `payment_status='paid'` and a settled `charge` transaction exists with
   the 90/10 driver/platform split.
4. `notify-dispatch` (log-only without FCM key) marks the
   `parcel_accepted` notification sent.
5. KYC pass: review the uploads in Storage → `documents`, then
   ```bash
   curl -X POST https://<ref>.functions.supabase.co/admin-kyc \
     -H "x-admin-secret: $ADMIN_SECRET" -H "content-type: application/json" \
     -d '{"user_id":"<uuid>","id_verified":true,"selfie_verified":true}'
   ```
   → the app's O-54 screen now shows the instant-pass state.

## What's deliberately NOT here yet

- **Epoint live integration** — slots and TODOs are marked in
  `_shared/payments.ts`; needs their API docs + merchant keys. Includes
  the checkout-page flow + an `epoint-webhook` function for new-card
  payments (screen 46).
- **Payouts** (driver balance → card) — needs Epoint's payout API;
  design already in the tech doc.
- **FCM HTTP v1 migration** — legacy server-key endpoint is wired for
  speed; move to the OAuth service-account API before scale.
