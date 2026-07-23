-- ============================================================
-- RLS TEST SUITE
-- Proves the policies in 003_rls.sql actually do what they claim,
-- instead of leaving that as an unverified assumption. Run with:
--   supabase test db
-- (uses pgTAP; Supabase's local stack has it pre-installed. On the
-- hosted project, run via `supabase db test --db-url <connection>`
-- or apply pgTAP once and run manually — see docs/rls-testing.md.)
--
-- Pattern: two fake users (A, B) plus one unrelated bystander (C) for
-- ride/booking scenarios. Each assertion switches the session's JWT
-- claims to a user's `sub`, sets role to `authenticated`, then checks
-- what that user CAN and CANNOT see. Every "cannot see" assertion is
-- as important as the "can see" ones — that's the actual security
-- boundary being proven.
-- ============================================================
begin;
select plan(28);

-- ------------------------------------------------------------
-- FIXTURES
-- ------------------------------------------------------------
-- phones must be distinct here: handle_new_user() mirrors them into
-- public.users, whose phone column is unique (coalesce(null,'') collides)
insert into auth.users (id, email, phone) values
  ('a0000000-0000-0000-0000-000000000001', 'a@test.sameway', '+994500000001'),
  ('b0000000-0000-0000-0000-000000000002', 'b@test.sameway', '+994500000002'),
  ('c0000000-0000-0000-0000-000000000003', 'c@test.sameway', '+994500000003');

-- handle_new_user() already created these rows; align the display fields
insert into public.users (id, phone, full_name) values
  ('a0000000-0000-0000-0000-000000000001', '+994500000001', 'Test Rider A'),
  ('b0000000-0000-0000-0000-000000000002', '+994500000002', 'Test Driver B'),
  ('c0000000-0000-0000-0000-000000000003', '+994500000003', 'Test Bystander C')
on conflict (id) do update set phone = excluded.phone, full_name = excluded.full_name;

-- handle_new_user() already created these rows too; set the document url
insert into public.user_verifications (user_id, id_document_url) values
  ('a0000000-0000-0000-0000-000000000001', 'a0000000.../id.jpg'),
  ('b0000000-0000-0000-0000-000000000002', 'b0000000.../id.jpg')
on conflict (user_id) do update set id_document_url = excluded.id_document_url;

-- required by follows_insert's policy, which checks a driver_profiles
-- row exists for the followed driver_id
insert into public.driver_profiles (user_id, rating_avg, rating_count, ride_count, follower_count)
values ('b0000000-0000-0000-0000-000000000002', 4.9, 12, 12, 0);

insert into public.vehicles (id, driver_id, make, model, color, year, plate_number, seats)
values ('d0000000-0000-0000-0000-0000000000d1', 'b0000000-0000-0000-0000-000000000002',
        'Toyota', 'Prius', 'Silver', 2019, 'TEST-001', 4);

insert into public.rides (
  id, driver_id, vehicle_id, from_address, from_lat, from_lng,
  to_address, to_lat, to_lng, departure_at, seats_total, seats_available,
  price_per_seat, status
) values (
  'e0000000-0000-0000-0000-0000000000e1', 'b0000000-0000-0000-0000-000000000002',
  'd0000000-0000-0000-0000-0000000000d1', 'Baku', 40.40, 49.86,
  'Ganja', 40.68, 46.36, now() + interval '1 day', 3, 3, 15, 'published'
);

insert into public.bookings (
  id, ride_id, lead_passenger_id, seat_count, total_price,
  payment_method, payment_status, status, expires_at
) values (
  'f0000000-0000-0000-0000-0000000000b1', 'e0000000-0000-0000-0000-0000000000e1',
  'a0000000-0000-0000-0000-000000000001', 1, 15, 'cash', 'unpaid', 'confirmed',
  now() + interval '1 hour'
);

insert into public.transactions (
  id, booking_id, payer_id, driver_id, type,
  amount_total, amount_driver, amount_platform, status
) values (
  '10000000-0000-0000-0000-0000000000a1', 'f0000000-0000-0000-0000-0000000000b1',
  'a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000002',
  'charge', 15, 13.5, 1.5, 'settled'
);

insert into public.conversations (id, ride_id, booking_id, type)
values ('20000000-0000-0000-0000-0000000000c1', 'e0000000-0000-0000-0000-0000000000e1',
        'f0000000-0000-0000-0000-0000000000b1', 'booking');

