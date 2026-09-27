const allowedOrigins = new Set(['https://www.zodis.app', 'https://zodis.app', 'https://zodis-landing-git-codex-beta3-o-f88ddc-davids-projects-25f8617a.vercel.app']);
const headersFor = (req: Request) => {
  const requestOrigin = req.headers.get('origin');
  const responseOrigin = requestOrigin && allowedOrigins.has(requestOrigin)
    ? requestOrigin
    : 'https://www.zodis.app';
  return {
    'Access-Control-Allow-Origin': responseOrigin,
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'content-type',
    Vary: 'Origin',
    'Content-Type': 'application/json',
  };
};
const json = (req: Request, body: object, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: headersFor(req) });
const env = (key: string) => { const value = Deno.env.get(key); if (!value) throw new Error(`Missing ${key}`); return value; };
async function rpc(name: string, payload: object) {
  const key = JSON.parse(env('SUPABASE_SECRET_KEYS')).default;
  if (typeof key !== 'string' || !key) throw new Error('Missing default Supabase secret key');
  const res = await fetch(`${env('SUPABASE_URL')}/rest/v1/rpc/${name}`, {
    method: 'POST', headers: { apikey: key, 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  });
  const data = await res.json();
  if (!res.ok) throw new Error(`Database RPC ${name} failed: ${res.status}`);
  return data;
}

type Job = {
  request_id: number; email: string; note: string; source: string;
  status: 'admitted' | 'waitlisted'; tester_count: number;
  claim_id: string; attempts: number; decided_at: string;
};

function emailContent(status: Job['status']) {
  if (status === 'admitted') return {
    subject: "You're in the Žodis Beta",
    text: `Hi,\n\nYou're in the Žodis Beta. Open the app at https://learning-lithuanian.vercel.app and sign in with the same email address you used to request access.\n\nTo add it to your phone: https://www.zodis.app/setup/\nA quick guide: https://www.zodis.app/userguide/\n\nThis is a small beta, and I'd love to hear what works or feels confusing. Just reply to this email. I'm learning Lithuanian too, so honest feedback really helps.\n\nDavid`,
  };
  return {
    subject: 'Your Žodis Beta waitlist place',
    text: `Hi,\n\nThanks for asking to try Žodis. The current Beta is full, but I've recorded your place on the waitlist. I'll be in touch when a place opens up.\n\nI'm learning Lithuanian too and really appreciate your interest.\n\nDavid`,
  };
}


type TurnstileResult = {
  success: boolean;
  hostname?: string;
  action?: string;
  'error-codes'?: string[];
};

async function verifyTurnstile(token: string) {
  if (!token || token.length > 2048) return false;
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), 8000);
  try {
    const res = await fetch('https://challenges.cloudflare.com/turnstile/v0/siteverify', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        secret: env('TURNSTILE_SECRET_KEY'),
        response: token,
        idempotency_key: crypto.randomUUID(),
      }),
      signal: controller.signal,
    });
    const result = await res.json() as TurnstileResult;
    if (!res.ok) throw new Error(`Turnstile HTTP ${res.status}`);
    return result.success === true &&
      (result.hostname === 'zodis.app' || result.hostname === 'www.zodis.app' || result.hostname === 'zodis-landing-git-codex-beta3-o-f88ddc-davids-projects-25f8617a.vercel.app') &&
      result.action === 'beta-signup';
  } finally {
    clearTimeout(timeoutId);
  }
}

