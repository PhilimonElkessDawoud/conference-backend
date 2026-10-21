-- =====================================================================
-- Migration: Grand Jeu (treasure hunt with stations) — PBI-19
-- Applies on top of 20261016130000_slot_types.sql.
--
-- Model
--   stations             the physical stations (name + location), shared
--   team_stations        each game team's route: order, opponent, status,
--                        and the clue once revealed — readable by that team
--   team_station_secrets the code + clue per team and station — admins only
--   team_bonus_clues     one optional bonus clue per team — readable by the
--                        team only once an admin reveals it
--   station_code_attempts log of codes entered (admins only), also used to
--                        slow down guessing
--
-- Codes and clues are kept out of team_stations so that members can never
-- read a code, nor a clue before earning it. The bonus clue is NOT stored in
-- teams because every member can read the teams table.
-- =====================================================================

create type public.station_status as enum ('non_visitee', 'gagnee', 'terminee');
-- non_visitee = not done yet · gagnee = code found, clue revealed
-- terminee = done without the clue (marked by the team itself)


-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------
create table public.stations (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique check (char_length(trim(name)) between 1 and 80),
  location    text not null check (char_length(trim(location)) between 1 and 120),
  created_at  timestamptz not null default now()
);

create table public.team_stations (
  id                  uuid primary key default gen_random_uuid(),
  team_id             uuid not null,
  team_type           public.team_type not null default 'game' check (team_type = 'game'),
  station_id          uuid not null references public.stations (id) on delete cascade,
  visit_order         smallint not null check (visit_order between 1 and 50),
  opponent_team_id    uuid,                                    -- null = no opposing team
  opponent_team_type  public.team_type not null default 'game' check (opponent_team_type = 'game'),
  status              public.station_status not null default 'non_visitee',
  revealed_clue       text,                                    -- filled by trigger when status = 'gagnee'
  finished_at         timestamptz,
  solved_by           uuid references public.members (id) on delete set null,
  created_at          timestamptz not null default now(),
  foreign key (team_id, team_type) references public.teams (id, type) on delete cascade,
  foreign key (opponent_team_id, opponent_team_type) references public.teams (id, type) on delete set null (opponent_team_id),
  unique (team_id, station_id),
  -- deferrable so set_team_route() can swap two stations' orders in one go
  constraint team_stations_team_order_key unique (team_id, visit_order) deferrable initially immediate,
  check (opponent_team_id is null or opponent_team_id <> team_id)
);
create index on public.team_stations (team_id, visit_order);

create table public.team_station_secrets (
  team_station_id  uuid primary key references public.team_stations (id) on delete cascade,
  code             text not null check (char_length(trim(code)) between 1 and 50),
  clue             text not null check (char_length(trim(clue)) between 1 and 1000)
);

create table public.team_bonus_clues (
  team_id      uuid primary key,
  team_type    public.team_type not null default 'game' check (team_type = 'game'),
  clue         text not null check (char_length(trim(clue)) between 1 and 1000),
  revealed     boolean not null default false,
  revealed_at  timestamptz,
  foreign key (team_id, team_type) references public.teams (id, type) on delete cascade
);

create table public.station_code_attempts (
  id               bigint generated always as identity primary key,
  team_station_id  uuid not null references public.team_stations (id) on delete cascade,
  member_id        uuid references public.members (id) on delete set null,
  attempted_code   text not null,
  success          boolean not null,
  created_at       timestamptz not null default now()
);
create index on public.station_code_attempts (team_station_id, created_at);


-- ---------------------------------------------------------------------
-- Keeps the revealed clue consistent with the status, on every insert or
-- update, whoever makes it (a member through the RPCs, or an admin editing
-- any field):
--   gagnee      -> clue copied from the secrets
--   terminee    -> no clue
--   non_visitee -> no clue, finished_at and solved_by cleared
-- When the status changes to gagnee/terminee, finished_at is set to now()
-- (admins can still edit finished_at afterwards). revealed_clue itself is
-- never edited directly: edit the clue in team_station_secrets instead.
-- ---------------------------------------------------------------------
create function public.team_stations_sync_status()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_status_changed boolean := tg_op = 'INSERT' or new.status is distinct from old.status;
begin
  if new.status = 'gagnee' then
    select s.clue into new.revealed_clue
    from public.team_station_secrets s where s.team_station_id = new.id;
    if new.revealed_clue is null then
      raise exception 'This station has no clue yet: add its code and clue first';
    end if;
  else
    new.revealed_clue := null;
  end if;

  if new.status = 'non_visitee' then
    new.finished_at := null;
    new.solved_by := null;
  elsif v_status_changed then
    new.finished_at := now();
  end if;
  return new;
end;
$$;

create trigger team_stations_sync_status
before insert or update on public.team_stations
for each row execute function public.team_stations_sync_status();