insert into public.conversation_participants (conversation_id, user_id) values
  ('20000000-0000-0000-0000-0000000000c1', 'a0000000-0000-0000-0000-000000000001'),
  ('20000000-0000-0000-0000-0000000000c1', 'b0000000-0000-0000-0000-000000000002');

insert into public.messages (id, conversation_id, sender_id, body) values
  ('30000000-0000-0000-0000-0000000000b2', '20000000-0000-0000-0000-0000000000c1',
   'a0000000-0000-0000-0000-000000000001', 'hi, where do I meet you?');

insert into public.reports (id, reporter_id, reported_user_id, reason, description)
values ('40000000-0000-0000-0000-0000000000f2', 'a0000000-0000-0000-0000-000000000001',
        'b0000000-0000-0000-0000-000000000002', 'other', 'test report');

-- the settled transaction above may have trigger-created this row already
insert into public.driver_balances (driver_id, pending, available, lifetime_earned)
values ('b0000000-0000-0000-0000-000000000002', 13.5, 0, 0)
on conflict (driver_id) do update
  set pending = excluded.pending, available = excluded.available,
      lifetime_earned = excluded.lifetime_earned;

-- helper: switch session identity
create or replace function pg_temp.as_user(p_user uuid) returns void as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  set local role authenticated;
end $$ language plpgsql;

-- ------------------------------------------------------------
-- 1 · USERS — owner-only base table
-- ------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-000000000001');
select is((select count(*) from public.users where id = 'a0000000-0000-0000-0000-000000000001')::int, 1,
  'A can read own users row');
select is((select count(*) from public.users where id = 'b0000000-0000-0000-0000-000000000002')::int, 0,
  'A CANNOT read B''s users row directly');
select is((select count(*) from public.public_profiles where id = 'b0000000-0000-0000-0000-000000000002')::int, 1,
  'A CAN read B''s safe columns via public_profiles');
select is((select count(*) from information_schema.columns
           where table_schema = 'public' and table_name = 'public_profiles'
             and column_name = 'phone')::int, 0,
  'public_profiles never exposes phone (column not selected in the view)');

-- ------------------------------------------------------------
-- 2 · USER_VERIFICATIONS — private, no cross-user read
-- ------------------------------------------------------------
select is((select count(*) from public.user_verifications
           where user_id = 'a0000000-0000-0000-0000-000000000001')::int, 1,
  'A can read own verification row');
select is((select count(*) from public.user_verifications
           where user_id = 'b0000000-0000-0000-0000-000000000002')::int, 0,
  'A CANNOT read B''s verification row (id_document_url must stay private)');

-- ------------------------------------------------------------
-- 3 · BOOKINGS — direct table writes must be denied (RPC-only per design)
-- ------------------------------------------------------------
select throws_ok(
  $$ insert into public.bookings (ride_id, lead_passenger_id, seat_count, total_price, payment_method, expires_at)
     values ('e0000000-0000-0000-0000-0000000000e1', 'a0000000-0000-0000-0000-000000000001', 1, 15, 'cash', now()) $$,
  null, null,
  'Direct INSERT into bookings is denied — must go through create_booking() RPC'
);
select is((select count(*) from public.bookings where id = 'f0000000-0000-0000-0000-0000000000b1')::int, 1,
  'A (lead passenger) can read own booking');

select pg_temp.as_user('c0000000-0000-0000-0000-000000000003');
select is((select count(*) from public.bookings where id = 'f0000000-0000-0000-0000-0000000000b1')::int, 0,
  'Bystander C CANNOT read A''s booking');

-- ------------------------------------------------------------
-- 4 · TRANSACTIONS — money table, client-read-only, scoped to parties
-- ------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-000000000001');
select is((select count(*) from public.transactions where payer_id = 'a0000000-0000-0000-0000-000000000001')::int, 1,
  'Payer A can read own transaction');
select pg_temp.as_user('c0000000-0000-0000-0000-000000000003');
select is((select count(*) from public.transactions)::int, 0,
  'Bystander C sees zero transactions they are not party to');
select throws_ok(
  $$ update public.transactions set status = 'reversed' where id = '10000000-0000-0000-0000-0000000000a1' $$,
  null, null,
  'Clients (any role) cannot write to transactions — service-role only'
);

