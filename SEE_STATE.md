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

## CP-13 · Markets / country registry (2026-07-23)
- Migration 0008 (markets): countries table — 249 ISO 3166-1
  entries (generated via pycountry + pycountry-convert, 10 territories
  needing manual region assignment fixed by hand), grouped by region
  (7: Africa/Asia/Europe/N.America/S.America/Oceania/Antarctica) with
  finer subregions carved out for Caucasus/Central Asia/Middle East
  (the likely next-expansion neighbors). Each row: is_active
  (market open/closed), payment_provider + payment_status enum
  (not_connected/pending/connected/suspended), currency_code.
  AZ pre-seeded: active=true, provider=epoint, status=connected —
  matches the real current state. Every other market ships CLOSED;
  nothing auto-opens. RLS: public read (mobile can show "live in your
  country" / "coming soon"), writes are admin-panel/service-role only.
- Admin panel: new Markets page. Region pill-nav, search by name/ISO,
  "active only" filter, grouped rows with region/subregion headers,
  each row a single form (currency, payment status dropdown, provider
  text field, active checkbox) + one Save button.
- Verified: migration SQL regenerated deterministically (same row
  count, same AZ row) after a git-identity mistake destroyed the first
  attempt's working files; server.js syntax (node --check); grouping
  logic against mock data. NOT YET run against the live database.
- Process failure (second occurrence): repeated the exact CP-8
  mistake — fresh clone without git identity set, silent commit
  failure, premature `rm -rf` before checking. The written rule
  ("verify hash before cleanup") wasn't enough by itself. New rule:
  set git config user.email/user.name IMMEDIATELY after every fresh
  clone, before any other command, no exceptions — make it the first
  line after `git clone`, not something done "when committing."

## Remaining after CP-13
1. Apply migration 0008 (Claude Code / supabase db push).
2. VPS: git pull + restart to get the Markets tab.
3. Everything still open from CP-9 through CP-12.

## CP-14 · Research recommendations applied (2026-07-23)
Migrations 0010–0012 + admin surfaces, from the BlaBlaCar/market research.

- 0010 PRICING. Two distinct mechanisms, both needed:
  * cost_share_ceiling() — HARD block, the legal safe-harbour. Driver
    cannot publish above it. This was the research's #1 risk (no price
    cap = drivers can profit = unlicensed commercial transport under
    the AYNA taxi regime, since AZ has no carpooling statute).
  * ride_price_guidance() — SOFT advisory returning corridor
    percentiles for the price meter Huseyn asked for.
  Params global + per-country overridable (opening a market = setting
  its fuel price, not editing code).
  Numeric verification caught three real bugs before shipping:
    1. straight-line distance understated Baku–Ganja by 26% → ceiling
       blocked the design's own 15 AZN fare → road_distance_factor 1.30
    2. multiplier permitted PROFIT above 4 seats (schema allows 8) →
       added LEAST(..., trip_cost/seats) hard bound
    3. round() rounded up past cost by qapik → truncate instead
  A short-trip floor was tried and rejected: 8 seats × floor on a 26 km
  hop = minibus economics. Replaced with base_trip_cost_azn so the
  invariant holds by construction. Verified: 3 corridors × 8 seat
  counts, collected never exceeds cost, realistic fares still publish.

- 0011 INTEGRITY & SAFETY.
  * CHECK (seats_available between 0 and seats_total) — DB-level
    oversell guard beneath the existing FOR UPDATE logic.
  * accept_booking_invite now checks the BOOKING's expiry, not just
    the invite's — real gap, sweeper can lag 60s+ and pg_cron never
    retries.
  * STREAK SAFETY: driver route-streak moved from ride COMPLETION to
    ride PUBLISH. A completion-based streak tells a tired driver
    "drive tonight or lose 12 weeks" — the Uber gamification failure
    mode. Now publishing availability maintains it; cancelling costs
    nothing. Freezes 1→2/quarter. Rider streaks left on completion
    (passengers carry no equivalent safety pressure).
  * parcels.declared_value + platform cap (crowdshipping liability).

- 0012 PERF & OPS.
  * All 42 policies referencing auth.uid() rewritten to
    (select auth.uid()) — generated mechanically from 003 and
    diff-checked so predicates cannot drift. Per-row → per-query
    evaluation.
  * 16 indexes on RLS predicate columns.
  * Follower fan-out moved OUT of the publish transaction into a job
    queue + worker. Previously a 5,000-follower driver did 5,000
    inserts before publish could commit — publish got slower the more
    successful the driver became.
  * job_runs + run_job() wrapper + job_health view; generator and
    payout cron re-pointed through it. pg_cron has no retry, no
    alerting, and silently skips overlapping runs.
  * corridor_liquidity() + fee-gate thresholds: fee activation is a
    liquidity decision, not a calendar one.

- Admin: new Ops tab (cron health, notification backlog, fee-readiness
  vs thresholds); Settings gains pricing params + gate thresholds.
- docs/pricing-and-legal.md explains why ceiling ≠ meter.

