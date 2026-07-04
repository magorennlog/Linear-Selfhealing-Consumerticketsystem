// Selfdeveloping System — Supabase Edge Function für den Reporter-E-Mail-Versand.
//
// Der supabase.sh-Adapter POSTet nach einem Deploy an SDS_SUPABASE_NOTIFY_WEBHOOK:
//   { "email": "...", "name": "...", "ticket_id": 42, "project": "shop", "text": "<Nachricht>" }
// Diese Function verschickt daraus eine E-Mail via Resend (resend.com — 100 Mails/Tag frei).
//
// Deployen:
//   supabase functions new sds-notify
//   # diese Datei nach supabase/functions/sds-notify/index.ts kopieren
//   supabase secrets set RESEND_API_KEY=re_xxxx SDS_NOTIFY_SECRET=<langes-zufalls-secret> \
//                        MAIL_FROM="Support <noreply@deine-domain.de>"
//   supabase functions deploy sds-notify --no-verify-jwt
//
// Dann in .sds-env:
//   SDS_SUPABASE_NOTIFY_WEBHOOK=https://<projekt>.supabase.co/functions/v1/sds-notify
//   SDS_SUPABASE_NOTIFY_SECRET=<dasselbe-secret>
//
// Das Shared Secret verhindert, dass Fremde die öffentliche Function-URL als
// Spam-Kanone benutzen — Requests ohne gültigen x-sds-secret-Header werden verworfen.

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });

  const secret = Deno.env.get("SDS_NOTIFY_SECRET") ?? "";
  if (!secret || req.headers.get("x-sds-secret") !== secret) {
    return new Response("forbidden", { status: 403 });
  }

  let p: { email?: string; name?: string; ticket_id?: number; project?: string; text?: string };
  try { p = await req.json(); } catch { return new Response("bad json", { status: 400 }); }

  if (!p.email || !p.text) {
    // Kein Reporter-Kontakt hinterlegt → nichts zu tun (Kommentar hat der Adapter gesetzt).
    return Response.json({ ok: true, skipped: "no email" });
  }

  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${Deno.env.get("RESEND_API_KEY")}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: Deno.env.get("MAIL_FROM") ?? "onboarding@resend.dev",
      to: [p.email],
      subject: `Deine Meldung #${p.ticket_id ?? "?"} (${p.project ?? ""}) ist umgesetzt 🎉`,
      text: p.text,
    }),
  });

  if (!res.ok) {
    console.error("resend error:", res.status, await res.text());
    return new Response("mail send failed", { status: 502 });
  }
  return Response.json({ ok: true });
});