-- ------------------------------------------------------------
-- 5 · DRIVER_BALANCES / PAYOUTS — owner-read-only, no client writes
-- ------------------------------------------------------------
select pg_temp.as_user('b0000000-0000-0000-0000-000000000002');
select is((select count(*) from public.driver_balances where driver_id = 'b0000000-0000-0000-0000-000000000002')::int, 1,
  'Driver B can read own balance');
select pg_temp.as_user('a0000000-0000-0000-0000-000000000001');
select is((select count(*) from public.driver_balances where driver_id = 'b0000000-0000-0000-0000-000000000002')::int, 0,
  'Rider A CANNOT read driver B''s balance');
select throws_ok(
  $$ update public.driver_balances set available = 9999 where driver_id = 'b0000000-0000-0000-0000-000000000002' $$,
  null, null,
  'Clients cannot write driver_balances — service-role/trigger only'
);

-- ------------------------------------------------------------
-- 6 · MESSAGING — participant-scoped
-- ------------------------------------------------------------
select pg_temp.as_user('b0000000-0000-0000-0000-000000000002');
select is((select count(*) from public.messages where conversation_id = '20000000-0000-0000-0000-0000000000c1')::int, 1,
  'Participant B can read the conversation''s messages');
select pg_temp.as_user('c0000000-0000-0000-0000-000000000003');
select is((select count(*) from public.messages where conversation_id = '20000000-0000-0000-0000-0000000000c1')::int, 0,
  'Non-participant C CANNOT read the conversation''s messages');
select is((select count(*) from public.conversation_participants
           where conversation_id = '20000000-0000-0000-0000-0000000000c1')::int, 0,
  'Non-participant C cannot even see who is in the conversation');

-- ------------------------------------------------------------
-- 7 · REPORTS — reporter sees own; reported party does NOT see the report
-- ------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-000000000001');
select is((select count(*) from public.reports where reporter_id = 'a0000000-0000-0000-0000-000000000001')::int, 1,
  'Reporter A can read own report');
select pg_temp.as_user('b0000000-0000-0000-0000-000000000002');
select is((select count(*) from public.reports where reported_user_id = 'b0000000-0000-0000-0000-000000000002')::int, 0,
  'Reported party B CANNOT see the report filed against them (ops-only visibility)');

-- ------------------------------------------------------------
-- 8 · FOLLOWS / BLOCKS — self-scoped lists
-- ------------------------------------------------------------
select pg_temp.as_user('a0000000-0000-0000-0000-000000000001');
select lives_ok(
  $$ insert into public.follows (follower_id, driver_id) values
     ('a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000002') $$,
  'A can follow B (own follower_id)'
);
select throws_ok(
  $$ insert into public.follows (follower_id, driver_id) values
     ('c0000000-0000-0000-0000-000000000003', 'b0000000-0000-0000-0000-000000000002') $$,
  null, null,
  'A CANNOT create a follow row on behalf of C (with-check blocks spoofing follower_id)'
);
select lives_ok(
  $$ insert into public.blocks (blocker_id, blocked_id) values
     ('a0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000003') $$,
  'A can block C (own blocker_id)'
);

-- ------------------------------------------------------------
-- 9 · ANONYMOUS — no session at all
-- ------------------------------------------------------------
reset role;
select set_config('request.jwt.claims', '', true);
set local role anon;
select is((select count(*) from public.users)::int, 0, 'Anonymous cannot read users table');
select is((select count(*) from public.bookings)::int, 0, 'Anonymous cannot read bookings');
select is((select count(*) from public.transactions)::int, 0, 'Anonymous cannot read transactions');
select is((select count(*) from public.public_profiles)::int > 0, true,
  'Anonymous CAN read public_profiles (intentionally public for browsing)');

-- ------------------------------------------------------------
-- 10 · COLUMN-LOCK SPOT CHECK — clients cannot tamper with counters
-- ------------------------------------------------------------
reset role;
select pg_temp.as_user('b0000000-0000-0000-0000-000000000002');
select throws_ok(
  $$ update public.driver_profiles set rating_avg = 5.0, ride_count = 999
     where user_id = 'b0000000-0000-0000-0000-000000000002' $$,
  null, null,
  'Driver B cannot self-edit denormalized rating_avg/ride_count (trigger-owned columns)'
);

select * from finish();
rollback;
