-- ============================================================
-- YOLDA · 003_rls.sql
-- Row Level Security for every table + column-level grants
--
-- Principles:
--   · users row = private (phone/email/DOB). Others read via
--     public_profiles view (001).
--   · Writes that must be atomic (booking, invites, approve,
--     cancel) go through SECURITY DEFINER RPCs (002); direct
--     table writes are denied.
--   · Money tables: client read-only; writes = service_role
--     (Edge Functions / webhooks) only.
--   · Denormalized counters: column-level REVOKE so clients
--     can't tamper even where row UPDATE is allowed.
-- ============================================================

-- ---------- enable RLS everywhere ----------
alter table public.users                     enable row level security;
alter table public.user_verifications       enable row level security;
alter table public.user_preferences         enable row level security;
alter table public.driver_profiles          enable row level security;
alter table public.vehicles                 enable row level security;
alter table public.routes                   enable row level security;
alter table public.route_stops              enable row level security;
alter table public.rides                    enable row level security;
alter table public.ride_stops               enable row level security;
alter table public.bookings                 enable row level security;
alter table public.booking_passengers       enable row level security;
alter table public.booking_invites          enable row level security;
alter table public.parcels                  enable row level security;
alter table public.badges                   enable row level security;
alter table public.user_badges              enable row level security;
alter table public.user_points              enable row level security;
alter table public.point_transactions       enable row level security;
alter table public.route_streaks            enable row level security;
alter table public.rider_streaks            enable row level security;
alter table public.ranks                    enable row level security;
alter table public.user_ranks               enable row level security;
alter table public.follows                  enable row level security;
alter table public.reviews                  enable row level security;
alter table public.conversations            enable row level security;
alter table public.conversation_participants enable row level security;
alter table public.messages                 enable row level security;
alter table public.payment_methods          enable row level security;
alter table public.transactions             enable row level security;
alter table public.payouts                  enable row level security;
alter table public.driver_balances          enable row level security;
alter table public.notifications            enable row level security;
alter table public.device_tokens            enable row level security;
alter table public.reports                  enable row level security;
alter table public.blocks                   enable row level security;

-- ============================================================
-- USERS — owner-only. Everyone else uses public_profiles view.
-- ============================================================
create policy users_select_own on public.users
  for select using (id = auth.uid());

create policy users_update_own on public.users
  for update using (id = auth.uid()) with check (id = auth.uid());
-- insert handled by signup trigger (security definer); no delete (soft-delete flag)

-- ============================================================
-- USER_VERIFICATIONS — owner reads status; only service writes.
-- id_document_url stays server-side.
-- ============================================================
create policy uv_select_own on public.user_verifications
  for select using (user_id = auth.uid());

-- Column privileges are ADDITIVE in Postgres: a table-level SELECT
-- grant covers all columns, so "revoke select (col)" alone does
-- nothing. Correct pattern = revoke table, grant column list.
revoke select on public.user_verifications from authenticated;
grant select (user_id, phone_verified_at, email_verified_at,
              id_verified_at, selfie_verified_at)
  on public.user_verifications to authenticated;   -- id_document_url excluded
-- no insert/update/delete policies → client writes denied

-- ============================================================
-- USER_PREFERENCES — owner full control. Ride participants can
-- read each other's comfort prefs (chattiness/music/…).
-- ============================================================
create policy prefs_own on public.user_preferences
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());
-- Others read chattiness/music/smoking/pets via public_preferences
-- view (001); notification settings never leave the owner.

-- ============================================================
-- DRIVER_PROFILES — public read; owner may edit license fields;
-- counters are trigger-maintained and locked at column level.
-- ============================================================
create policy dp_select_all on public.driver_profiles
  for select using (true);

create policy dp_insert_own on public.driver_profiles
  for insert with check (user_id = auth.uid());

create policy dp_update_own on public.driver_profiles
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Lock counters (trigger-maintained) and hide license PII.
revoke update on public.driver_profiles from authenticated;
grant update (license_number, license_url)
  on public.driver_profiles to authenticated;

revoke select on public.driver_profiles from authenticated;
grant select (user_id, license_verified_at,
              rating_avg, rating_count, ride_count, follower_count)
  on public.driver_profiles to authenticated;
-- license_number / license_url: service_role only

-- ============================================================
-- VEHICLES — owner CRUD; others see active vehicles (ride detail).
-- Registration doc stays private.
-- ============================================================
create policy veh_select on public.vehicles
  for select using (is_active or driver_id = auth.uid());

create policy veh_cud on public.vehicles
  for all using (driver_id = auth.uid()) with check (driver_id = auth.uid());

