-- =====================================================================
-- Youth conference app — initial schema (Supabase / Postgres)
-- Auth: phone OTP for registration (restricted to pre-provisioned members),
--       then phone + password for every later login
-- Program & chants are static frontend content (no tables)
-- =====================================================================


-- ---------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------
create type public.team_type         as enum ('workshop', 'game');
create type public.moderation_status as enum ('pending', 'approved', 'rejected');
create type public.score_source      as enum ('admin', 'daily_question');


-- ---------------------------------------------------------------------
-- Epic 1 — Members (pre-provisioned before the conference)
-- ---------------------------------------------------------------------
create table public.members (
  id            uuid primary key default gen_random_uuid(),
  phone         text not null unique check (phone ~ '^\+[1-9][0-9]{7,14}$'),  -- E.164, e.g. +33612345678
  full_name     text not null,
  auth_user_id  uuid unique references auth.users (id) on delete set null,
  is_admin      boolean not null default false,
  has_password  boolean not null default false,  -- maintained by trigger on auth.users
  created_at    timestamptz not null default now()
);

-- Helpers used by RLS policies. SECURITY DEFINER so they can read
-- public.members without triggering members' own RLS (avoids recursion).
create function public.current_member_id()
returns uuid
language sql stable security definer set search_path = ''
as $$
  select id from public.members where auth_user_id = auth.uid()
$$;

create function public.is_admin()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce(
    (select is_admin from public.members where auth_user_id = auth.uid()),
    false
  )
$$;

-- Public-facing names (no phone numbers). Runs with the owner's rights, so it
-- deliberately bypasses members' RLS; Supabase's linter will flag it as
-- a "security definer view" — that is intended here.
create view public.member_profiles as
  select id, full_name from public.members;


-- ---------------------------------------------------------------------
-- Epic 2 — Teams
-- ---------------------------------------------------------------------
create table public.teams (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  type        public.team_type not null,
  photo_path  text,                       -- path in the 'team-photos' bucket
  created_at  timestamptz not null default now(),
  unique (name, type),
  unique (id, type)                        -- target of composite FKs below
);

create table public.team_members (
  team_id    uuid not null,
  team_type  public.team_type not null,
  member_id  uuid not null references public.members (id) on delete cascade,
  primary key (team_id, member_id),
  foreign key (team_id, team_type) references public.teams (id, type) on delete cascade,
  unique (member_id, team_type)            -- at most one workshop team + one game team per member
);

create function public.is_team_member(p_team_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.team_members
    where team_id = p_team_id and member_id = public.current_member_id()
  )
$$;


-- ---------------------------------------------------------------------
-- Epic 3 — Games & scoring
-- ---------------------------------------------------------------------
create table public.daily_questions (
  id          uuid primary key default gen_random_uuid(),
  body        text not null,
  publish_at  timestamptz not null,
  closes_at   timestamptz,
  created_at  timestamptz not null default now(),
  check (closes_at is null or closes_at > publish_at)
);

-- Append-only log: the team score is the sum of its events (audit trail for PBI-4).
create table public.score_events (
  id                 bigint generated always as identity primary key,
  team_id            uuid not null,
  team_type          public.team_type not null default 'game' check (team_type = 'game'),
  delta              integer not null check (delta <> 0),
  reason             text,
  source             public.score_source not null default 'admin',
  daily_question_id  uuid references public.daily_questions (id) on delete set null,
  created_by         uuid references public.members (id) on delete set null default public.current_member_id(),
  created_at         timestamptz not null default now(),
  foreign key (team_id, team_type) references public.teams (id, type) on delete cascade,
  check (source = 'admin' or daily_question_id is not null)
);
create index on public.score_events (team_id);
-- Safety net: a team can earn the daily-question point only once per question.
create unique index score_events_one_daily_point_per_team
  on public.score_events (daily_question_id, team_id)
  where source = 'daily_question';

create view public.team_scores with (security_invoker = true) as
  select t.id as team_id, t.name, t.photo_path,
         coalesce(sum(s.delta), 0)::int as score
  from public.teams t
  left join public.score_events s on s.team_id = t.id
  where t.type = 'game'
  group by t.id;

-- Every attempt is kept (unlimited attempts). No answer key: an admin reads
-- the answers in submission order and awards the point with award_daily_point().
create table public.daily_answers (
  id            bigint generated always as identity primary key,
  question_id   uuid not null references public.daily_questions (id) on delete cascade,
  member_id     uuid not null references public.members (id) on delete cascade,
  team_id       uuid not null references public.teams (id) on delete cascade,
  answer        text not null check (char_length(answer) between 1 and 500),
  earned_point  boolean not null default false,
  submitted_at  timestamptz not null default now()
);
create index on public.daily_answers (question_id, submitted_at);

