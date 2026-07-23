-- Lock money tables against client writes at the privilege level.
--
-- transactions and driver_balances carry only SELECT policies (003_rls.sql):
-- clients read their own rows; all writes belong to the service role and
-- triggers. But RLS with no UPDATE/DELETE policy merely makes writes match
-- zero rows — the anon/authenticated roles still HOLD the table privileges
-- Supabase grants by default. That leaves no defense-in-depth: one future
-- permissive policy added by mistake would instantly open client writes to
-- money data. Revoking the privileges closes that gap, and makes attempted
-- writes fail loudly (privilege error) instead of silently no-oping —
-- which is also what the RLS test suite (000_rls.test.sql) asserts.

revoke insert, update, delete, truncate
  on public.transactions, public.driver_balances
  from anon, authenticated;
