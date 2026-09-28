import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { parseReferral, referralLabels } from '../supabase/functions/beta-signup/referrals.mjs';

const labels = [
  ['reddit','Reddit'],['instagram','Instagram'],['facebook','Facebook'],['tiktok','TikTok'],
  ['google_search','Google / web search'],['friend_family','Friend or family'],
  ['language_community','Lithuanian or language-learning community'],
  ['previous_beta','Already knew about Žodis / previous beta'],['other','Other'],
];

test('all nine approved values produce stable, readable notes', () => {
  assert.deepEqual(Object.entries(referralLabels), labels);
  for (const [source, label] of labels)
    assert.deepEqual(parseReferral(source, null), { source, detail: null, note: label });
  assert.equal(parseReferral('random', null), null);
  assert.equal(parseReferral('', null), null);
  assert.equal(parseReferral('reddit', 'unrequested detail'), null);
});

test('Other detail is optional, trimmed and bounded without newlines in Discord note', () => {
  assert.deepEqual(parseReferral('other', '  Lithuanian\n Discord server  '),
    { source:'other', detail:'Lithuanian Discord server', note:'Other: Lithuanian Discord server' });
  assert.deepEqual(parseReferral('other', ' \n '), {source:'other', detail:null, note:'Other'});
  assert.equal(parseReferral('other', 'x'.repeat(200))?.detail.length, 200);
  assert.equal(parseReferral('other', 'x'.repeat(201)), null);
  assert.equal(parseReferral('other', { text:'private data' }), null);
});

test('form uses the approved options and the existing theme-aware form controls', () => {
  const html = readFileSync(new URL('../index.html', import.meta.url), 'utf8');
  const values = [...html.matchAll(/<option value="([^"]+)">([^<]+)<\/option>/g)].map(m=>[m[1],m[2]]);
  assert.deepEqual(values, labels);
  assert.match(html, /<select id="referralSource" name="referralSource" required>/);
  assert.match(html, /<option value="" disabled selected>Choose one…<\/option>/);
  assert.match(html, /<div class="field" id="otherField" hidden>/);
  assert.match(html, /maxlength="200" autocomplete="off" disabled/);
  assert.match(html, /\.field input,\.field textarea,\.field select\{/);
  assert.match(html, /\.field\[hidden\]\{display:none\}/);
  assert.doesNotMatch(html, /<textarea id="note"/);
  assert.match(html, /body:JSON.stringify\(\{email,note,referralSource,referralDetail:referralDetail\|\|null,website:form\.elements\.website\.value,turnstileToken\}\)/);
});

test('migration keeps technical source, cap, duplicate and allowlist logic, and service-only RPC grants', () => {
  const sql = readFileSync(new URL('../supabase/migrations/20260928220000_beta3_structured_referral.sql', import.meta.url), 'utf8');
  assert.match(sql, /add column referral_source text/);
  assert.match(sql, /add column referral_detail text/);
  assert.match(sql, /p_source is distinct from 'zodis\.app'/);
  assert.match(sql, /pg_catalog\.pg_advisory_xact_lock\(4522026, 100\)/);
  assert.match(sql, /if found then\s+return query select 'received'/);
  assert.match(sql, /v_count < 100/);
  assert.match(sql, /insert into public\.beta_allowlist\(email\)/);
  assert.match(sql, /davidgordonlang@gmail\.com','barbora\.gaulyte@gmail\.com/);
  assert.match(sql, /revoke all on function public\.beta_submit_request\(text,text,text,text,text\)\s+from public,anon,authenticated/);
  assert.match(sql, /grant execute on function public\.beta_submit_request\(text,text,text,text,text\)\s+to service_role/);
});

test('public Edge handler validates new and legacy payloads before secured RPC', async () => {
  let handler, calls=[];
  const previousDeno=globalThis.Deno, previousFetch=globalThis.fetch;
  globalThis.Deno={env:{get:key=>({
    BETA_WORKER_SECRET:'worker-secret', TURNSTILE_SECRET_KEY:'turnstile-secret',
    SUPABASE_SECRET_KEYS:JSON.stringify({default:'service-secret'}),
    SUPABASE_URL:'https://db.example.test'
  })[key]}, serve: fn=>{handler=fn}};
  globalThis.fetch=async (url,opts)=>{
    calls.push({url:String(url),opts});
    if(String(url).includes('siteverify')) return Response.json({success:true,hostname:'zodis.app',action:'beta-signup'});
    if(String(url).includes('/rpc/beta_submit_request')) return Response.json([{outcome:'received',request_id:null}]);
    throw Error('Unexpected network call: '+url);
  };
  try {
    await import('../supabase/functions/beta-signup/index.ts');
    const submit = async body => handler(new Request('https://db.example.test/functions/v1/beta-signup',
      {method:'POST',headers:{origin:'https://www.zodis.app'},body:JSON.stringify({
        email:'NEW@example.com',website:'',turnstileToken:'valid-token',...body,
      })}));
    for (const [source,label] of labels) {
      calls=[];
      const res=await submit({referralSource:source,referralDetail:null,note:'spoofed browser note'});
      assert.equal(res.status,200);
      const rpc=calls.find(c=>c.url.includes('/rpc/beta_submit_request'));
      assert.ok(rpc, source);
      const payload=JSON.parse(rpc.opts.body);
      assert.deepEqual(payload,{p_email:'new@example.com',p_note:label,p_source:'zodis.app',
        p_referral_source:source,p_referral_detail:null});
      assert.equal(calls.length,2, 'neutral duplicate outcome sends no email or Discord');
    }
    calls=[];
    await submit({referralSource:'other',referralDetail:'  language group  '});
    assert.deepEqual(JSON.parse(calls.at(-1).opts.body),{p_email:'new@example.com',
      p_note:'Other: language group',p_source:'zodis.app',
      p_referral_source:'other',p_referral_detail:'language group'});
    for (const bad of ['unknown','',null]) {
      calls=[];assert.equal((await submit({referralSource:bad})).status,400);assert.equal(calls.length,0);
    }
    calls=[];assert.equal((await submit({referralSource:'other',referralDetail:'x'.repeat(201)})).status,400);
    assert.equal(calls.length,0);
    calls=[];assert.equal((await submit({note:'Old free-text note'})).status,200);
    assert.deepEqual(JSON.parse(calls.at(-1).opts.body),
      {p_email:'new@example.com',p_note:'Old free-text note',p_source:'zodis.app'});
    calls=[];
    assert.equal((await handler(new Request('https://db.example.test/functions/v1/beta-signup',
      {method:'POST',headers:{origin:'https://attacker.test'},body:'{}'}))).status,403);
    assert.equal(calls.length,0);
    calls=[];assert.equal((await submit({referralSource:'reddit',turnstileToken:''})).status,403);
    assert.equal(calls.some(c=>c.url.includes('/rpc/')),false);
    calls=[];assert.equal((await submit({referralSource:'reddit',website:'spambot'})).status,200);
    assert.equal(calls.length,0);
  } finally {globalThis.Deno=previousDeno;globalThis.fetch=previousFetch}
});
