-- =====================================================================
-- Migration: Web Push notifications (PBI-13)
-- Applies on top of 20261008120000_october_backlog_update.sql.
--
-- Flow:
--   1. A member's device subscribes in the browser and calls
--      register_push_subscription() to store it.
--   2. An admin calls the 'send-push' Edge Function. The function, acting
--      with the admin's own token (no secret key), calls
--      prepare_push_notification() to log the notification and get the
--      target devices, sends the pushes, then reports back with
--      remove_push_subscriptions() and record_push_result().
-- =====================================================================


-- Delivery stats shown in the admin's notification history
alter table public.notifications
  add column devices_count integer,      -- devices targeted
  add column sent_count    integer,      -- accepted by the push services
  add column failed_count  integer;      -- rejected (expired devices are removed)


-- ---------------------------------------------------------------------
-- Member: store this device's subscription.
-- Upsert on the endpoint, so a device that changes hands (logout, then
-- another member logs in on the same phone) is reassigned instead of
-- failing on the unique endpoint.
-- ---------------------------------------------------------------------
create function public.register_push_subscription(p_endpoint text, p_p256dh text, p_auth text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_member uuid := public.current_member_id();
begin
  if v_member is null then
    raise exception 'Not a registered member' using errcode = '42501';
  end if;
  if p_endpoint !~ '^https://' or coalesce(p_p256dh, '') = '' or coalesce(p_auth, '') = '' then
    raise exception 'Invalid push subscription';
  end if;

  insert into public.push_subscriptions (member_id, endpoint, p256dh, auth)
  values (v_member, p_endpoint, p_p256dh, p_auth)
  on conflict (endpoint) do update
    set member_id = excluded.member_id,
        p256dh    = excluded.p256dh,
        auth      = excluded.auth,
        created_at = now();
end;
$$;


-- ---------------------------------------------------------------------
-- Admin: log the notification and return the devices to push to.
-- Targets active members only; p_target_team_id = null means everyone.
-- Returns {"notification_id": ..., "targets": [{endpoint, p256dh, auth}]}.
-- ---------------------------------------------------------------------
create function public.prepare_push_notification(p_title text, p_body text, p_target_team_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_id      uuid;
  v_targets jsonb;
begin
  if not public.is_admin() then
    raise exception 'Admins only' using errcode = '42501';
  end if;
  if char_length(trim(coalesce(p_title, ''))) not between 1 and 80 then
    raise exception 'Title must be 1 to 80 characters';
  end if;
  if char_length(trim(coalesce(p_body, ''))) not between 1 and 300 then
    raise exception 'Message must be 1 to 300 characters';
  end if;
  if p_target_team_id is not null
     and not exists (select 1 from public.teams where id = p_target_team_id) then
    raise exception 'Team not found';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth)), '[]'::jsonb)
    into v_targets
  from public.push_subscriptions s
  join public.members m on m.id = s.member_id and m.is_active
  where p_target_team_id is null
     or exists (select 1 from public.team_members tm
                where tm.member_id = s.member_id and tm.team_id = p_target_team_id);

  insert into public.notifications (title, body, target_team_id, devices_count)
  values (trim(p_title), trim(p_body), p_target_team_id, jsonb_array_length(v_targets))
  returning id into v_id;

  return jsonb_build_object('notification_id', v_id, 'targets', v_targets);
end;
$$;


-- ---------------------------------------------------------------------
-- Admin: drop subscriptions the push service reported as expired (404/410)
-- ---------------------------------------------------------------------
create function public.remove_push_subscriptions(p_endpoints text[])
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  v_count integer;
begin
  if not public.is_admin() then
    raise exception 'Admins only' using errcode = '42501';
  end if;
  delete from public.push_subscriptions where endpoint = any (p_endpoints);
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;


-- ---------------------------------------------------------------------
-- Admin: save how many pushes were accepted / rejected
-- ---------------------------------------------------------------------
create function public.record_push_result(p_notification_id uuid, p_sent integer, p_failed integer)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'Admins only' using errcode = '42501';
  end if;
  update public.notifications
  set sent_count = p_sent, failed_count = p_failed
  where id = p_notification_id;
end;
$$;


-- ---------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------
revoke execute on function public.register_push_subscription(text, text, text)  from public, anon;
revoke execute on function public.prepare_push_notification(text, text, uuid)   from public, anon;
revoke execute on function public.remove_push_subscriptions(text[])             from public, anon;
revoke execute on function public.record_push_result(uuid, integer, integer)    from public, anon;
grant  execute on function public.register_push_subscription(text, text, text)  to authenticated;
grant  execute on function public.prepare_push_notification(text, text, uuid)   to authenticated;  -- checks is_admin() inside
grant  execute on function public.remove_push_subscriptions(text[])             to authenticated;  -- checks is_admin() inside
grant  execute on function public.record_push_result(uuid, integer, integer)    to authenticated;  -- checks is_admin() inside
