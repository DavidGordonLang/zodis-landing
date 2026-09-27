-- Temporary controlled-test helper for the Beta 3 onboarding preview only.
-- Production admission remains governed by beta_submit_request with a fixed cap of 100.
create or replace function public.beta_submit_request_testcap(
  p_email text,
  p_note text,
  p_source text default 'zodis.app',
  p_capacity integer default 100
)
returns table (outcome text, tester_count integer, request_id bigint)
language plpgsql security definer set search_path = ''
as $$
declare v_email text := lower(btrim(p_email)); v_count integer; v_id bigint; v_cap integer;
begin
  v_cap := greatest(1, least(coalesce(p_capacity, 100), 100));
  if v_email is null or length(v_email) > 254 or
     v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' or
     p_note is null or length(btrim(p_note)) < 1 or length(p_note) > 500 or
     p_source <> 'zodis.app' then
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

  insert into public.beta_requests(email,note,source,status,decided_at,email_state,discord_state)
  values (
    v_email,btrim(p_note),p_source,
    case when v_count < v_cap then 'admitted' else 'waitlisted' end,
    now(),'pending','pending'
  ) returning id into v_id;

  if v_count < v_cap then
    insert into public.beta_allowlist(email) values (v_email);
    v_count := v_count + 1;
    return query select 'admitted'::text, v_count, v_id;
  else
    return query select 'waitlisted'::text, v_count, v_id;
  end if;
end $$;

revoke all on function public.beta_submit_request_testcap(text,text,text,integer) from public,anon,authenticated;
grant execute on function public.beta_submit_request_testcap(text,text,text,integer) to service_role;
