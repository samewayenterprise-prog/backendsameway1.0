-- ============================================================
-- 006 · PAYOUTS
-- driver_balances existed since 001 but nothing ever wrote to it —
-- the settle→pending and pending→available→sent flow described in
-- the tech doc (§5) was designed but not implemented. This migration
-- closes that gap:
--   A. trg_credit_driver_balance — settled charges credit `pending`
--      (booking fees have amount_driver=0, so they correctly credit
--      nothing to the driver; parcel/seat charges credit the driver's
--      cut). Settled refunds with amount_driver>0 debit symmetrically.
--   B. batch_driver_payouts() — weekly job: sweeps pending → available
--      is skipped as a separate step (see comment) — moves pending
--      straight into a payout row, resets pending to 0, bumps
--      lifetime_earned. The payments-watcher Edge Function executes
--      the actual provider payout and flips payouts.status.
-- Additive-only, like 004/005.
-- ============================================================

-- ------------------------------------------------------------
-- A · credit/debit driver_balances from settled transactions
-- ------------------------------------------------------------
create or replace function public.trg_credit_driver_balance()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'settled' and old.status is distinct from 'settled' then
    if new.type = 'charge' and new.amount_driver > 0 then
      insert into driver_balances (driver_id, pending, available, lifetime_earned)
      values (new.driver_id, new.amount_driver, 0, 0)
      on conflict (driver_id) do update
        set pending = driver_balances.pending + excluded.pending;

    elsif new.type = 'refund' and new.amount_driver > 0 then
      -- Symmetric clawback. Take from pending first (money not yet
      -- paid out), then available if pending is insufficient. Floors
      -- at 0 rather than going negative — a shortfall here means a
      -- payout already went out before the refund landed, which is a
      -- reconciliation case for the daily balance-check job (see
      -- edge-functions.md), not something to silently invent money for.
      update driver_balances
      set pending   = greatest(0, pending - least(new.amount_driver, pending)),
          available = greatest(0, available - greatest(0, new.amount_driver - pending))
      where driver_id = new.driver_id;
    end if;
  end if;
  return new;
end $$;

create trigger transactions_credit_driver_balance
  after update on public.transactions
  for each row execute function public.trg_credit_driver_balance();

-- Also handle the (less common) case of a transaction inserted
-- pre-settled — e.g. the sandbox provider settles instantly, so
-- payments-watcher's insert already has status='settled' with no
-- preceding 'pending' row to transition from.
create or replace function public.trg_credit_driver_balance_on_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'settled' and new.type = 'charge' and new.amount_driver > 0 then
    insert into driver_balances (driver_id, pending, available, lifetime_earned)
    values (new.driver_id, new.amount_driver, 0, 0)
    on conflict (driver_id) do update
      set pending = driver_balances.pending + excluded.pending;
  end if;
  return new;
end $$;

create trigger transactions_credit_driver_balance_ins
  after insert on public.transactions
  for each row execute function public.trg_credit_driver_balance_on_insert();

-- ------------------------------------------------------------
-- B · weekly payout batch
-- Minimum threshold avoids issuing a payout for pocket change every
-- week — tune MIN_PAYOUT once real transaction volume exists.
-- ------------------------------------------------------------
create or replace function public.batch_driver_payouts(p_min_payout numeric default 5.00)
returns int
language plpgsql security definer set search_path = public as $$
declare
  v_bal driver_balances%rowtype;
  v_count int := 0;
begin
  for v_bal in
    select * from driver_balances where pending >= p_min_payout for update
  loop
    insert into payouts (driver_id, amount, currency, status)
    values (v_bal.driver_id, v_bal.pending, 'AZN', 'pending');

    update driver_balances
    set pending = 0,
        lifetime_earned = lifetime_earned + v_bal.pending
    where driver_id = v_bal.driver_id;

    v_count := v_count + 1;
  end loop;
  return v_count;
end $$;

revoke execute on function public.batch_driver_payouts(numeric) from public, anon, authenticated;

-- Weekly, Monday 04:00 UTC — after the nightly ride generator (03:00)
-- and well clear of booking-expiry (every minute), so it never runs
-- mid-way through a burst of settlements.
select cron.schedule(
  'batch-driver-payouts',
  '0 4 * * 1',
  $$select public.batch_driver_payouts()$$
);