NOT done (needs external input, flagged in research):
  * AZ legal counsel on: platform fee vs commercial classification;
    whether the 90/10 parcel split is freight brokerage; store
    compliance. Cannot be resolved by building.
  * KYC vendor (Sumsub/Veriff both cover AZ/Cyrillic) — pick + sandbox.
  * Ladies-only already existed in schema (ladies_only + gender check
    in create_booking) — research flagged it as missing; it is not.
  * Prohibited-items policy TEXT still to write (prohibited_ack column
    and CHECK already existed).

## STANDING RULE — commit message format (2026-07-23, permanent)

Every commit from here forward must contain BOTH, in the commit message
body itself (not only in CHANGELOG.md):

1. A PLAIN-LANGUAGE paragraph first — explain what changed and why it
   matters as if to a smart 15-year-old or a non-technical cofounder.
   No jargon, no code terms. What does this mean for the product/users?
2. The TECHNICAL description after — what actually changed in the code,
   for a developer reading `git log`.

CHANGELOG.md still gets its own entry too (same plain-language content,
permanently browsable on GitHub without reading commit history) — the
changelog does NOT replace this, both are required going forward.

Template:

    <short technical summary line>

    PLAIN ENGLISH: <what changed and why it matters, no jargon>

    TECHNICAL: <what actually changed, for developers>

This applies to every future commit in this repo, regardless of which
Claude session or Claude Code session makes it. Do not drop this
format even for small fixes.

## CP-15 · Ride companion visibility (2026-07-23)
Gap found by direct BlaBlaCar comparison (user tested their own account):
on a ride detail screen — including a PAST completed ride — BlaBlaCar
shows "Other passengers: Oliwia (+1)" across booking groups, tap-through
to her full profile, rate/report/message all still available, no time
cutoff. Our booking_passengers RLS (bp_select_member) correctly scopes
to the caller's OWN booking group — that's right for the table itself
(invite tokens, pending slots live there) but left no way to see other
groups on the same ride. That was the actual, sole gap.

Checked and confirmed NOT broken (no change needed):
  * messaging — conversations are per-BOOKING already (trigger
    trg_booking_conversation), so separate threads per group already
    matches observed behaviour
  * reviews — reviews_insert already has no time cutoff, only requires
    booking.status='completed' + is_booking_member
  * reporting — reports_insert only checks reporter_id = auth.uid(),
    takes any reported_user_id, zero booking-scoping to begin with

Built: migration 0013, ride_companions(ride_id) SECURITY DEFINER
function. Grouped by lead passenger + companion count (matches
"Oliwia (+1)" exactly, not a flat name list). Excludes caller's own
booking (screen is titled "Other passengers"). Gated: caller must
themselves be a confirmed passenger or the driver of THAT ride, else
empty result (not an error) — not a general roster lookup. No time
cutoff, by design, matching the observed behaviour.
Verified the join/grouping logic against mock data from 3 perspectives
(rider seeing others, a different rider, the driver) before shipping —
all three produced the expected "(+N)" groupings.
docs/ride-companions.md written alongside.

## Remaining after CP-15
1. Apply migration 0013 (Claude Code / supabase db push).
2. Mobile: add "Other passengers" entry point on ride detail (S-10),
   works on past rides too — not built yet, doc has the pointer.
3. Everything still open from CP-9 through CP-14.

## CP-16 · Pre-booking ride inquiries (2026-07-23)
Gap found by direct BlaBlaCar comparison: a "Negocjuj" (Negotiate)
button on ride detail, separate from Book, opens 4 templated questions
(different meeting point / different drop-off / another special
request / just want to chat) and starts a chat thread with the driver
— with NO booking request behind it at all. Distinct from our existing
screen-45 message, which fires AFTER a booking request exists.

Confirmed complete gap before building (not partial): conversations.
booking_id was already nullable so a ride-only thread was structurally
possible, but the ONLY insert path was trg_booking_conversation, gated
on booking.status='confirmed'. conversation_type_t had no type for
this. RLS (is_conversation_member) is correctly circular for
bootstrapping — nothing could have created a usable pre-booking
conversation via a raw insert either.

Built: migration 0015. start_ride_inquiry(ride_id, template, message)
— SECURITY DEFINER RPC, same pattern as create_booking (does its own
RLS-protected inserts, no policy changes needed since existing
conv_select/msg_select/cp_select already key off
conversation_participants membership). Find-or-reuse via a
(ride_id, initiator_id) partial unique index + ON CONFLICT — one
thread per rider per ride, race-safe against a double-tap, verified by
hand-tracing 5 scenarios (new/repeat/second-rider/driver-blocked/
concurrent) before shipping. messages.inquiry_template tags the
prompting category on the first message. Existing messages_scrub and
messages_notify triggers fire automatically, no duplication.

Noted a real Postgres caveat in the migration + doc: ALTER TYPE ADD
VALUE can't be used in the same command that adds it — placed first in
the file for that reason, flagged clearly so a future failure there
isn't mysterious.

## Remaining after CP-16
1. Apply migration 0015 (git pull + supabase db push).
2. Mobile: ride detail needs a "Negotiate" button + 4-template picker
   (doc has the screen pointer) — not built.
