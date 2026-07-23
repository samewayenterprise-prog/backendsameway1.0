-- ============================================================
-- 012 · PERFORMANCE & OPERATIONS
--   A. RLS: wrap auth.uid() so it evaluates once per query, not per row
--   B. Indexes on RLS predicate columns
--   C. Follower fan-out moved out of the triggering transaction
--   D. Cron run monitoring (Supabase provides none)
--   E. Liquidity thresholds that gate turning the fee on
-- ============================================================

-- ------------------------------------------------------------
-- A · RLS performance
-- A bare auth.uid() in a policy is re-evaluated for EVERY ROW the
-- query touches. Wrapped as (select auth.uid()) Postgres hoists it
-- into an InitPlan and evaluates it once. On tables that will grow
-- (rides, bookings, messages, notifications) this is the difference
-- between a couple of milliseconds and multi-second queries — the
-- single most common Supabase performance mistake.
--
-- All 42 policies that reference auth.uid() are rewritten below. The
-- predicates are otherwise byte-identical to migration 003; only the
-- call is wrapped. Generated mechanically and diff-checked rather
-- than retyped, so the security semantics cannot drift.
-- ------------------------------------------------------------

drop policy if exists users_select_own on public.users;
create policy users_select_own on public.users
  for select using (id = (select auth.uid()));

drop policy if exists users_update_own on public.users;
create policy users_update_own on public.users
  for update using (id = (select auth.uid())) with check (id = (select auth.uid()));

drop policy if exists uv_select_own on public.user_verifications;
create policy uv_select_own on public.user_verifications
  for select using (user_id = (select auth.uid()));

drop policy if exists prefs_own on public.user_preferences;
create policy prefs_own on public.user_preferences
  for all using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

drop policy if exists dp_insert_own on public.driver_profiles;
create policy dp_insert_own on public.driver_profiles
  for insert with check (user_id = (select auth.uid()));

drop policy if exists dp_update_own on public.driver_profiles;
create policy dp_update_own on public.driver_profiles
  for update using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

drop policy if exists veh_select on public.vehicles;
create policy veh_select on public.vehicles
  for select using (is_active or driver_id = (select auth.uid()));

drop policy if exists veh_cud on public.vehicles;
create policy veh_cud on public.vehicles
  for all using (driver_id = (select auth.uid())) with check (driver_id = (select auth.uid()));

drop policy if exists routes_select on public.routes;
create policy routes_select on public.routes
  for select using (is_active or driver_id = (select auth.uid()));

drop policy if exists routes_cud on public.routes;
create policy routes_cud on public.routes
  for all using (driver_id = (select auth.uid())) with check (driver_id = (select auth.uid()));

drop policy if exists rstops_select on public.route_stops;
create policy rstops_select on public.route_stops
  for select using (exists (select 1 from public.routes r
                            where r.id = route_id
                              and (r.is_active or r.driver_id = (select auth.uid()))));

drop policy if exists rstops_cud on public.route_stops;
create policy rstops_cud on public.route_stops
  for all
  using (exists (select 1 from public.routes r
                 where r.id = route_id and r.driver_id = (select auth.uid())))
  with check (exists (select 1 from public.routes r
                      where r.id = route_id and r.driver_id = (select auth.uid())));

drop policy if exists rides_select on public.rides;
create policy rides_select on public.rides
  for select using (status in ('published','full') or driver_id = (select auth.uid()));

drop policy if exists rides_insert_own on public.rides;
create policy rides_insert_own on public.rides
  for insert with check (
    driver_id = (select auth.uid())
    and exists (select 1 from public.vehicles v
                where v.id = vehicle_id and v.driver_id = (select auth.uid()) and v.is_active)
  );

drop policy if exists rides_update_own on public.rides;
create policy rides_update_own on public.rides
  for update using (driver_id = (select auth.uid())) with check (driver_id = (select auth.uid()));

drop policy if exists rides_delete_own on public.rides;
create policy rides_delete_own on public.rides
  for delete using (driver_id = (select auth.uid()) and status = 'published');

drop policy if exists ridestops_select on public.ride_stops;
create policy ridestops_select on public.ride_stops
  for select using (exists (select 1 from public.rides r
                            where r.id = ride_id
                              and (r.status in ('published','full')
                                   or r.driver_id = (select auth.uid()))));

