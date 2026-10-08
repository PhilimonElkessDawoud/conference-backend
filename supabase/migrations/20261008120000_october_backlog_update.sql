-- =====================================================================
-- Migration: October backlog update
-- Applies on top of 20260929000000_initial_schema.sql (the pushed version).
--
--   PBI-7/16  Program made of admin-managed slots (no overlaps) + slot teams
--   PBI-8     Sermon questions attached to sermon slots (replaces sermon_key)
--   PBI-14    Admins create/rename/delete teams and move members
--   PBI-15    Admins add/edit/deactivate members, grant admin rights;
--             optional church and age; get_member() lookup by id or phone
--   PBI-17    Member profile photos (avatars bucket)
--   PBI-11/18 Chants as admin-uploaded PDFs (chants table + bucket)
--   PBI-5     Daily questions published on demand + close_daily_question()
--
-- Deactivated members are cut off from all data, so most read policies now
-- require an active member (is_member()).
-- =====================================================================


-- ---------------------------------------------------------------------
-- Safety check: sermon questions move from a text key to a slot.
-- Existing questions can't be mapped automatically, so stop if any exist.
-- ---------------------------------------------------------------------
do $$
begin
  if exists (select 1 from public.sermon_questions) then
    raise exception 'sermon_questions is not empty: delete the test questions first '
                    '(delete from public.sermon_questions;) and push again';
  end if;
end;
$$;


-- ---------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------
create type public.slot_type as enum ('session', 'sermon', 'workshop', 'game', 'meal', 'other');


-- ---------------------------------------------------------------------
-- Members: new columns
-- ---------------------------------------------------------------------
alter table public.members
  add constraint members_full_name_check check (char_length(trim(full_name)) between 1 and 120),
  add column church      text check (char_length(trim(church)) between 1 and 120),   -- optional
  add column age         smallint check (age between 1 and 120),                     -- optional
  add column avatar_path text,                                                      -- 'avatars' bucket
  add column is_active   boolean not null default true;


-- ---------------------------------------------------------------------
-- Helpers: a deactivated member resolves to NULL / false everywhere
-- ---------------------------------------------------------------------
create or replace function public.current_member_id()
returns uuid
language sql stable security definer set search_path = ''
as $$
  select id from public.members where auth_user_id = auth.uid() and is_active
$$;

create function public.is_member()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select public.current_member_id() is not null
$$;

create or replace function public.is_admin()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce(
    (select is_admin from public.members where auth_user_id = auth.uid() and is_active),
    false
  )
$$;

-- Public-facing profiles (no phone, church or age), active members only.
create or replace view public.member_profiles as
  select id, full_name, avatar_path
  from public.members
  where is_active and (select public.is_member());


-- ---------------------------------------------------------------------
-- Members: guards, relinking on phone change, deactivation, lookup
-- auth.uid() is NULL for the SQL editor, the seed and the Auth server,
-- which are trusted; the checks only apply to requests from the app.
-- ---------------------------------------------------------------------
create function public.members_before_write()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_relink boolean := tg_op = 'INSERT';
begin
  if tg_op = 'UPDATE' then
    -- Members may only change their own photo; the rest is admin-only.
    if auth.uid() is not null and not public.is_admin()
       and (new.full_name, new.phone, new.church, new.age, new.is_admin, new.is_active)
           is distinct from (old.full_name, old.phone, old.church, old.age, old.is_admin, old.is_active) then
      raise exception 'Only admins can change this' using errcode = '42501';
    end if;

    -- Never leave the app without an active admin.
    if old.is_admin and old.is_active and not (new.is_admin and new.is_active)
       and not exists (select 1 from public.members
                       where is_admin and is_active and id <> old.id) then
      raise exception 'There must be at least one active admin';
    end if;

    v_relink := new.phone is distinct from old.phone;
  end if;

  -- New member or new phone number: link to the auth account that already
  -- uses this number, if any. Otherwise the member is unlinked and must
  -- register again with the new number.
  if v_relink then
    new.auth_user_id := null;
    new.has_password := false;
    select u.id, coalesce(u.encrypted_password, '') <> ''
      into new.auth_user_id, new.has_password
    from auth.users u
    where regexp_replace(coalesce(u.phone, ''), '[^0-9]', '', 'g')
        = regexp_replace(new.phone, '[^0-9]', '', 'g')
      and not exists (select 1 from public.members m
                      where m.auth_user_id = u.id and m.id <> new.id)
    limit 1;
    new.has_password := coalesce(new.has_password, false);
  end if;

  return new;