-- Members submit through this function only (no direct INSERT policy), so
-- member, team and timestamp are set by the server and cannot be forged.
create function public.submit_daily_answer(p_question_id uuid, p_answer text)
returns bigint
language plpgsql security definer set search_path = ''
as $$
declare
  v_member  uuid := public.current_member_id();
  v_q       public.daily_questions%rowtype;
  v_team    uuid;
  v_id      bigint;
begin
  if v_member is null then
    raise exception 'Not a registered member';
  end if;

  select * into v_q from public.daily_questions where id = p_question_id;
  if not found or v_q.publish_at > now() then
    raise exception 'Question not available';
  end if;
  if v_q.closes_at is not null and now() > v_q.closes_at then
    raise exception 'Question is closed';
  end if;

  select team_id into v_team
  from public.team_members
  where member_id = v_member and team_type = 'game';
  if v_team is null then
    raise exception 'You are not in a game team';
  end if;

  insert into public.daily_answers (question_id, member_id, team_id, answer)
  values (p_question_id, v_member, v_team, trim(p_answer))
  returning id into v_id;

  return v_id;
end;
$$;

-- Admin marks an answer as correct and awards its team 1 point.
-- Enforces the PBI-5 rules: one point per team per question, 3 teams max.
-- Locks the question row so two admins clicking at once can't exceed 3.
create function public.award_daily_point(p_answer_id bigint)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_a public.daily_answers%rowtype;
begin
  if not public.is_admin() then
    raise exception 'Admins only';
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

-- Undo a mistaken award (removes the point and the highlight).
create function public.revoke_daily_point(p_answer_id bigint)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_a public.daily_answers%rowtype;
begin
  if not public.is_admin() then
    raise exception 'Admins only';
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


-- ---------------------------------------------------------------------
-- Epic 4 — Sermon Q&A
-- The program is static frontend content; each sermon in it has a stable
-- key (e.g. 'day1-evening-sermon') that questions are attached to.
-- ---------------------------------------------------------------------
create table public.sermon_questions (
  id           uuid primary key default gen_random_uuid(),
  sermon_key   text not null check (sermon_key ~ '^[a-z0-9-]{1,60}$'),
  body         text not null check (char_length(body) between 3 and 500),
  status       public.moderation_status not null default 'pending',
  like_count   integer not null default 0,
  created_at   timestamptz not null default now(),
  reviewed_at  timestamptz
);
create index on public.sermon_questions (sermon_key, status, like_count desc, created_at desc);

-- Who asked what lives in a separate admin-only table, so the public
-- question rows carry no author information at all.
create table public.sermon_question_authors (
  question_id  uuid primary key references public.sermon_questions (id) on delete cascade,
  member_id    uuid not null references public.members (id) on delete cascade
);

create table public.sermon_question_likes (
  question_id  uuid not null references public.sermon_questions (id) on delete cascade,
  member_id    uuid not null references public.members (id) on delete cascade default public.current_member_id(),
  created_at   timestamptz not null default now(),
  primary key (question_id, member_id)     -- one like per member per question
);

create function public.submit_sermon_question(p_sermon_key text, p_body text)
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
  insert into public.sermon_questions (sermon_key, body)
  values (p_sermon_key, trim(p_body))
  returning id into v_id;

  insert into public.sermon_question_authors (question_id, member_id)
  values (v_id, v_member);

  return v_id;
end;
$$;

-- Keeps like_count in sync; the row update is what Realtime broadcasts.
create function public.sync_sermon_like_count()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    update public.sermon_questions set like_count = like_count + 1 where id = new.question_id;
  elsif tg_op = 'DELETE' then
    update public.sermon_questions set like_count = like_count - 1 where id = old.question_id;
  end if;
  return null;
end;
$$;

create trigger sermon_question_likes_count
after insert or delete on public.sermon_question_likes
for each row execute function public.sync_sermon_like_count();


-- ---------------------------------------------------------------------
-- Epic 6 — Social wall
-- ---------------------------------------------------------------------
create table public.conference_settings (
  id              boolean primary key default true check (id),   -- single row
  wall_reveal_at  timestamptz not null
);

create function public.wall_revealed()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce((select now() >= wall_reveal_at from public.conference_settings), false)
$$;

create table public.wall_photos (
  id             uuid primary key default gen_random_uuid(),
  member_id      uuid not null references public.members (id) on delete cascade default public.current_member_id(),
  original_path  text not null unique,     -- 'wall-originals' bucket
  blurred_path   text unique,              -- 'wall-blurred' bucket, set on approval
  status         public.moderation_status not null default 'pending',
  created_at     timestamptz not null default now(),
  reviewed_at    timestamptz
);
create index on public.wall_photos (status, created_at desc);


