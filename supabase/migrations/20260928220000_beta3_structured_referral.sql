-- Self-reported acquisition source is distinct from the technical signup source.
-- Historical free-text notes are left untouched; nullable fields keep the live legacy form working.
alter table public.beta_requests
  add column referral_source text,
  add column referral_detail text;

alter table public.beta_requests
  add constraint beta_requests_referral_source_v1
    check (referral_source is null or referral_source in
      ('reddit','instagram','facebook','tiktok','google_search','friend_family',
       'language_community','previous_beta','other')),
  add constraint beta_requests_referral_detail_v1
    check (referral_detail is null or
      (referral_source is not distinct from 'other' and length(referral_detail) between 1 and 200 and
       referral_detail = btrim(referral_detail)));

-- The five-argument service-only RPC writes both acquisition fields atomically.
-- The three-argument RPC is intentionally retained as a legacy wrapper while
-- old landing forms can remain open or cached during controlled rollout.
CREATE OR REPLACE FUNCTION public.beta_submit_request(p_email text, p_note text, p_source text, p_referral_source text, p_referral_detail text)
 RETURNS TABLE(outcome text, tester_count integer, request_id bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_email text := lower(btrim(p_email)); v_count integer; v_id bigint;
begin
  if v_email is null or length(v_email) > 254 or
     v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' or
     p_note is null or length(btrim(p_note)) < 1 or length(p_note) > 500 or
     p_source is distinct from 'zodis.app' or
     (p_referral_source is not null and p_referral_source not in
       ('reddit','instagram','facebook','tiktok','google_search','friend_family',
        'language_community','previous_beta','other')) or
     (p_referral_detail is not null and
       (p_referral_source is distinct from 'other' or length(p_referral_detail) > 200 or
        p_referral_detail <> btrim(p_referral_detail) or p_referral_detail = '')) then
    raise exception 'invalid beta request' using errcode = '22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(4522026, 100);
  select count(*)::integer into v_count
    from public.beta_allowlist ba
    where lower(btrim(ba.email)) not in ('davidgordonlang@gmail.com','barbora.gaulyte@gmail.com');

  select r.id into v_id
    from public.beta_requests r
    where lower(btrim(r.email)) = v_email
    limit 1;
  if found then
    return query select 'received'::text, v_count, v_id;
    return;
  end if;

  if exists (select 1 from public.beta_allowlist ba where lower(btrim(ba.email)) = v_email) then
    return query select 'received'::text, v_count, null::bigint;
    return;
  end if;

  insert into public.beta_requests(email,note,source,referral_source,referral_detail,status,decided_at,email_state,discord_state)
  values (v_email,btrim(p_note),p_source,p_referral_source,p_referral_detail,
          case when v_count < 100 then 'admitted' else 'waitlisted' end,
          now(),'pending','pending') returning id into v_id;
  if v_count < 100 then
    insert into public.beta_allowlist(email) values (v_email);
    v_count := v_count + 1;
    return query select 'admitted'::text, v_count, v_id;
  else
    return query select 'waitlisted'::text, v_count, v_id;
  end if;
end $function$
;

create or replace function public.beta_submit_request(
  p_email text, p_note text, p_source text default 'zodis.app'
) returns table (outcome text, tester_count integer, request_id bigint)
language plpgsql security definer set search_path = ''
as $function$
begin
  return query select r.outcome, r.tester_count, r.request_id
    from public.beta_submit_request(p_email,p_note,p_source,null::text,null::text) r;
end $function$;

revoke all on function public.beta_submit_request(text,text,text,text,text)
  from public,anon,authenticated;
grant execute on function public.beta_submit_request(text,text,text,text,text)
  to service_role;
-- Preserve the existing internal-only privilege on the compatibility wrapper.
revoke all on function public.beta_submit_request(text,text,text)
  from public,anon,authenticated;
grant execute on function public.beta_submit_request(text,text,text)
  to service_role;