-- Plate stays visible (riders need it at pickup); the uploaded
-- registration document does not.
revoke select on public.vehicles from authenticated;
grant select (id, driver_id, make, model, color, year, plate_number,
              seats, verified_at, is_active)
  on public.vehicles to authenticated;

-- ============================================================
-- ROUTES / ROUTE_STOPS — driver CRUD; public read active routes
-- (powers "routes he runs" on the profile page).
-- ============================================================
create policy routes_select on public.routes
  for select using (is_active or driver_id = auth.uid());

create policy routes_cud on public.routes
  for all using (driver_id = auth.uid()) with check (driver_id = auth.uid());

create policy rstops_select on public.route_stops
  for select using (exists (select 1 from public.routes r
                            where r.id = route_id
                              and (r.is_active or r.driver_id = auth.uid())));

create policy rstops_cud on public.route_stops
  for all
  using (exists (select 1 from public.routes r
                 where r.id = route_id and r.driver_id = auth.uid()))
  with check (exists (select 1 from public.routes r
                      where r.id = route_id and r.driver_id = auth.uid()));

-- ============================================================
-- RIDES / RIDE_STOPS — anyone can search published rides;
-- driver manages own. Seat counts are RPC-managed → lock column.
-- ============================================================
create policy rides_select on public.rides
  for select using (status in ('published','full') or driver_id = auth.uid());

create policy rides_insert_own on public.rides
  for insert with check (
    driver_id = auth.uid()
    and exists (select 1 from public.vehicles v
                where v.id = vehicle_id and v.driver_id = auth.uid() and v.is_active)
  );

create policy rides_update_own on public.rides
  for update using (driver_id = auth.uid()) with check (driver_id = auth.uid());

create policy rides_delete_own on public.rides
  for delete using (driver_id = auth.uid() and status = 'published');

-- Seat inventory moves ONLY through booking RPCs.
revoke update on public.rides from authenticated;
grant update (vehicle_id, from_address, from_lat, from_lng,
              to_address, to_lat, to_lng, departure_at,
              arrival_estimate_at, price_per_seat, status,
              polyline, notes, accepts_cash, accepts_card,
              instant_book, ladies_only)
  on public.rides to authenticated;

create policy ridestops_select on public.ride_stops
  for select using (exists (select 1 from public.rides r
                            where r.id = ride_id
                              and (r.status in ('published','full')
                                   or r.driver_id = auth.uid())));

create policy ridestops_cud on public.ride_stops
  for all
  using (public.is_ride_driver(ride_id))
  with check (public.is_ride_driver(ride_id));

-- ============================================================
-- BOOKINGS — read: members (lead, group, driver). Writes: RPC only.
-- ============================================================
create policy bookings_select_member on public.bookings
  for select using (public.is_booking_member(id));
-- no insert/update/delete policies → all writes via RPCs in 002

-- ============================================================
-- BOOKING_PASSENGERS — members read; invitee updates own row
-- (decline); everything else via RPC.
-- ============================================================
create policy bp_select_member on public.booking_passengers
  for select using (public.is_booking_member(booking_id));

create policy bp_update_self on public.booking_passengers
  for update using (user_id = auth.uid())
  with check (user_id = auth.uid() and status in ('confirmed','declined'));

-- ============================================================
-- BOOKING_INVITES — lead sees own invites. Token redemption via
-- accept_booking_invite() RPC; no open select on tokens.
-- ============================================================
create policy invites_select_creator on public.booking_invites
  for select using (created_by = auth.uid());
-- writes via RPC only

-- ============================================================
-- PARCELS — sender and the ride's driver can read; all writes
-- via RPC (create_parcel / respond_parcel / mark_parcel_delivered).
-- ============================================================
create policy parcels_select on public.parcels
  for select using (
    sender_id = auth.uid() or public.is_ride_driver(ride_id)
  );
-- no insert/update/delete policies → client writes denied, RPC only

-- ============================================================
-- GAMIFICATION — badges catalog is public; earned badges,
-- points, and streaks are public read (they're social proof on
-- profiles) but writes are trigger/RPC-only, never client.
-- ============================================================
create policy badges_select_all on public.badges
  for select using (true);

create policy user_badges_select_all on public.user_badges
  for select using (true);

create policy user_points_select_all on public.user_points
  for select using (true);

create policy ptxn_select_own on public.point_transactions
  for select using (user_id = auth.uid());

create policy route_streaks_select_all on public.route_streaks
  for select using (true);

create policy rider_streaks_select_own on public.rider_streaks
  for select using (user_id = auth.uid());

create policy ranks_select_all on public.ranks
  for select using (true);

create policy user_ranks_select_all on public.user_ranks
  for select using (true);