3. Everything still open from CP-9 through CP-15.

## CP-17 · Table admin — the Django-admin equivalent (2026-07-23)
Prompted by seeing another project's Django admin (auto-CRUD for every
model). We have no ORM/Django-equivalent — hand-built one bespoke page
per workflow, leaving ~30 of 37 tables with zero admin visibility.

Built: admin/data-admin.js mounts AdminJS (verified real package,
inspected actual installed source before writing code, not from memory)
at /data via @adminjs/sql's raw-Postgres adapter — auto-introspects the
schema, no ORM/models needed. Three-tier safety policy per table (FULL
CRUD / READ-ONLY / HIDDEN) so this can't be used to bypass the
integrity rules built earlier today (price ceiling, trigger-owned
counters, ledger-only-via-service-role). New tables must be triaged
before being added — default is NOT full CRUD.

Real bug found and fixed, not worked around: @adminjs/sql v2.2.6's
FK-detection query identifies a table by bare `relname` with zero
schema qualification. Every real Supabase project has both auth.users
and public.users — the moment this library introspects `users`
specifically, that ambiguity throws "more than one row returned by a
subquery," silently dropping the single most important table from the
admin entirely. Confirmed structural (would hit the real hosted DB
identically), not a local-only quirk. Considered and REJECTED a
users_admin view-based workaround (dodges the crash but breaks every
other table's auto-linked "click to view this user" relation, since
FK-matching is by table name). Instead patched the actual 1-line bug
via patch-package, schema-qualifying the query using a parameter
(schemaName) the function already received but never used. Verified
via a from-scratch `rm -rf node_modules && npm install` that the patch
auto-reapplies through postinstall — this is exactly what happens on
the VPS's first install.

Testing discipline: since this sandbox has no live Supabase project,
installed Postgres 16 locally, hand-built a stand-in auth/storage/cron
layer (roles, auth.uid(), schemas, foldername helper) matching real
Supabase's shape, and applied all 16 real migrations end to end — 37
tables came back clean. Then actually logged in through the real HTTP
login flow, followed the session cookie, and confirmed against the
real JSON API (not just the SPA shell, which returns identical bytes
for valid/invalid resources — caught myself nearly treating that as
proof before checking further): users resource returns real paginated
data; user_verifications is genuinely unreachable (the error response
lists every actually-registered resource, and it's absent); the
transactions edit action is genuinely forbidden (AdminJS reports
action-level errors in the JSON body as ForbiddenError, not via HTTP
status — worth knowing for future debugging here).

Also found and fixed a dormant bug: .gitignore's `.env.*` pattern was
also silently blocking `.env.example` from ever being committed all
session — every earlier "update" to that file was invisible to git.
Fixed with a `!.env.example` negation, verified against a minimal
isolated repo first since git check-ignore's exit code turned out not
to mean what it looks like it means (git status/add is the real
ground truth, not check-ignore's exit code).

## Remaining after CP-17
1. Set SUPABASE_DB_URL in /etc/sameway-admin.env on the VPS (Supabase
   Dashboard -> Project Settings -> Database -> Connection string),
   git pull, npm install (patch auto-applies), systemctl restart.
2. Everything still open from CP-9 through CP-16.

## CP-17 addendum — the patch needed two more fixes than first thought
Re-verified from a clean state after this session's Postgres service
restarted mid-testing (filesystem/repo state survived intact, only the
DB server process died — re-confirmed by re-running every test that
had already passed, rather than trusting stale output).

The originally-committed patch only fixed the foreign-key-detection
query (fix #1). Re-running the FULL verification chain surfaced two
more, real bugs from the exact same root cause (unqualified table-name
matching across the auth/public schema collision):

- Fix #2: the primary-key-detection join
  (`information_schema.key_column_usage`) matched on table_name only,
  missing table_schema — silently duplicating rows instead of erroring.
- Fix #3: those duplicate rows collide with a SEPARATE, genuine fact
  about our schema — `users.id` is legitimately both the primary key
  AND a foreign key (to auth.users). Even with fix #2 alone, `id` still
  produces two joined rows (one per constraint), and whichever lands
  second silently overwrites the correct one — breaking primary-key
  detection entirely (`idColumn` resolved to `undefined`, which would
  make AdminJS refuse to build the resource at all). Fixed by
  deduplicating in JS, preferring whichever row is actually flagged
  PRIMARY KEY.

Stopping after fix #1 alone would have left `users` appearing to work
(present in the table list) while being silently broken underneath —
worse than an obvious error, since it might not have surfaced until
someone actually tried to use the Users resource. Regenerated the
patch file via `npx patch-package @adminjs/sql` to capture all three
fixes as one complete diff, then re-ran the entire verification chain
(clean reinstall, real login, real session, real query against a real
seeded row, idProperty resolving to 'id', a genuine FK on a different
table still resolving correctly, user_verifications' 500 body
literally listing all 37 registered resources with it absent,
transactions' new-action ForbiddenError, and the complete server.js
booting both old and new routes side by side) against the corrected
patch before trusting it.
