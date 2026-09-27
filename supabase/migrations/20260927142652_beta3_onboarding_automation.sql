-- Beta 3 public signup. Apply only at the approved production activation checkpoint.
-- Existing pending requests are deliberately not swept into this new cohort.
alter table public.beta_requests
  add column if not exists decided_at timestamptz,
  add column if not exists email_state text not null default 'none',
  add column if not exists email_sent_at timestamptz,
  add column if not exists email_provider_id text,
  add column if not exists email_attempts integer not null default 0,
  add column if not exists email_error text,
  add column if not exists email_claim uuid,
  add column if not exists email_claimed_at timestamptz,
  add column if not exists discord_state text not null default 'none',
  add column if not exists discord_sent_at timestamptz,
  add column if not exists discord_attempts integer not null default 0,
  add column if not exists discord_error text,
  add column if not exists discord_claim uuid,
  add column if not exists discord_claimed_at timestamptz,
  add column if not exists suppressed_at timestamptz;

alter table public.beta_requests
  add constraint beta_requests_status_v3 check (status in ('pending','admitted','waitlisted')),
  add constraint beta_requests_email_state_v3 check (email_state in ('none','pending','sending','sent','failed')),
  add constraint beta_requests_discord_state_v3 check (discord_state in ('none','pending','sending','sent','failed')),
  add constraint beta_requests_normal_email_v3 check (email = lower(btrim(email)) and email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$');

create unique index beta_requests_email_lower_v3 on public.beta_requests (lower(btrim(email)));
create unique index beta_allowlist_email_lower_v3 on public.beta_allowlist (lower(btrim(email)));
create index beta_requests_delivery_v3 on public.beta_requests (email_state, discord_state, created_at)
  where status in ('admitted','waitlisted');

-- The old direct browser insertion path is removed at activation. No public read policy is added.
drop policy if exists "landing page can submit beta requests" on public.beta_requests;
revoke insert on public.beta_requests from anon, authenticated;

create or replace function public.beta_submit_request(p_email text, p_note text, p_source text default 'zodis.app')
returns table (outcome text, tester_count integer)
language plpgsql security definer set search_path = ''
as $$
declare v_email text := lower(btrim(p_email)); v_count integer; v_id bigint;
begin
  if v_email is null or length(v_email) > 254 or
     v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' or
     p_note is null or length(btrim(p_note)) < 1 or length(p_note) > 500 or
     p_source <> 'zodis.app' then
    raise exception 'invalid beta request' using errcode = '22023';
  end if;

  -- One transaction-scoped lock serialises admission, including the final place.
  perform pg_catalog.pg_advisory_xact_lock(4522026, 100);
  select count(*)::integer into v_count from public.beta_allowlist
   where lower(btrim(email)) not in ('davidgordonlang@gmail.com','barbora.gaulyte@gmail.com');

  -- A request or allowlist entry pre-dating activation must not receive a new email.
  if exists (select 1 from public.beta_requests where lower(btrim(email)) = v_email)
     or exists (select 1 from public.beta_allowlist where lower(btrim(email)) = v_email) then
    return query select 'received'::text, v_count;
    return;
  end if;

  insert into public.beta_requests(email,note,source,status,decided_at,email_state,discord_state)
  values (v_email,btrim(p_note),p_source,
          case when v_count < 100 then 'admitted' else 'waitlisted' end,
          now(),'pending','pending') returning id into v_id;
  if v_count < 100 then
    insert into public.beta_allowlist(email) values (v_email);
    v_count := v_count + 1;
    return query select 'admitted'::text, v_count;
  else
    return query select 'waitlisted'::text, v_count;
  end if;
end $$;

create or replace function public.beta_claim_delivery(p_channel text)
returns table (request_id bigint, email text, note text, source text, status text,
               tester_count integer, claim_id uuid, attempts integer, decided_at timestamptz)
language plpgsql security definer set search_path = ''
as $$
declare v public.beta_requests%rowtype; v_claim uuid := gen_random_uuid(); v_count integer;
begin
  if p_channel not in ('email','discord') then raise exception 'invalid channel'; end if;
  select * into v from public.beta_requests r
   where r.status in ('admitted','waitlisted') and
   ((p_channel = 'email' and r.suppressed_at is null and
     (r.email_state = 'pending' or (r.email_state = 'failed' and r.email_attempts < 4
       and r.email_claimed_at < now() - interval '5 minutes')
      or (r.email_state = 'sending' and r.email_claimed_at < now() - interval '10 minutes' and r.email_attempts < 4)))
    or (p_channel = 'discord' and
     (r.discord_state = 'pending' or (r.discord_state = 'failed' and r.discord_attempts < 4
       and r.discord_claimed_at < now() - interval '5 minutes')
      or (r.discord_state = 'sending' and r.discord_claimed_at < now() - interval '10 minutes' and r.discord_attempts < 4))))
   order by r.created_at for update skip locked limit 1;
  if not found then return; end if;
  if p_channel = 'email' then
    update public.beta_requests r set email_state='sending', email_claim=v_claim,
      email_claimed_at=now(),email_attempts=r.email_attempts+1,email_error=null where r.id=v.id;
    v_count := 0;
  else
    update public.beta_requests r set discord_state='sending',discord_claim=v_claim,
      discord_claimed_at=now(),discord_attempts=r.discord_attempts+1,discord_error=null where r.id=v.id;
    select count(*)::integer into v_count from public.beta_allowlist
     where lower(btrim(email)) not in ('davidgordonlang@gmail.com','barbora.gaulyte@gmail.com');
  end if;
  return query select v.id,v.email,v.note,v.source,v.status,v_count,v_claim,
     case when p_channel='email' then v.email_attempts+1 else v.discord_attempts+1 end,v.decided_at;
end $$;

create or replace function public.beta_finish_delivery(p_id bigint,p_channel text,p_claim uuid,
  p_success boolean,p_provider_id text default null,p_error text default null)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  if p_channel = 'email' then
    update public.beta_requests set email_state=case when p_success then 'sent' else 'failed' end,
      email_sent_at=case when p_success then now() else email_sent_at end,
      email_provider_id=case when p_success then p_provider_id else email_provider_id end,
      email_error=case when p_success then null else left(p_error,500) end,
      email_claim=null
     where id=p_id and email_claim=p_claim and email_state='sending';
  elsif p_channel = 'discord' then
    update public.beta_requests set discord_state=case when p_success then 'sent' else 'failed' end,
      discord_sent_at=case when p_success then now() else discord_sent_at end,
      discord_error=case when p_success then null else left(p_error,500) end,
      discord_claim=null
     where id=p_id and discord_claim=p_claim and discord_state='sending';
  else raise exception 'invalid channel'; end if;
  return found;
end $$;

revoke all on function public.beta_submit_request(text,text,text) from public,anon,authenticated;
revoke all on function public.beta_claim_delivery(text) from public,anon,authenticated;
revoke all on function public.beta_finish_delivery(bigint,text,uuid,boolean,text,text) from public,anon,authenticated;
grant execute on function public.beta_submit_request(text,text,text) to service_role;
grant execute on function public.beta_claim_delivery(text) to service_role;
grant execute on function public.beta_finish_delivery(bigint,text,uuid,boolean,text,text) to service_role;
