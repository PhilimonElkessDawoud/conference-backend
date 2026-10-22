-- =====================================================================
-- Migration: the admins' notifications in the members' app (bell)
-- Applies on top of 20261021120000_grand_jeu.sql.
--
-- Until now, the notifications sent by the admins (send-push) were only
-- readable by the admins (their history): a member got the push on the
-- phone, but not in the app's notification list. Now:
--   - a member reads the notifications sent to everyone or to one of
--     their teams (only those);
--   - each notification keeps the page of the app it opens (`url`), so
--     that the app's list leads where the push led (e.g. the clues tab of
--     the grand jeu for a bonus clue).
-- =====================================================================

alter table public.notifications
  add column url text not null default '/' check (url ~ '^/' and char_length(url) <= 300);


-- ---------------------------------------------------------------------
-- Admin: log the notification and return the devices to push to.
-- Same as before, plus the page the notification opens (p_url, '/' by
-- default). The old 3-argument version is replaced (dropped first, so
-- that a call with 3 arguments is not ambiguous).
-- ---------------------------------------------------------------------
drop function public.prepare_push_notification(text, text, uuid);

create function public.prepare_push_notification(
  p_title text, p_body text, p_target_team_id uuid default null, p_url text default '/')
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_id      uuid;
  v_targets jsonb;
  v_url     text := coalesce(nullif(trim(p_url), ''), '/');
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
  if v_url !~ '^/' or char_length(v_url) > 300 then
    raise exception 'The page must start with /';
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

  insert into public.notifications (title, body, target_team_id, devices_count, url)
  values (trim(p_title), trim(p_body), p_target_team_id, jsonb_array_length(v_targets), v_url)
  returning id into v_id;

  return jsonb_build_object('notification_id', v_id, 'targets', v_targets);
end;
$$;

revoke execute on function public.prepare_push_notification(text, text, uuid, text) from public, anon;
grant  execute on function public.prepare_push_notification(text, text, uuid, text) to authenticated;  -- checks is_admin() inside


-- ---------------------------------------------------------------------
-- Members read the notifications meant for them: sent to everyone, or to
-- one of their teams. (Admins keep reading and managing all of them.)
-- ---------------------------------------------------------------------
create policy "notifications: members read theirs" on public.notifications
  for select to authenticated
  using ((select public.is_member())
         and (target_team_id is null or public.is_team_member(target_team_id)));