-- ---------------------------------------------------------------------
-- Epic 7 — Push notifications
-- ---------------------------------------------------------------------
create table public.push_subscriptions (
  id          uuid primary key default gen_random_uuid(),
  member_id   uuid not null references public.members (id) on delete cascade default public.current_member_id(),
  endpoint    text not null unique,
  p256dh      text not null,
  auth        text not null,
  created_at  timestamptz not null default now()
);

create table public.notifications (
  id              uuid primary key default gen_random_uuid(),
  title           text not null,
  body            text not null,
  target_team_id  uuid references public.teams (id) on delete set null,   -- null = everyone
  sent_by         uuid references public.members (id) on delete set null default public.current_member_id(),
  sent_at         timestamptz not null default now()
);


-- =====================================================================
-- Auth: restrict sign-up to pre-provisioned phones + link accounts
-- Supabase stores auth.users.phone as digits without '+', so both sides
-- are compared on digits only.
-- =====================================================================

-- Enable in Dashboard → Authentication → Hooks → "Before User Created"
-- and select this function.
create function public.hook_before_user_created(event jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
begin
  if exists (select 1 from public.members
             where regexp_replace(phone, '[^0-9]', '', 'g')
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
grant execute on function public.hook_before_user_created(jsonb) to supabase_auth_admin;
revoke execute on function public.hook_before_user_created(jsonb) from public, anon, authenticated;

create function public.link_member_to_auth_user()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  update public.members
  set auth_user_id = new.id
  where regexp_replace(phone, '[^0-9]', '', 'g') = regexp_replace(coalesce(new.phone, ''), '[^0-9]', '', 'g')
    and coalesce(new.phone, '') <> ''
    and auth_user_id is null;
  return new;
end;
$$;

create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.link_member_to_auth_user();

-- Registration is complete once the member has set a password.
-- The frontend reads members.has_password after OTP verification to decide
-- whether to show the "set your password" screen.
create function public.sync_member_has_password()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  update public.members
  set has_password = coalesce(new.encrypted_password, '') <> ''
  where auth_user_id = new.id;
  return new;
end;
$$;

create trigger on_auth_user_password_changed
after update of encrypted_password on auth.users
for each row execute function public.sync_member_has_password();


-- =====================================================================
-- Row Level Security
-- Everything is "to authenticated": anonymous visitors see nothing.
-- Members and teams are pre-populated before the conference (SQL editor /
-- seed script, which bypass RLS).
-- =====================================================================
alter table public.members                 enable row level security;
alter table public.teams                   enable row level security;
alter table public.team_members            enable row level security;
alter table public.daily_questions         enable row level security;
alter table public.score_events            enable row level security;
alter table public.daily_answers           enable row level security;
alter table public.sermon_questions        enable row level security;
alter table public.sermon_question_authors enable row level security;
alter table public.sermon_question_likes   enable row level security;
alter table public.conference_settings     enable row level security;
alter table public.wall_photos             enable row level security;
alter table public.push_subscriptions      enable row level security;
alter table public.notifications           enable row level security;

-- Members: own row (phone numbers stay private); names go through member_profiles
create policy "members: read own or admin" on public.members
  for select to authenticated
  using (auth_user_id = (select auth.uid()) or (select public.is_admin()));

-- Teams: everyone reads; team members may change only the photo
create policy "teams: read" on public.teams
  for select to authenticated using (true);
create policy "teams: members update photo" on public.teams
  for update to authenticated
  using (public.is_team_member(id) or (select public.is_admin()))
  with check (public.is_team_member(id) or (select public.is_admin()));
revoke update on public.teams from authenticated;
grant update (photo_path) on public.teams to authenticated;

create policy "team_members: read" on public.team_members
  for select to authenticated using (true);

-- Daily questions: visible once published; answers key admin-only
create policy "daily_questions: read published" on public.daily_questions
  for select to authenticated
  using (publish_at <= now() or (select public.is_admin()));
create policy "daily_questions: admin write" on public.daily_questions
  for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

-- Answers: members see their own, admins see all (leaderboard PBI-6)
create policy "daily_answers: read own or admin" on public.daily_answers
  for select to authenticated
  using (member_id = (select public.current_member_id()) or (select public.is_admin()));

-- Scores: everyone reads; admins add/remove points (as +/- events)
create policy "score_events: read" on public.score_events
  for select to authenticated using (true);
create policy "score_events: admin insert" on public.score_events
  for insert to authenticated
  with check ((select public.is_admin()) and source = 'admin');

-- Settings: read-only for members
create policy "conference_settings: read" on public.conference_settings
  for select to authenticated using (true);

-- Sermon questions: public once approved; admins moderate
create policy "sermon_questions: read approved or admin" on public.sermon_questions
  for select to authenticated
  using (status = 'approved' or (select public.is_admin()));
create policy "sermon_questions: admin moderate" on public.sermon_questions
  for update to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));
