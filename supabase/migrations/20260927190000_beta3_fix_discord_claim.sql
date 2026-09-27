-- Fix beta_claim_delivery Discord branch: qualify beta_allowlist.email so it
-- cannot collide with the function's output column named email.
create or replace function public.beta_claim_delivery(p_channel text, p_request_id bigint default null)
returns table (request_id bigint, email text, note text, source text, status text,
               tester_count integer, claim_id uuid, attempts integer, decided_at timestamptz)
language plpgsql security definer set search_path = ''
as $$
declare v public.beta_requests%rowtype; v_claim uuid := gen_random_uuid(); v_count integer;
begin
  if p_channel not in ('email','discord') then raise exception 'invalid channel'; end if;
  select * into v from public.beta_requests r
   where r.status in ('admitted','waitlisted') and
   (p_request_id is null or r.id = p_request_id) and
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
    select count(*)::integer into v_count
      from public.beta_allowlist ba
      where lower(btrim(ba.email)) not in ('davidgordonlang@gmail.com','barbora.gaulyte@gmail.com');
  end if;
  return query select v.id,v.email,v.note,v.source,v.status,v_count,v_claim,
     case when p_channel='email' then v.email_attempts+1 else v.discord_attempts+1 end,v.decided_at;
end $$;

revoke all on function public.beta_claim_delivery(text,bigint) from public,anon,authenticated;
grant execute on function public.beta_claim_delivery(text,bigint) to service_role;