end;
$$;

create trigger members_before_write
before insert or update on public.members
for each row execute function public.members_before_write();

-- Look up one member by id OR by phone (exactly one of the two).
--   POST /rest/v1/rpc/get_member  {"p_id": "..."}  or  {"p_phone": "+33612345678"}
-- SECURITY INVOKER: members' RLS applies, so admins can find anyone and a
-- member can only find themselves. Not found → HTTP 404 (SQLSTATE PT404,
-- PostgREST's convention for choosing the HTTP status).
create function public.get_member(p_id uuid default null, p_phone text default null)
returns setof public.members
language plpgsql stable set search_path = ''
rows 1
as $$
begin
  if (p_id is null) = (p_phone is null) then
    raise exception 'Provide either p_id or p_phone, not both'
      using errcode = '22023', hint = 'Send exactly one of the two parameters.';
  end if;

  return query
    select * from public.members m
    where (p_id is not null and m.id = p_id)
       or (p_phone is not null
           and regexp_replace(m.phone, '[^0-9]', '', 'g') = regexp_replace(p_phone, '[^0-9]', '', 'g'));

  if not found then
    raise exception 'Member not found' using errcode = 'PT404';
  end if;
end;
$$;


-- ---------------------------------------------------------------------
-- Teams: admin management
-- ---------------------------------------------------------------------
alter table public.teams
  add constraint teams_name_check check (char_length(trim(name)) between 1 and 80);

-- Team members may change their team's photo; only admins may rename it.
create function public.teams_before_update()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if auth.uid() is not null and not public.is_admin()
     and new.name is distinct from old.name then
    raise exception 'Only admins can rename a team' using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger teams_before_update
before update on public.teams
for each row execute function public.teams_before_update();

-- Admin assigns a member to a team. If the member is already in a team of
-- that type, they are moved (the previous assignment is replaced).
create function public.set_member_team(p_member_id uuid, p_team_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_type public.team_type;
begin
  if not public.is_admin() then
    raise exception 'Admins only' using errcode = '42501';
  end if;

  select type into v_type from public.teams where id = p_team_id;
  if not found then
    raise exception 'Team not found';
  end if;
  if not exists (select 1 from public.members where id = p_member_id and is_active) then
    raise exception 'Member not found or deactivated';
  end if;

  delete from public.team_members where member_id = p_member_id and team_type = v_type;
  insert into public.team_members (team_id, team_type, member_id)
  values (p_team_id, v_type, p_member_id);
end;
$$;

-- A deactivated member is removed from their teams (history is kept
-- elsewhere: answers and points store the team directly).
create function public.members_after_update()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if old.is_active and not new.is_active then
    delete from public.team_members where member_id = new.id;
  end if;
  return null;
end;
$$;

create trigger members_after_update
after update of is_active on public.members
for each row execute function public.members_after_update();


-- ---------------------------------------------------------------------
-- Daily question: published on demand, closed with the server clock
-- ---------------------------------------------------------------------
alter table public.daily_questions
  alter column publish_at set default now(),
  add constraint daily_questions_body_check check (char_length(trim(body)) between 3 and 1000);

create or replace function public.award_daily_point(p_answer_id bigint)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_a public.daily_answers%rowtype;
begin
  if not public.is_admin() then
    raise exception 'Admins only' using errcode = '42501';
  end if;

  select * into v_a from public.daily_answers where id = p_answer_id;
  if not found then
    raise exception 'Answer not found';
  end if;

  perform 1 from public.daily_questions where id = v_a.question_id for update;

  if exists (select 1 from public.daily_answers
             where question_id = v_a.question_id and team_id = v_a.team_id and earned_point) then
    raise exception 'This team already earned the point for this question';
  end if;
  if (select count(*) from public.daily_answers
      where question_id = v_a.question_id and earned_point) >= 3 then
    raise exception 'Three teams have already earned the point for this question';
  end if;

  update public.daily_answers set earned_point = true where id = p_answer_id;

  insert into public.score_events (team_id, delta, reason, source, daily_question_id)
  values (v_a.team_id, 1, 'Daily question', 'daily_question', v_a.question_id);
end;
$$;

create or replace function public.revoke_daily_point(p_answer_id bigint)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_a public.daily_answers%rowtype;
begin
  if not public.is_admin() then
    raise exception 'Admins only' using errcode = '42501';
  end if;

  select * into v_a from public.daily_answers where id = p_answer_id and earned_point;
  if not found then
    raise exception 'This answer has no point to revoke';
  end if;

  update public.daily_answers set earned_point = false where id = p_answer_id;
  delete from public.score_events
  where daily_question_id = v_a.question_id and team_id = v_a.team_id and source = 'daily_question';
end;
$$;

-- Admin closes a question now, using the server clock (a phone's clock may
-- be off). Answers sent afterwards are refused by submit_daily_answer().
create function public.close_daily_question(p_question_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'Admins only' using errcode = '42501';
  end if;

  update public.daily_questions
  set closes_at = now()
  where id = p_question_id
    and publish_at <= now()
    and (closes_at is null or closes_at > now());
  if not found then
    raise exception 'Question not found, not published yet, or already closed';
  end if;
end;
$$;


-- ---------------------------------------------------------------------
-- Program: slots (no overlaps, back-to-back allowed, no crossing midnight)
-- ---------------------------------------------------------------------
create table public.slots (
  id          uuid primary key default gen_random_uuid(),
  title       text not null check (char_length(trim(title)) between 1 and 120),
  type        public.slot_type not null default 'session',
  slot_date   date not null,
  start_time  time not null,
  end_time    time not null,
  place       text not null check (char_length(trim(place)) between 1 and 120),
  created_at  timestamptz not null default now(),
  constraint slots_end_after_start check (end_time > start_time),
  -- Rejected with SQLSTATE 23P01 when a slot would overlap another one.
  constraint slots_no_overlap exclude using gist (
    tsrange(slot_date + start_time, slot_date + end_time, '[)') with &&
  )
);
create index on public.slots (slot_date, start_time);

create table public.slot_teams (
  slot_id  uuid not null references public.slots (id) on delete cascade,
  team_id  uuid not null references public.teams (id) on delete cascade,
  primary key (slot_id, team_id)
);
create index on public.slot_teams (team_id);


-- ---------------------------------------------------------------------
-- Sermon Q&A: attach questions to sermon slots instead of a text key
-- (the table is empty, checked at the top)
-- ---------------------------------------------------------------------
drop index if exists public.sermon_questions_sermon_key_status_like_count_created_at_idx;
alter table public.sermon_questions drop column sermon_key;
alter table public.sermon_questions
  add column slot_id uuid not null references public.slots (id) on delete cascade;
create index on public.sermon_questions (slot_id, status, like_count desc, created_at desc);

drop function public.submit_sermon_question(text, text);
create function public.submit_sermon_question(p_slot_id uuid, p_body text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_member uuid := public.current_member_id();
  v_id     uuid;
begin
  if v_member is null then
    raise exception 'Not a registered member';
  end if;
  if not exists (select 1 from public.slots where id = p_slot_id and type = 'sermon') then
    raise exception 'Questions can only be submitted for sermons';
  end if;

  insert into public.sermon_questions (slot_id, body)
  values (p_slot_id, trim(p_body))
  returning id into v_id;

  insert into public.sermon_question_authors (question_id, member_id)
  values (v_id, v_member);

  return v_id;
end;
$$;


-- ---------------------------------------------------------------------
-- Chants as PDFs
-- ---------------------------------------------------------------------
create table public.chants (
  id          uuid primary key default gen_random_uuid(),
  title       text not null check (char_length(trim(title)) between 1 and 200),
  file_path   text not null unique,              -- path in the 'chants' bucket
  sort_order  integer not null default 0,
  created_by  uuid references public.members (id) on delete set null default public.current_member_id(),
  created_at  timestamptz not null default now()
);
create index on public.chants (sort_order, title);


-- ---------------------------------------------------------------------
-- Auth hook: deactivated members can't register
-- ---------------------------------------------------------------------
create or replace function public.hook_before_user_created(event jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
begin
  if exists (select 1 from public.members
             where is_active
               and regexp_replace(phone, '[^0-9]', '', 'g')
                 = regexp_replace(coalesce(event -> 'user' ->> 'phone', ''), '[^0-9]', '', 'g')
               and coalesce(event -> 'user' ->> 'phone', '') <> '') then
    return '{}'::jsonb;
  end if;
  return jsonb_build_object('error', jsonb_build_object(
    'http_code', 403,
    'message', 'This phone number is not registered for the conference.'
  ));
end;
$$;


-- =====================================================================
-- Row Level Security
-- =====================================================================
alter table public.slots      enable row level security;
alter table public.slot_teams enable row level security;
alter table public.chants     enable row level security;

-- Existing policies now require an active member
alter policy "members: read own or admin" on public.members
  using (id = (select public.current_member_id()) or (select public.is_admin()));
alter policy "teams: read" on public.teams
  using ((select public.is_member()));
alter policy "team_members: read" on public.team_members
  using ((select public.is_member()));
alter policy "daily_questions: read published" on public.daily_questions
  using (((select public.is_member()) and publish_at <= now()) or (select public.is_admin()));
alter policy "score_events: read" on public.score_events
  using ((select public.is_member()));
alter policy "conference_settings: read" on public.conference_settings
  using ((select public.is_member()));
alter policy "sermon_questions: read approved or admin" on public.sermon_questions
  using (((select public.is_member()) and status = 'approved') or (select public.is_admin()));
alter policy "wall_photos: read" on public.wall_photos
  using (((select public.is_member()) and status = 'approved')
         or member_id = (select public.current_member_id())
         or (select public.is_admin()));

-- Members: admins add and edit; members edit their own photo; never deleted
create policy "members: admin insert" on public.members
  for insert to authenticated
  with check ((select public.is_admin()));
create policy "members: update own or admin" on public.members
  for update to authenticated
  using (id = (select public.current_member_id()) or (select public.is_admin()))
  with check (id = (select public.current_member_id()) or (select public.is_admin()));
revoke insert, update, delete on public.members from anon, authenticated;
grant insert (full_name, phone, church, age, is_admin) on public.members to authenticated;
grant update (full_name, phone, church, age, is_admin, is_active, avatar_path) on public.members to authenticated;
-- members_before_write() limits non-admins to avatar_path.

-- Teams: admins create/rename/delete; team members change the photo
drop policy "teams: members update photo" on public.teams;
create policy "teams: admin insert" on public.teams
  for insert to authenticated
  with check ((select public.is_admin()));
create policy "teams: team members or admin update" on public.teams
  for update to authenticated
  using (public.is_team_member(id) or (select public.is_admin()))
  with check (public.is_team_member(id) or (select public.is_admin()));
create policy "teams: admin delete" on public.teams
  for delete to authenticated using ((select public.is_admin()));
revoke insert, update on public.teams from anon, authenticated;
grant insert (name, type) on public.teams to authenticated;
grant update (name, photo_path) on public.teams to authenticated;
-- teams_before_update() limits non-admins to photo_path.

-- Team membership: admins assign via set_member_team() and remove via DELETE
create policy "team_members: admin delete" on public.team_members
  for delete to authenticated using ((select public.is_admin()));
revoke insert, update on public.team_members from anon, authenticated;

-- Slots & their teams: members read; admins manage
create policy "slots: read" on public.slots
  for select to authenticated using ((select public.is_member()));
create policy "slots: admin write" on public.slots
  for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));
create policy "slot_teams: read" on public.slot_teams
  for select to authenticated using ((select public.is_member()));
create policy "slot_teams: admin write" on public.slot_teams
  for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

-- Chants: members read; admins upload/reorder/remove
create policy "chants: read" on public.chants
  for select to authenticated using ((select public.is_member()));
create policy "chants: admin write" on public.chants
  for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));


-- ---------------------------------------------------------------------
-- Function grants
-- ---------------------------------------------------------------------
revoke execute on function public.submit_sermon_question(uuid, text) from public, anon;
revoke execute on function public.set_member_team(uuid, uuid)        from public, anon;
revoke execute on function public.get_member(uuid, text)             from public, anon;
revoke execute on function public.close_daily_question(uuid)         from public, anon;
grant  execute on function public.submit_sermon_question(uuid, text) to authenticated;
grant  execute on function public.set_member_team(uuid, uuid)        to authenticated;  -- checks is_admin() inside
grant  execute on function public.get_member(uuid, text)             to authenticated;  -- RLS applies inside
grant  execute on function public.close_daily_question(uuid)         to authenticated;  -- checks is_admin() inside

revoke execute on function public.members_before_write()     from public, anon, authenticated;
revoke execute on function public.members_after_update()     from public, anon, authenticated;
revoke execute on function public.teams_before_update()      from public, anon, authenticated;


-- =====================================================================
-- Storage: new buckets (avatars, chants) and member-only reads
-- =====================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('avatars', 'avatars', false,  1048576, array['image/jpeg', 'image/png', 'image/webp']),
  ('chants',  'chants',  false, 10485760, array['application/pdf']);

alter policy "team-photos: read" on storage.objects
  using (bucket_id = 'team-photos' and (select public.is_member()));
alter policy "wall-originals: read" on storage.objects
  using (
    bucket_id = 'wall-originals'
    and (
      (storage.foldername(name))[1] = (select public.current_member_id())::text
      or (select public.is_admin())
      or ((select public.is_member())
          and (select public.wall_revealed())
          and exists (select 1 from public.wall_photos w
                      where w.original_path = name and w.status = 'approved'))
    )
  );
alter policy "wall-blurred: read approved" on storage.objects
  using (
    bucket_id = 'wall-blurred'
    and (select public.is_member())
    and exists (select 1 from public.wall_photos w
                where w.blurred_path = name and w.status = 'approved')
  );

-- Avatars: members read all; each member manages their own folder
create policy "avatars: read" on storage.objects
  for select to authenticated
  using (bucket_id = 'avatars' and (select public.is_member()));
create policy "avatars: upload own" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'avatars'
              and (storage.foldername(name))[1] = (select public.current_member_id())::text);
create policy "avatars: replace own" on storage.objects
  for update to authenticated
  using (bucket_id = 'avatars'
         and (storage.foldername(name))[1] = (select public.current_member_id())::text);
create policy "avatars: delete own" on storage.objects
  for delete to authenticated
  using (bucket_id = 'avatars'
         and (storage.foldername(name))[1] = (select public.current_member_id())::text);

-- Chants: members read; admins upload/replace/delete
create policy "chants: read" on storage.objects
  for select to authenticated
  using (bucket_id = 'chants' and (select public.is_member()));
create policy "chants: admin upload" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'chants' and (select public.is_admin()));
create policy "chants: admin replace" on storage.objects
  for update to authenticated
  using (bucket_id = 'chants' and (select public.is_admin()));
create policy "chants: admin delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'chants' and (select public.is_admin()));


-- =====================================================================
-- Realtime
-- =====================================================================
alter publication supabase_realtime add table
  public.daily_questions, public.slots, public.slot_teams;