-- all writes for this whole block happen via SECURITY DEFINER
-- trigger functions (002) — no client insert/update/delete policies


-- ============================================================
create policy follows_select on public.follows
  for select using (follower_id = auth.uid() or driver_id = auth.uid());

create policy follows_insert on public.follows
  for insert with check (
    follower_id = auth.uid()
    and exists (select 1 from public.driver_profiles dp where dp.user_id = driver_id)
    and not exists (select 1 from public.blocks b
                    where b.blocker_id = driver_id and b.blocked_id = auth.uid())
  );

create policy follows_delete on public.follows
  for delete using (follower_id = auth.uid());

-- ============================================================
-- REVIEWS — public read (profile pages). Insert only by a member
-- of a COMPLETED booking, about another member, once.
-- ============================================================
create policy reviews_select_all on public.reviews
  for select using (true);

create policy reviews_insert on public.reviews
  for insert with check (
    reviewer_id = auth.uid()
    and reviewee_id <> auth.uid()
    and (
      (booking_id is not null
        and public.is_booking_member(booking_id)
        and exists (select 1 from public.bookings b
                    where b.id = booking_id and b.status = 'completed'))
      or
      (parcel_id is not null
        and exists (select 1 from public.parcels p
                    where p.id = parcel_id and p.status = 'delivered'
                      and (p.sender_id = auth.uid() or public.is_ride_driver(p.ride_id))))
    )
  );
-- no update/delete → reviews are immutable from the client

-- ============================================================
-- MESSAGING — participants only, everywhere.
-- ============================================================
create policy conv_select on public.conversations
  for select using (public.is_conversation_member(id));

create policy cp_select on public.conversation_participants
  for select using (public.is_conversation_member(conversation_id));

create policy cp_update_own on public.conversation_participants
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy msg_select on public.messages
  for select using (public.is_conversation_member(conversation_id));

create policy msg_insert on public.messages
  for insert with check (
    sender_id = auth.uid()
    and is_system = false
    and public.is_conversation_member(conversation_id)
  );

-- ============================================================
-- PAYMENTS — strict. Client reads own; ALL writes via service_role
-- (Edge Functions + provider webhooks). provider_token never
-- reaches the client.
-- ============================================================
create policy pm_select_own on public.payment_methods
  for select using (user_id = auth.uid());

create policy pm_delete_own on public.payment_methods
  for delete using (user_id = auth.uid());

revoke select on public.payment_methods from authenticated;
grant select (id, user_id, type, provider, last4, label, is_default)
  on public.payment_methods to authenticated;   -- provider_token excluded
-- insert/update via service role only (tokenization happens server-side)

create policy txn_select_own on public.transactions
  for select using (payer_id = auth.uid() or driver_id = auth.uid());

create policy payouts_select_own on public.payouts
  for select using (driver_id = auth.uid());

create policy balances_select_own on public.driver_balances
  for select using (driver_id = auth.uid());

-- ============================================================
-- NOTIFICATIONS — owner reads + marks read. Created by triggers.
-- ============================================================
create policy notif_select_own on public.notifications
  for select using (user_id = auth.uid());

create policy notif_update_own on public.notifications
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());

revoke update on public.notifications from authenticated;
grant update (read_at) on public.notifications to authenticated;

create policy notif_delete_own on public.notifications
  for delete using (user_id = auth.uid());

-- ============================================================
-- DEVICE_TOKENS — owner CRUD.
-- ============================================================
create policy dt_own on public.device_tokens
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ============================================================
-- REPORTS — reporter creates + sees own; ops handles the rest.
-- ============================================================
create policy reports_insert on public.reports
  for insert with check (reporter_id = auth.uid());

create policy reports_select_own on public.reports
  for select using (reporter_id = auth.uid());

-- ============================================================
-- BLOCKS — blocker manages own list.
-- ============================================================
create policy blocks_own on public.blocks
  for all using (blocker_id = auth.uid()) with check (blocker_id = auth.uid());

-- ============================================================
-- STORAGE BUCKETS (run in Supabase dashboard or here)
-- ============================================================
insert into storage.buckets (id, name, public)
values ('avatars','avatars', true),
       ('vehicles','vehicles', true),
       ('documents','documents', false)        -- IDs, licenses, registrations
on conflict (id) do nothing;

create policy avatars_read on storage.objects
  for select using (bucket_id in ('avatars','vehicles'));

create policy avatars_write_own on storage.objects
  for insert with check (
    bucket_id in ('avatars','vehicles')
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy docs_write_own on storage.objects
  for insert with check (
    bucket_id = 'documents'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
-- documents bucket: no select policy for authenticated → service_role only