drop policy if exists bp_update_self on public.booking_passengers;
create policy bp_update_self on public.booking_passengers
  for update using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()) and status in ('confirmed','declined'));

drop policy if exists invites_select_creator on public.booking_invites;
create policy invites_select_creator on public.booking_invites
  for select using (created_by = (select auth.uid()));

drop policy if exists parcels_select on public.parcels;
create policy parcels_select on public.parcels
  for select using (
    sender_id = (select auth.uid()) or public.is_ride_driver(ride_id)
  );

drop policy if exists ptxn_select_own on public.point_transactions;
create policy ptxn_select_own on public.point_transactions
  for select using (user_id = (select auth.uid()));

drop policy if exists rider_streaks_select_own on public.rider_streaks;
create policy rider_streaks_select_own on public.rider_streaks
  for select using (user_id = (select auth.uid()));

drop policy if exists follows_select on public.follows;
create policy follows_select on public.follows
  for select using (follower_id = (select auth.uid()) or driver_id = (select auth.uid()));

drop policy if exists follows_insert on public.follows;
create policy follows_insert on public.follows
  for insert with check (
    follower_id = (select auth.uid())
    and exists (select 1 from public.driver_profiles dp where dp.user_id = driver_id)
    and not exists (select 1 from public.blocks b
                    where b.blocker_id = driver_id and b.blocked_id = (select auth.uid()))
  );

drop policy if exists follows_delete on public.follows;
create policy follows_delete on public.follows
  for delete using (follower_id = (select auth.uid()));

drop policy if exists reviews_insert on public.reviews;
create policy reviews_insert on public.reviews
  for insert with check (
    reviewer_id = (select auth.uid())
    and reviewee_id <> (select auth.uid())
    and (
      (booking_id is not null
        and public.is_booking_member(booking_id)
        and exists (select 1 from public.bookings b
                    where b.id = booking_id and b.status = 'completed'))
      or
      (parcel_id is not null
        and exists (select 1 from public.parcels p
                    where p.id = parcel_id and p.status = 'delivered'
                      and (p.sender_id = (select auth.uid()) or public.is_ride_driver(p.ride_id))))
    )
  );

drop policy if exists cp_update_own on public.conversation_participants;
create policy cp_update_own on public.conversation_participants
  for update using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

drop policy if exists msg_insert on public.messages;
create policy msg_insert on public.messages
  for insert with check (
    sender_id = (select auth.uid())
    and is_system = false
    and public.is_conversation_member(conversation_id)
  );

drop policy if exists pm_select_own on public.payment_methods;
create policy pm_select_own on public.payment_methods
  for select using (user_id = (select auth.uid()));

drop policy if exists pm_delete_own on public.payment_methods;
create policy pm_delete_own on public.payment_methods
  for delete using (user_id = (select auth.uid()));

drop policy if exists txn_select_own on public.transactions;
create policy txn_select_own on public.transactions
  for select using (payer_id = (select auth.uid()) or driver_id = (select auth.uid()));

drop policy if exists payouts_select_own on public.payouts;
create policy payouts_select_own on public.payouts
  for select using (driver_id = (select auth.uid()));

drop policy if exists balances_select_own on public.driver_balances;
create policy balances_select_own on public.driver_balances
  for select using (driver_id = (select auth.uid()));

drop policy if exists notif_select_own on public.notifications;
create policy notif_select_own on public.notifications
  for select using (user_id = (select auth.uid()));

drop policy if exists notif_update_own on public.notifications;
create policy notif_update_own on public.notifications
  for update using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

drop policy if exists notif_delete_own on public.notifications;
create policy notif_delete_own on public.notifications
  for delete using (user_id = (select auth.uid()));

drop policy if exists dt_own on public.device_tokens;
create policy dt_own on public.device_tokens
  for all using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

drop policy if exists reports_insert on public.reports;
create policy reports_insert on public.reports
  for insert with check (reporter_id = (select auth.uid()));

drop policy if exists reports_select_own on public.reports;
create policy reports_select_own on public.reports
  for select using (reporter_id = (select auth.uid()));

drop policy if exists blocks_own on public.blocks;
create policy blocks_own on public.blocks
  for all using (blocker_id = (select auth.uid())) with check (blocker_id = (select auth.uid()));

