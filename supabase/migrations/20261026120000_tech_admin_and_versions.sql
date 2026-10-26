-- =====================================================================
-- Technical admins (a step above admins) and app versions / "What's new"
-- =====================================================================


-- ---------------------------------------------------------------------
-- Technical admins: everything an admin does, plus the AI section (later).
-- A technical admin is always an admin, so is_admin() and every existing
-- policy keep working unchanged. Only a technical admin may grant or
-- remove the role, and the app always keeps one active technical admin.
-- ---------------------------------------------------------------------
alter table public.members
  add column is_tech_admin boolean not null default false,
  add constraint members_tech_admin_is_admin check (not is_tech_admin or is_admin);

create function public.is_tech_admin()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce(
    (select is_tech_admin from public.members where auth_user_id = auth.uid() and is_active),
    false
  )
$$;

create or replace function public.members_before_write()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_relink boolean := tg_op = 'INSERT';
begin
  -- No longer an admin: no longer a technical admin either.
  if not new.is_admin then
    new.is_tech_admin := false;
  end if;

  -- Only technical admins grant the role, or change a technical admin's rights.
  if auth.uid() is not null and not public.is_tech_admin()
     and (new.is_tech_admin is distinct from (tg_op = 'UPDATE' and old.is_tech_admin)
          or (tg_op = 'UPDATE' and old.is_tech_admin
              and (new.is_admin, new.is_active) is distinct from (old.is_admin, old.is_active))) then
    raise exception 'Only technical admins can change this' using errcode = '42501';
  end if;

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

    -- Nor without an active technical admin.
    if old.is_tech_admin and old.is_active and not (new.is_tech_admin and new.is_active)
       and not exists (select 1 from public.members
                       where is_tech_admin and is_active and id <> old.id) then
      raise exception 'There must be at least one active technical admin';
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

grant insert (is_tech_admin) on public.members to authenticated;
grant update (is_tech_admin) on public.members to authenticated;

-- The first technical admin.
update public.members
set is_admin = true, is_tech_admin = true
where regexp_replace(phone, '[^0-9]', '', 'g') = '33666560265';


-- ---------------------------------------------------------------------
-- App versions and "What's new". One version per change shipped (fix →
-- patch, update or new feature → minor); each version lists its entries by
-- type. Every member reads the published, visible entries; technical admins
-- read and write everything. last_seen_version drives the "new" badge.
-- ---------------------------------------------------------------------
create table public.app_versions (
  id          uuid primary key default gen_random_uuid(),
  version     text not null unique check (version ~ '^[0-9]+\.[0-9]+\.[0-9]+$'),
  released_at timestamptz not null default now()
);

create table public.changelog_entries (
  id         uuid primary key default gen_random_uuid(),
  version_id uuid not null references public.app_versions (id) on delete cascade,
  type       text not null check (type in ('bug_fix', 'update', 'feature')),
  title_fr   text not null check (char_length(trim(title_fr)) between 1 and 200),
  body_fr    text,
  title_en   text,
  body_en    text,
  hidden     boolean not null default false,  -- technical change, kept out of "What's new"
  published  boolean not null default true,   -- false while the technical admin reviews it
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);
create index changelog_entries_version_id_idx on public.changelog_entries (version_id);

alter table public.members add column last_seen_version text;

alter table public.app_versions enable row level security;
alter table public.changelog_entries enable row level security;

create policy "app_versions: read" on public.app_versions
  for select to authenticated using ((select public.is_member()));
create policy "app_versions: tech admin write" on public.app_versions
  for all to authenticated
  using ((select public.is_tech_admin())) with check ((select public.is_tech_admin()));

create policy "changelog_entries: read published" on public.changelog_entries
  for select to authenticated
  using (((select public.is_member()) and published and not hidden) or (select public.is_tech_admin()));
create policy "changelog_entries: tech admin write" on public.changelog_entries
  for all to authenticated
  using ((select public.is_tech_admin())) with check ((select public.is_tech_admin()));

revoke all on public.app_versions, public.changelog_entries from anon;

-- The caller has seen every version up to the given one ("What's new" opened).
create function public.mark_whats_new_seen(p_version text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not exists (select 1 from public.app_versions where version = p_version) then
    raise exception 'Unknown version' using errcode = 'PT404';
  end if;
  update public.members set last_seen_version = p_version
  where auth_user_id = auth.uid();
end;
$$;

revoke execute on function public.is_tech_admin()              from public, anon;
grant  execute on function public.is_tech_admin()              to authenticated;
revoke execute on function public.mark_whats_new_seen(text)    from public, anon;
grant  execute on function public.mark_whats_new_seen(text)    to authenticated;

-- The first version.
with v as (
  insert into public.app_versions (version, released_at) values ('1.0.0', now()) returning id
)
insert into public.changelog_entries (version_id, type, title_fr, body_fr, title_en, body_en, sort_order)
select v.id, e.type, e.title_fr, e.body_fr, e.title_en, e.body_en, e.sort_order
from v, (values
  ('feature', 'Lancement de MaConference',
   'Programme, équipes, Grand Jeu, ateliers, chants, mur photo et question du jour : toute la conférence dans une seule app.',
   'MaConference launch',
   'Program, teams, Grand Jeu, workshops, chants, photo wall and question of the day: the whole conference in one app.', 1),
  ('feature', 'Quoi de neuf ?',
   'Retrouve ici les nouveautés et corrections de chaque version de l''app.',
   'What''s new',
   'Find the new features and fixes of every version of the app here.', 2)
) as e (type, title_fr, body_fr, title_en, body_en, sort_order);
