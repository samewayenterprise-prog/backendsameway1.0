-- ============================================================
-- 014 · FIX: price-ceiling trigger broke ALL route & ride inserts
--
-- trg_enforce_price_ceiling() (010) read the seat count with
--   case when tg_table_name = 'routes' then new.max_seats
--        else new.seats_total end
-- PL/pgSQL resolves every record field in an expression when the
-- expression is planned, not lazily per CASE branch — so on rides
-- (no max_seats) the trigger raised `record "new" has no field
-- "max_seats"` before the CASE ever ran, and on routes it failed
-- symmetrically on seats_total. Net effect: every insert into
-- either table errored; both tables have been un-writable since
-- 010 applied.
--
-- Fix: read the one divergent column through to_jsonb(new), which
-- never triggers field validation — a missing key is just null.
-- from_lat/from_lng/to_lat/to_lng/price_per_seat exist on BOTH
-- tables under the same names, so direct NEW access stays for those.
-- ============================================================

create or replace function public.trg_enforce_price_ceiling()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_seats int;
  v_distance numeric;
  v_ceiling numeric;
  v_row jsonb := to_jsonb(new);
begin
  -- routes carry max_seats, rides carry seats_total; exactly one is present
  v_seats := coalesce(
    (v_row->>'max_seats')::int,
    (v_row->>'seats_total')::int,
    0
  );

  v_distance := haversine_km(new.from_lat, new.from_lng, new.to_lat, new.to_lng);
  v_ceiling  := cost_share_ceiling(v_distance, v_seats, 'AZ');

  if v_ceiling is not null and new.price_per_seat > v_ceiling then
    raise exception
      'price_above_cost_share_ceiling: % exceeds the maximum of % AZN per seat for a % km trip with % seats. SameWay is a cost-sharing platform — drivers share travel costs, they do not profit from rides.',
      new.price_per_seat, v_ceiling, v_distance, v_seats
      using errcode = 'check_violation';
  end if;

  return new;
end $$;