drop policy if exists avatars_write_own on storage.objects;
create policy avatars_write_own on storage.objects
  for insert with check (
    bucket_id in ('avatars','vehicles')
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists docs_write_own on storage.objects;
create policy docs_write_own on storage.objects
  for insert with check (
    bucket_id = 'documents'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

-- ------------------------------------------------------------
-- B · indexes for RLS predicates and hot lookups
-- A policy predicate is only as fast as the index behind it.
-- ------------------------------------------------------------
create index if not exists bookings_lead_passenger_idx on public.bookings(lead_passenger_id);
create index if not exists bookings_ride_status_idx    on public.bookings(ride_id, status);
create index if not exists bp_user_idx                 on public.booking_passengers(user_id);
create index if not exists bp_booking_status_idx       on public.booking_passengers(booking_id, status);
create index if not exists cp_user_idx                 on public.conversation_participants(user_id);
create index if not exists messages_conv_created_idx   on public.messages(conversation_id, created_at desc);
create index if not exists notif_user_created_idx      on public.notifications(user_id, created_at desc);
create index if not exists txn_payer_idx               on public.transactions(payer_id);
create index if not exists txn_driver_idx              on public.transactions(driver_id);
create index if not exists reports_reporter_idx        on public.reports(reporter_id);
create index if not exists follows_driver_idx          on public.follows(driver_id);
create index if not exists parcels_sender_idx          on public.parcels(sender_id);
create index if not exists parcels_ride_status_idx     on public.parcels(ride_id, status);
create index if not exists rides_driver_departure_idx  on public.rides(driver_id, departure_at desc);
create index if not exists vehicles_driver_idx         on public.vehicles(driver_id);
create index if not exists routes_driver_idx           on public.routes(driver_id);

-- ------------------------------------------------------------
-- C · asynchronous follower fan-out
-- The old trigger inserted one notification row per follower INSIDE
-- the transaction that published the ride. A driver with 5,000
-- followers meant 5,000 inserts before the publish could commit —
-- the publish gets slower the more successful the driver becomes,
-- which is exactly backwards.
--
-- Now the trigger enqueues a single job row and returns immediately.
-- A worker expands it into notifications outside the publish path.
-- ------------------------------------------------------------
create table if not exists public.notification_jobs (
  id           bigserial primary key,
  kind         text not null,
  payload      jsonb not null,
  created_at   timestamptz not null default now(),
  processed_at timestamptz,
  attempts     int not null default 0,
  last_error   text
);

create index if not exists notif_jobs_pending_idx
  on public.notification_jobs(created_at) where processed_at is null;

alter table public.notification_jobs enable row level security;
-- no policies: service role only, clients have no business here
revoke all on public.notification_jobs from anon, authenticated;

create or replace function public.trg_ride_fanout()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into notification_jobs (kind, payload)
  values ('followed_driver_posted',
          jsonb_build_object('ride_id', new.id, 'driver_id', new.driver_id,
                             'from', new.from_address, 'to', new.to_address,
                             'departure_at', new.departure_at));
  return new;
end $$;

-- Worker: expands queued jobs into per-follower notification rows.
-- Batched so one enormous follower list cannot monopolise a run.
create or replace function public.process_notification_jobs(p_limit int default 50)
returns int
language plpgsql security definer set search_path = public as $$
declare v_job record; v_done int := 0;
begin
  for v_job in
    select * from notification_jobs
    where processed_at is null and attempts < 5
    order by created_at
    limit p_limit
    for update skip locked
  loop
    begin
      insert into notifications (user_id, type, data)
      select f.follower_id, v_job.kind, v_job.payload
      from follows f
      where f.driver_id = (v_job.payload->>'driver_id')::uuid;

      update notification_jobs set processed_at = now() where id = v_job.id;
      v_done := v_done + 1;
    exception when others then
      update notification_jobs
         set attempts = attempts + 1, last_error = sqlerrm
       where id = v_job.id;
    end;
  end loop;
  return v_done;
end $$;

revoke execute on function public.process_notification_jobs(int) from public, anon, authenticated;

select cron.schedule('process-notification-jobs', '* * * * *',
                     $$select public.process_notification_jobs()$$);

-- ------------------------------------------------------------
-- D · cron run monitoring
-- pg_cron does not retry, silently skips a run if the previous one
-- still holds its lock, and raises no alert on failure. Without a
-- record of runs, the nightly ride generator could stop producing
-- rides and the first symptom would be an empty search screen.
-- ------------------------------------------------------------
create table if not exists public.job_runs (
  id          bigserial primary key,
  job_name    text not null,
  started_at  timestamptz not null default now(),
  finished_at timestamptz,
  ok          boolean,
  result      text,
  error       text
);

create index if not exists job_runs_name_started_idx
  on public.job_runs(job_name, started_at desc);

alter table public.job_runs enable row level security;
revoke all on public.job_runs from anon, authenticated;

-- Wrapper so any scheduled statement gets logged with timing + outcome.
create or replace function public.run_job(p_name text, p_sql text)
returns void
language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_res text;
begin
  insert into job_runs (job_name) values (p_name) returning id into v_id;
  begin
    execute p_sql into v_res;
    update job_runs set finished_at = now(), ok = true, result = v_res where id = v_id;
  exception when others then
    update job_runs set finished_at = now(), ok = false, error = sqlerrm where id = v_id;
    raise;
  end;
end $$;

revoke execute on function public.run_job(text, text) from public, anon, authenticated;

-- Re-point the existing schedules through the wrapper.
select cron.unschedule('generate-recurring-rides');
select cron.schedule('generate-recurring-rides', '0 3 * * *',
  $$select public.run_job('generate-recurring-rides',
                          'select public.generate_recurring_rides()::text')$$);

select cron.unschedule('batch-driver-payouts');
select cron.schedule('batch-driver-payouts', '0 4 * * 1',
  $$select public.run_job('batch-driver-payouts',
                          'select public.batch_driver_payouts()::text')$$);

-- Health view for the admin panel: last run per job and how stale it is.
create or replace view public.job_health as
select j.jobname                as job_name,
       j.schedule,
       j.active,
       r.started_at             as last_run_at,
       r.ok                     as last_run_ok,
       r.error                  as last_error,
       now() - r.started_at     as since_last_run
from cron.job j
left join lateral (
  select * from job_runs jr
  where jr.job_name = j.jobname
  order by started_at desc limit 1
) r on true;

-- ------------------------------------------------------------
-- E · liquidity gate for fee activation
-- Turning the platform fee on is a liquidity decision, not a calendar
-- decision. Charging before a corridor reliably fills seats suppresses
-- the very supply you are trying to build. These thresholds make the
-- condition explicit and measurable so the call is made on evidence.
-- ------------------------------------------------------------
alter table public.platform_settings
  add column if not exists fee_gate_min_daily_rides int not null default 20,
  add column if not exists fee_gate_min_fill_rate   numeric(4,2) not null default 0.60;

comment on column public.platform_settings.fee_gate_min_fill_rate is
  'Share of offered seats actually booked. Below this the marketplace is not liquid enough to absorb a fee.';

create or replace function public.corridor_liquidity(p_days int default 7)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_rides int; v_seats int; v_booked int;
  v_daily numeric; v_fill numeric;
  v_min_daily int; v_min_fill numeric;
begin
  select count(*), coalesce(sum(seats_total),0),
         coalesce(sum(seats_total - seats_available),0)
    into v_rides, v_seats, v_booked
    from rides
   where departure_at between now() - (p_days || ' days')::interval and now();

  v_daily := round(v_rides::numeric / greatest(p_days,1), 2);
  v_fill  := case when v_seats > 0
                  then round(v_booked::numeric / v_seats, 3) else 0 end;

  select fee_gate_min_daily_rides, fee_gate_min_fill_rate
    into v_min_daily, v_min_fill from platform_settings where id = 1;

  return jsonb_build_object(
    'window_days',      p_days,
    'rides',            v_rides,
    'rides_per_day',    v_daily,
    'seats_offered',    v_seats,
    'seats_booked',     v_booked,
    'fill_rate',        v_fill,
    'min_daily_rides',  v_min_daily,
    'min_fill_rate',    v_min_fill,
    'ready_for_fees',   (v_daily >= v_min_daily and v_fill >= v_min_fill)
  );
end $$;
