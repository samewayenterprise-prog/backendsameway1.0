// Service-role client for Edge Functions. SUPABASE_URL and
// SUPABASE_SERVICE_ROLE_KEY are injected automatically on Supabase's
// runtime — never expose this client's key to anything client-side.
import { createClient } from "npm:@supabase/supabase-js@2";

export function serviceClient() {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) throw new Error("missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY");
  return createClient(url, key, { auth: { persistSession: false } });
}
