// supabase/functions/send-push/index.ts
//
// Admin-only: sends a Web Push notification to every member's devices, or to
// one team's devices. Called from the app with:
//
//   supabase.functions.invoke('send-push', {
//     body: { title: 'Rappel', body: 'Dîner à 19h', target_team_id: null, url: '/' }
//   })
//
// The function never uses a secret key: it calls the database with the
// caller's own token, and the SQL functions check that the caller is an
// active admin. Secrets needed: VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT.

import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

const VAPID_PUBLIC_KEY = Deno.env.get("VAPID_PUBLIC_KEY");
const VAPID_PRIVATE_KEY = Deno.env.get("VAPID_PRIVATE_KEY");
const VAPID_SUBJECT = Deno.env.get("VAPID_SUBJECT"); // e.g. "mailto:you@example.com"

if (VAPID_PUBLIC_KEY && VAPID_PRIVATE_KEY && VAPID_SUBJECT) {
  webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);
}

type Target = { endpoint: string; p256dh: string; auth: string };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  if (!VAPID_PUBLIC_KEY || !VAPID_PRIVATE_KEY || !VAPID_SUBJECT) {
    return json({ error: "VAPID secrets are not configured" }, 500);
  }

  const apikey = req.headers.get("apikey");
  const authorization = req.headers.get("Authorization");
  if (!apikey || !authorization) {
    return json({ error: "Missing apikey or Authorization header" }, 401);
  }

  let input: Record<string, unknown>;
  try {
    input = await req.json();
  } catch {
    return json({ error: "Body must be JSON" }, 400);
  }

  const title = String(input.title ?? "").trim();
  const body = String(input.body ?? "").trim();
  const targetTeamId = (input.target_team_id as string | null | undefined) ?? null;
  const url = typeof input.url === "string" && input.url.startsWith("/") ? input.url : "/";

  // Database calls run as the caller: RLS and the admin checks apply.
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, apikey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // The page is also logged, so that the members' notification list in the app leads where the push leads.
  const { data: prepared, error: prepError } = await supabase.rpc("prepare_push_notification", {
    p_title: title,
    p_body: body,
    p_target_team_id: targetTeamId,
    p_url: url,
  });
  if (prepError) {
    const status = prepError.code === "42501" ? 403 : 400;
    return json({ error: prepError.message }, status);
  }

  const notificationId: string = prepared.notification_id;
  const targets: Target[] = prepared.targets ?? [];
  const payload = JSON.stringify({ title, body, url, notification_id: notificationId });

  const results = await Promise.allSettled(
    targets.map((t) =>
      webpush.sendNotification(
        { endpoint: t.endpoint, keys: { p256dh: t.p256dh, auth: t.auth } },
        payload,
        { TTL: 12 * 60 * 60, urgency: "high" }, // keep for 12h if the phone is offline
      )
    ),
  );

  let sent = 0;
  const expired: string[] = [];
  const errors: string[] = [];
  results.forEach((r, i) => {
    if (r.status === "fulfilled") {
      sent++;
      return;
    }
    const statusCode = (r.reason as { statusCode?: number })?.statusCode;
    if (statusCode === 404 || statusCode === 410) {
      expired.push(targets[i].endpoint); // device unsubscribed or app removed
    } else {
      errors.push(`${statusCode ?? "network"}: ${String((r.reason as Error)?.message ?? r.reason).slice(0, 120)}`);
    }
  });
  const failed = targets.length - sent;

  if (expired.length > 0) {
    await supabase.rpc("remove_push_subscriptions", { p_endpoints: expired });
  }
  await supabase.rpc("record_push_result", {
    p_notification_id: notificationId,
    p_sent: sent,
    p_failed: failed,
  });

  return json({
    notification_id: notificationId,
    devices: targets.length,
    sent,
    failed,
    removed_expired: expired.length,
    errors: errors.slice(0, 5),
  });
});