-- If an admin edits the clue of a station already won, update what the team sees.
create function public.team_station_secrets_sync_clue()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  update public.team_stations
  set revealed_clue = new.clue
  where id = new.team_station_id and status = 'gagnee';
  return null;
end;
$$;

create trigger team_station_secrets_sync_clue
after update of clue on public.team_station_secrets
for each row execute function public.team_station_secrets_sync_clue();

-- Revealing the bonus clue stamps the time; hiding it clears it.
-- Admins can edit the clue at any time, revealed or not.
create function public.team_bonus_clues_stamp()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  new.revealed_at := case when new.revealed then coalesce(new.revealed_at, now()) end;
  return new;
end;
$$;

create trigger team_bonus_clues_stamp
before insert or update on public.team_bonus_clues
for each row execute function public.team_bonus_clues_stamp();


-- ---------------------------------------------------------------------
-- Member: enter the code found at a station.
--   POST /rest/v1/rpc/submit_station_code  {"p_station_id": "...", "p_code": "..."}
-- The team is the caller's game team. Right code -> status 'gagnee' and the
-- clue is returned. Codes are compared ignoring case and surrounding spaces.
-- At most 5 wrong codes per team and station in 5 minutes (anti-guessing).
-- Locked until every earlier station of the route is gagnee or terminee.
-- ---------------------------------------------------------------------
create function public.submit_station_code(p_station_id uuid, p_code text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_member  uuid := public.current_member_id();
  v_team    uuid;
  v_ts      public.team_stations%rowtype;
  v_code    text;
  v_ok      boolean;
begin
  if v_member is null then
    raise exception 'Not a registered member' using errcode = '42501';
  end if;

  select team_id into v_team
  from public.team_members where member_id = v_member and team_type = 'game';
  if v_team is null then
    raise exception 'You are not in a game team';
  end if;

  select * into v_ts
  from public.team_stations
  where team_id = v_team and station_id = p_station_id
  for update;
  if not found then
    raise exception 'This station is not on your team''s route';
  end if;

  if v_ts.status = 'gagnee' then
    return jsonb_build_object('status', 'gagnee', 'clue', v_ts.revealed_clue, 'already', true);
  end if;
  if v_ts.status = 'terminee' then
    raise exception 'This station is already completed for your team';
  end if;

  if exists (select 1 from public.team_stations p
             where p.team_id = v_team and p.visit_order < v_ts.visit_order
               and p.status = 'non_visitee') then
    raise exception 'This station is locked: finish the previous station first';
  end if;

  if (select count(*) from public.station_code_attempts
      where team_station_id = v_ts.id and not success
        and created_at > now() - interval '5 minutes') >= 5 then
    raise exception 'Too many wrong codes: wait a few minutes before trying again';
  end if;

  select code into v_code from public.team_station_secrets where team_station_id = v_ts.id;
  if v_code is null then
    raise exception 'This station is not ready yet';
  end if;

  v_ok := lower(trim(coalesce(p_code, ''))) = lower(trim(v_code));

  insert into public.station_code_attempts (team_station_id, member_id, attempted_code, success)
  values (v_ts.id, v_member, left(coalesce(p_code, ''), 50), v_ok);

  if not v_ok then
    return jsonb_build_object('status', 'non_visitee', 'correct', false);
  end if;

  update public.team_stations
  set status = 'gagnee', solved_by = v_member
  where id = v_ts.id
  returning * into v_ts;

  return jsonb_build_object('status', 'gagnee', 'correct', true, 'clue', v_ts.revealed_clue);
end;
$$;


-- ---------------------------------------------------------------------
-- Member: mark a station as completed without the clue (lost the challenge).
--   POST /rest/v1/rpc/complete_station  {"p_station_id": "..."}
-- Only from 'non_visitee', and only once the station is unlocked.
-- A team can't undo it: an admin can reset it.
-- ---------------------------------------------------------------------
create function public.complete_station(p_station_id uuid)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_member  uuid := public.current_member_id();
  v_team    uuid;
  v_ts      public.team_stations%rowtype;
begin
  if v_member is null then
    raise exception 'Not a registered member' using errcode = '42501';
  end if;

  select team_id into v_team
  from public.team_members where member_id = v_member and team_type = 'game';
  if v_team is null then
    raise exception 'You are not in a game team';
  end if;

  select * into v_ts
  from public.team_stations
  where team_id = v_team and station_id = p_station_id
  for update;
  if not found then
    raise exception 'This station is not on your team''s route';
  end if;
  if v_ts.status = 'gagnee' then
    raise exception 'This station is already won by your team';
  end if;
  if v_ts.status = 'terminee' then
    return jsonb_build_object('status', 'terminee', 'already', true);
  end if;

  if exists (select 1 from public.team_stations p
             where p.team_id = v_team and p.visit_order < v_ts.visit_order
               and p.status = 'non_visitee') then
    raise exception 'This station is locked: finish the previous station first';
  end if;

  update public.team_stations
  set status = 'terminee', solved_by = v_member
  where id = v_ts.id;

  return jsonb_build_object('status', 'terminee');
end;
$$;


-- ---------------------------------------------------------------------
-- Computed field: is the station unlocked for its team?
--   GET /rest/v1/team_stations?select=visit_order,status,is_unlocked,...
-- true when every earlier station of the route is gagnee or terminee.
-- ---------------------------------------------------------------------
create function public.is_unlocked(public.team_stations)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select not exists (
    select 1 from public.team_stations p
    where p.team_id = $1.team_id
      and p.visit_order < $1.visit_order
      and p.status = 'non_visitee');
$$;


-- ---------------------------------------------------------------------
-- Admin: reorder a team's route in one call.
--   POST /rest/v1/rpc/set_team_route
--   {"p_team_id": "...", "p_station_ids": ["<1st station>", "<2nd>", ...]}
-- The list must contain exactly the stations already on the route; each
-- gets the order of its position in the list (1, 2, 3...).
-- (To change one station's order to a free number, a plain PATCH is enough.)
-- ---------------------------------------------------------------------
create function public.set_team_route(p_team_id uuid, p_station_ids uuid[])
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'Admins only' using errcode = '42501';
  end if;

  if (select count(*) from public.team_stations where team_id = p_team_id)
       <> coalesce(cardinality(p_station_ids), 0)
     or (select count(distinct x) from unnest(p_station_ids) x)
       <> cardinality(p_station_ids)
     or exists (select 1 from unnest(p_station_ids) x
                where not exists (select 1 from public.team_stations
                                  where team_id = p_team_id and station_id = x)) then
    raise exception 'The list must contain each station of this team''s route exactly once'
      using errcode = '22023';
  end if;

  set constraints public.team_stations_team_order_key deferred;

  update public.team_stations ts
  set visit_order = o.pos
  from unnest(p_station_ids) with ordinality as o(station_id, pos)
  where ts.team_id = p_team_id and ts.station_id = o.station_id;
end;
$$;


-- =====================================================================
-- Row Level Security
-- =====================================================================
alter table public.stations              enable row level security;
alter table public.team_stations         enable row level security;
alter table public.team_station_secrets  enable row level security;
alter table public.team_bonus_clues      enable row level security;
alter table public.station_code_attempts enable row level security;

-- Stations (names + places): every member reads; admins manage
create policy "stations: read" on public.stations
  for select to authenticated using ((select public.is_member()));
create policy "stations: admin write" on public.stations
  for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

-- Routes: a team reads its own; admins read and manage all.
-- Members never write directly: they go through submit_station_code()
-- and complete_station().
create policy "team_stations: read own team or admin" on public.team_stations
  for select to authenticated
  using (public.is_team_member(team_id) or (select public.is_admin()));
create policy "team_stations: admin write" on public.team_stations
  for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

-- Codes and clues: admins only
create policy "team_station_secrets: admin only" on public.team_station_secrets
  for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

-- Bonus clue: the team sees it only once revealed; admins manage
create policy "team_bonus_clues: team once revealed, or admin" on public.team_bonus_clues
  for select to authenticated
  using ((revealed and public.is_team_member(team_id)) or (select public.is_admin()));
create policy "team_bonus_clues: admin write" on public.team_bonus_clues
  for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

-- Attempts log: admins only (inserted by submit_station_code)
create policy "station_code_attempts: admin read" on public.station_code_attempts
  for select to authenticated using ((select public.is_admin()));
revoke insert, update, delete on public.station_code_attempts from anon, authenticated;


-- ---------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------
revoke execute on function public.submit_station_code(uuid, text) from public, anon;
revoke execute on function public.complete_station(uuid)          from public, anon;
grant  execute on function public.submit_station_code(uuid, text) to authenticated;
grant  execute on function public.complete_station(uuid)          to authenticated;
revoke execute on function public.is_unlocked(public.team_stations) from public, anon;
grant  execute on function public.is_unlocked(public.team_stations) to authenticated;
revoke execute on function public.set_team_route(uuid, uuid[])     from public, anon;
grant  execute on function public.set_team_route(uuid, uuid[])     to authenticated;

revoke execute on function public.team_stations_sync_status()      from public, anon, authenticated;
revoke execute on function public.team_station_secrets_sync_clue() from public, anon, authenticated;
revoke execute on function public.team_bonus_clues_stamp()         from public, anon, authenticated;


-- ---------------------------------------------------------------------
-- Realtime: a clue revealed by one member appears on teammates' phones,
-- and a revealed bonus clue appears on the team's phones.
-- ---------------------------------------------------------------------
alter publication supabase_realtime add table public.team_stations, public.team_bonus_clues;