async function deliver(channel: 'email' | 'discord', requestId: number | null = null) {
  const data = await rpc('beta_claim_delivery', { p_channel: channel, p_request_id: requestId });
  const job = (data as Job[] | null)?.[0];
  if (!job) return false;
  let success = false, providerId: string | null = null, failure: string | null = null;
  try {
    if (channel === 'email') {
      // Resend retains idempotency keys for 24h. An unresolved older attempt
      // needs a human check before any replay that might duplicate delivery.
      if (job.attempts > 1 && Date.now() - Date.parse(job.decided_at) > 23 * 60 * 60 * 1000) {
        throw new Error('Ambiguous email attempt exceeds provider idempotency window; review manually');
      }
      const message = emailContent(job.status);
      const res = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${env('RESEND_API_KEY')}`,
          'Content-Type': 'application/json',
          'Idempotency-Key': `zodis-beta3-${job.request_id}-${job.status}`,
        },
        body: JSON.stringify({ from: 'David from Žodis <hello@zodis.app>',
          to: [job.email], reply_to: 'davidgordonlang@gmail.com', ...message }),
      });
      const result = await res.json();
      if (!res.ok || !result.id) throw new Error(`Resend HTTP ${res.status}: ${String(result.message || 'no message ID').slice(0,160)}`);
      providerId = result.id;
    } else {
      const content = `Žodis Beta signup · ${job.status}\nEmail: ${job.email}\nSource: ${job.source}\nHow found: ${job.note}\nExternal testers: ${job.tester_count}/100`;
      const res = await fetch(env('DISCORD_BETA_WEBHOOK_URL'), {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ content: content.slice(0,1900), allowed_mentions: { parse: [] } }),
      });
      if (!res.ok) throw new Error(`Discord HTTP ${res.status}`);
    }
    success = true;
  } catch (e) {
    failure = e instanceof Error ? e.message : 'delivery error';
    console.error(`${channel} delivery failed for request ${job.request_id}: ${failure}`);
  }
  const finish = await rpc('beta_finish_delivery', { p_id: job.request_id,
    p_channel: channel, p_claim: job.claim_id, p_success: success,
    p_provider_id: providerId, p_error: failure });
  if (!finish) throw new Error(`Could not record ${channel} delivery result`);
  return true;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: headersFor(req) });
  if (req.method !== 'POST') return json(req, { error: 'Method not allowed' }, 405);
  try {
    if (req.headers.get('x-worker-secret') === Deno.env.get('BETA_WORKER_SECRET') && Deno.env.get('BETA_WORKER_SECRET')) {
      for (let i = 0; i < 12; i++) {
        const [email, discord] = await Promise.all([deliver('email'), deliver('discord')]);
        if (!email && !discord) break;
      }
      return json(req, { ok: true });
    }
    const requestOrigin = req.headers.get('origin');
    if (!requestOrigin || !allowedOrigins.has(requestOrigin)) return json(req, { error: 'Forbidden' }, 403);
    if (Number(req.headers.get('content-length') || 0) > 2048) return json(req, { error: 'Invalid request' }, 413);
    const rawBody = await req.text();
    if (rawBody.length > 2048) return json(req, { error: 'Invalid request' }, 413);
    let input: Record<string, unknown>;
    try {
      input = JSON.parse(rawBody);
    } catch {
      return json(req, { error: 'Invalid request' }, 400);
    }
    if (input.website) return json(req, { outcome: 'received' }); // honeypot
    const email = String(input.email || '').trim().toLowerCase();
    const note = String(input.note || '').trim();
    const turnstileToken = String(input.turnstileToken || '');
    if (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || note.length < 1 || note.length > 500)
      return json(req, { error: 'Please enter a valid email and a short note.' }, 400);
    if (!await verifyTurnstile(turnstileToken))
      return json(req, { error: 'Please complete the security check and try again.' }, 403);
    const data = await rpc('beta_submit_request', {
      p_email: email, p_note: note, p_source: 'zodis.app',
    });
    const outcome = data?.[0]?.outcome || 'received';
    const requestId = data?.[0]?.request_id;
    // Delivery is synchronous for a useful immediate result. The durable worker
    // catches failed or interrupted requests; provider failure never loses admission.
    if (Number.isSafeInteger(requestId)) {
      await Promise.all([deliver('email', requestId), deliver('discord', requestId)]);
    }
    return json(req, { outcome });
  } catch (e) {
    console.error('beta signup error', e);
    return json(req, { error: 'Something went wrong. Please try again in a moment.' }, 500);
  }
});