create policy "sermon_questions: admin delete" on public.sermon_questions
  for delete to authenticated using ((select public.is_admin()));

create policy "sermon_question_authors: admin only" on public.sermon_question_authors
  for select to authenticated using ((select public.is_admin()));

create policy "likes: read own" on public.sermon_question_likes
  for select to authenticated
  using (member_id = (select public.current_member_id()));
create policy "likes: like approved questions" on public.sermon_question_likes
  for insert to authenticated
  with check (
    member_id = (select public.current_member_id())
    and exists (select 1 from public.sermon_questions q
                where q.id = question_id and q.status = 'approved')
  );
create policy "likes: unlike own" on public.sermon_question_likes
  for delete to authenticated
  using (member_id = (select public.current_member_id()));

-- Wall: members post (pending), see approved + their own; admins moderate
create policy "wall_photos: read" on public.wall_photos
  for select to authenticated
  using (status = 'approved'
         or member_id = (select public.current_member_id())
         or (select public.is_admin()));
create policy "wall_photos: submit" on public.wall_photos
  for insert to authenticated
  with check (member_id = (select public.current_member_id()) and status = 'pending');
create policy "wall_photos: admin moderate" on public.wall_photos
  for update to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));
create policy "wall_photos: delete own pending or admin" on public.wall_photos
  for delete to authenticated
  using ((member_id = (select public.current_member_id()) and status = 'pending')
         or (select public.is_admin()));

-- Push: each member manages their own device subscriptions
create policy "push_subscriptions: own" on public.push_subscriptions
  for all to authenticated
  using (member_id = (select public.current_member_id()))
  with check (member_id = (select public.current_member_id()));

create policy "notifications: admin" on public.notifications
  for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));


-- ---------------------------------------------------------------------
-- Grants on views and functions (Supabase grants anon by default)
-- ---------------------------------------------------------------------
revoke all on public.member_profiles, public.team_scores from anon;
grant select on public.member_profiles, public.team_scores to authenticated;

revoke execute on function public.submit_daily_answer(uuid, text)    from public, anon;
revoke execute on function public.submit_sermon_question(text, text) from public, anon;
revoke execute on function public.award_daily_point(bigint)          from public, anon;
revoke execute on function public.revoke_daily_point(bigint)         from public, anon;
grant  execute on function public.submit_daily_answer(uuid, text)    to authenticated;
grant  execute on function public.submit_sermon_question(text, text) to authenticated;
grant  execute on function public.award_daily_point(bigint)          to authenticated;  -- checks is_admin() inside
grant  execute on function public.revoke_daily_point(bigint)         to authenticated;  -- checks is_admin() inside

revoke execute on function public.sync_sermon_like_count()   from public, anon, authenticated;
revoke execute on function public.link_member_to_auth_user() from public, anon, authenticated;
revoke execute on function public.sync_member_has_password() from public, anon, authenticated;


-- =====================================================================
-- Storage buckets & policies
-- Path conventions:
--   team-photos/<team_id>/<file>
--   wall-originals/<member_id>/<file>
--   wall-blurred/<member_id>/<file>   (written by an Edge Function with the service role)
-- =====================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('team-photos',    'team-photos',    false,  5242880, array['image/jpeg', 'image/png', 'image/webp']),
  ('wall-originals', 'wall-originals', false, 10485760, array['image/jpeg', 'image/png', 'image/webp']),
  ('wall-blurred',   'wall-blurred',   false,  2097152, array['image/jpeg', 'image/webp']);

create policy "team-photos: read" on storage.objects
  for select to authenticated
  using (bucket_id = 'team-photos');
create policy "team-photos: team members upload" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'team-photos'
              and public.is_team_member(((storage.foldername(name))[1])::uuid));
create policy "team-photos: team members replace" on storage.objects
  for update to authenticated
  using (bucket_id = 'team-photos'
         and public.is_team_member(((storage.foldername(name))[1])::uuid));

create policy "wall-originals: upload own folder" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'wall-originals'
              and (storage.foldername(name))[1] = (select public.current_member_id())::text);

-- Originals: owner and admins always; everyone else only after the reveal date
create policy "wall-originals: read" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'wall-originals'
    and (
      (storage.foldername(name))[1] = (select public.current_member_id())::text
      or (select public.is_admin())
      or ((select public.wall_revealed())
          and exists (select 1 from public.wall_photos w
                      where w.original_path = name and w.status = 'approved'))
    )
  );

create policy "wall-blurred: read approved" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'wall-blurred'
    and exists (select 1 from public.wall_photos w
                where w.blurred_path = name and w.status = 'approved')
  );


-- =====================================================================
-- Realtime (respects RLS)
-- =====================================================================
alter publication supabase_realtime add table public.score_events, public.sermon_questions, public.daily_answers;
