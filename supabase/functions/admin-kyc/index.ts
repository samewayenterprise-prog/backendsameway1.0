// admin-kyc — the manual-review tool for launch-phase KYC (decision:
// manual admin review now, automated vendor later). Protected by a
// shared secret header; deploy with --no-verify-jwt since callers are
// admins with the secret, not app users.
//
//   POST /admin-kyc
//   headers: x-admin-secret: <ADMIN_SECRET>
//   body: { "user_id": "...", "id_verified": true, "selfie_verified": true }
//
// Passing false clears a timestamp (re-review); omitting a field leaves
// it untouched. The documents themselves live in the private `documents`
// bucket — review them in the dashboard's storage browser, then call
// this to flip the flags the app reads on screen O-54.
import { serviceClient } from "../_shared/service.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("POST only", { status: 405 });
  }
  const secret = Deno.env.get("ADMIN_SECRET");
  if (!secret || req.headers.get("x-admin-secret") !== secret) {
    return new Response("forbidden", { status: 403 });
  }

  let body: { user_id?: string; id_verified?: boolean; selfie_verified?: boolean };
  try {
    body = await req.json();
  } catch {
    return new Response("invalid json", { status: 400 });
  }
  if (!body.user_id) return new Response("user_id required", { status: 400 });

  const patch: Record<string, string | null> = {};
  const now = new Date().toISOString();
  if (body.id_verified !== undefined) {
    patch.id_verified_at = body.id_verified ? now : null;
  }
  if (body.selfie_verified !== undefined) {
    patch.selfie_verified_at = body.selfie_verified ? now : null;
  }
  if (Object.keys(patch).length === 0) {
    return new Response("nothing to update", { status: 400 });
  }

  const db = serviceClient();
  const { data, error } = await db
    .from("user_verifications")
    .update(patch)
    .eq("user_id", body.user_id)
    .select()
    .maybeSingle();

  if (error) return new Response(error.message, { status: 500 });
  if (!data) return new Response("user_verifications row not found", { status: 404 });

  return new Response(JSON.stringify(data), {
    headers: { "content-type": "application/json" },
  });
});
