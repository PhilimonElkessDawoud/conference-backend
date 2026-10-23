-- =====================================================================
-- Migration: slots of different teams may happen at the same time
-- Applies on top of 20261023120000_wall_reveal_admin.sql.
--
-- Before: slots_no_overlap refused any two overlapping slots of the program.
-- Now: two overlapping slots are refused only when
--   * they share a team, or
--   * one of them has no team (it concerns the whole conference).
-- Back-to-back slots are still allowed. Rejected writes keep SQLSTATE 23P01.
--
-- The teams of a slot live in slot_teams, written after the slot itself, so
-- the rule is checked at the end of the transaction (deferred constraint
-- triggers). save_slot() writes a slot and its teams in one transaction and
-- checks the rule before returning: the app uses it for every add and edit.
-- =====================================================================

alter table public.slots drop constraint slots_no_overlap;

-- ---------------------------------------------------------------------
-- The rule, checked for the slot concerned by the written row
-- ---------------------------------------------------------------------
create function public.check_slot_overlap()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_slot_id  uuid;
  v_slot     public.slots;
  v_conflict public.slots;
begin
  if tg_table_name = 'slots' then
    v_slot_id := new.id;
  elsif tg_op = 'DELETE' then
    v_slot_id := old.slot_id;
  else
    v_slot_id := new.slot_id;
  end if;

  select * into v_slot from public.slots where id = v_slot_id;
  if not found then
    -- The slot was deleted in the same transaction: nothing to check.
    return null;
  end if;

  -- One check at a time per day, so that two admins saving at once cannot both pass.
  perform pg_advisory_xact_lock(hashtext('slots:' || v_slot.slot_date::text));

  select other.* into v_conflict
  from public.slots other
  where other.id <> v_slot.id
    and other.slot_date = v_slot.slot_date
    and other.start_time < v_slot.end_time
    and other.end_time > v_slot.start_time
    and (
      not exists (select 1 from public.slot_teams where slot_id = v_slot.id)
      or not exists (select 1 from public.slot_teams where slot_id = other.id)
      or exists (
        select 1
        from public.slot_teams mine
        join public.slot_teams theirs on theirs.team_id = mine.team_id
        where mine.slot_id = v_slot.id and theirs.slot_id = other.id
      )
    )
  order by other.start_time
  limit 1;

  if found then
    raise exception 'Slot overlaps another slot of one of its teams or of the whole conference'
      using errcode = '23P01',
            detail = format('"%s" (%s–%s) overlaps "%s" (%s–%s) on %s',
              v_slot.title, v_slot.start_time, v_slot.end_time,
              v_conflict.title, v_conflict.start_time, v_conflict.end_time, v_slot.slot_date);
  end if;

  return null;
end;
$$;

create constraint trigger slots_no_team_overlap
  after insert or update of slot_date, start_time, end_time on public.slots
  deferrable initially deferred
  for each row execute function public.check_slot_overlap();

-- Adding a team can create a conflict; removing the last one makes the slot
-- concern the whole conference, which can too.
create constraint trigger slot_teams_no_team_overlap
  after insert or update or delete on public.slot_teams
  deferrable initially deferred
  for each row execute function public.check_slot_overlap();

revoke execute on function public.check_slot_overlap() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Add (p_id null) or edit a slot and replace its teams, in one transaction.
-- Admins only (the RLS of slots and slot_teams applies). Returns the slot id.
-- ---------------------------------------------------------------------
create function public.save_slot(
  p_id         uuid,
  p_title      text,
  p_type       public.slot_type,
  p_slot_date  date,
  p_start_time time,
  p_end_time   time,
  p_place      text,
  p_team_ids   uuid[]
)
returns uuid
language plpgsql security invoker set search_path = ''
as $$
declare
  v_id uuid;
begin
  if not public.is_admin() then
    raise exception 'Only admins can manage slots' using errcode = '42501';
  end if;

  if p_id is null then
    insert into public.slots (title, type, slot_date, start_time, end_time, place)
    values (trim(p_title), p_type, p_slot_date, p_start_time, p_end_time, trim(p_place))
    returning id into v_id;
  else
    update public.slots
    set title = trim(p_title), type = p_type, slot_date = p_slot_date,
        start_time = p_start_time, end_time = p_end_time, place = trim(p_place)
    where id = p_id
    returning id into v_id;
    if v_id is null then
      raise exception 'Slot not found' using errcode = 'P0002';
    end if;
  end if;

  delete from public.slot_teams where slot_id = v_id;
  insert into public.slot_teams (slot_id, team_id)
  select distinct v_id, team_id from unnest(coalesce(p_team_ids, '{}'::uuid[])) as team_id;

  -- Run the overlap check now, so that a conflict is reported by this call.
  set constraints public.slots_no_team_overlap, public.slot_teams_no_team_overlap immediate;

  return v_id;
end;
$$;

revoke execute on function public.save_slot(uuid, text, public.slot_type, date, time, time, text, uuid[]) from public, anon;

grant execute on function public.save_slot(uuid, text, public.slot_type, date, time, time, text, uuid[]) to authenticated;
