-- =====================================================================
-- Migration: the places of the site, managed by the admins
-- Applies on top of 20261023170000_meeting_url.sql.
--
-- Until now the places were written in the frontend, and a slot's place
-- (slots.place) and a grand jeu station's location (stations.location)
-- were free text. The admins now manage the list from the app's settings
-- (add, rename, change, delete):
--   GET    /rest/v1/places?select=*
--   POST   /rest/v1/places              {"name": "Salle Emojis", "kind": "ROOM", "floor": "rdc"}
--   PATCH  /rest/v1/places?id=eq.<uuid> {"name": "Salle Bourbon (Emojis)"}
--   DELETE /rest/v1/places?id=eq.<uuid>
--
-- slots.place and stations.location now reference places.name:
--   * renaming a place renames it in the planning and the grand jeu
--     (on update cascade);
--   * a place still used by a slot or a station cannot be deleted
--     (on delete restrict, SQLSTATE 23503).
--
-- plan_id: the shape or marker of the site plan drawn by the frontend
-- (its own place ids), null for a place that is not on the plan.
-- =====================================================================

create table public.places (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique check (char_length(trim(name)) between 1 and 120),
  kind        text not null default 'ROOM' check (kind in ('ROOM', 'FACILITY', 'BUILDING', 'OUTDOOR')),
  number      integer check (number between 1 and 999),
  floor       text check (char_length(floor) <= 40),
  plan_id     integer unique,
  created_at  timestamptz not null default now()
);

-- The places of the site plan that a slot can take place in, then the
-- ground floor rooms of the grand jeu's plan.
insert into public.places (name, kind, number, floor, plan_id) values
  ('Parking', 'OUTDOOR', null, null, 8),
  ('Grand escalier', 'OUTDOOR', null, null, 9),
  ('Podium', 'OUTDOOR', null, null, 10),
  ('Cocorico', 'BUILDING', null, null, 11),
  ('Plan d''eau', 'OUTDOOR', null, null, 12),
  ('Prairie ouest', 'OUTDOOR', null, null, 13),
  ('Prairie est', 'OUTDOOR', null, null, 14),
  ('Verger et jardins partagés', 'OUTDOOR', null, null, 15),
  ('Terrain bitumé', 'OUTDOOR', null, null, 16),
  ('Orangerie', 'BUILDING', null, null, 17),
  ('Chalet', 'BUILDING', null, null, 18),
  ('Bassin aux poissons rouges', 'OUTDOOR', null, null, 19),
  ('Espace et parking Saint-Joseph (communal)', 'OUTDOOR', null, null, 20),
  ('Accueil', 'FACILITY', null, null, 21),
  ('Restaurant', 'ROOM', 1, 'rdc', 29),
  ('Cafétéria / distributeur de boissons', 'ROOM', 2, 'rdc', 30),
  ('Oratoire / salle Pologne', 'ROOM', 3, 'rdc / 1er étage', 31),
  ('Salle Sénégal', 'ROOM', 5, null, 33),
  ('Salles Éthiopie, sanitaires d''été', 'ROOM', 6, 'rez de jardin', 34),
  ('Chambres Nigéria', 'ROOM', 7, null, 35),
  ('Musée Spiritain des Arts Africains', 'ROOM', 8, null, 36),
  ('Sanctuaire Saint-Joseph', 'ROOM', 9, '1er étage', 37),
  ('Chapelle de la Sainte-Famille', 'ROOM', 10, '1er étage', 38),
  ('Salle Mexique', 'ROOM', 11, '1er étage', 39),
  ('Salle Brésil', 'ROOM', 12, 'rdc', 40),
  ('Dortoirs Paraguay', 'ROOM', 13, '1er étage', 41),
  ('Chambres Antilles', 'ROOM', 14, '2e étage', 42),
  ('Chambres Vietnam', 'ROOM', 16, '1er étage', 44),
  ('Salle Madagascar', 'ROOM', 17, 'rdc', 45),
  ('Salle Bourbon', 'ROOM', 18, 'rdc', 46),
  ('Salle Maurice', 'ROOM', 19, 'rdc', 47),
  ('Salle Papouasie', 'ROOM', 20, '1er étage', 48),
  ('Salle Pakistan', 'ROOM', 21, 'rez de jardin', 49),
  ('Salle du Méridien', 'ROOM', null, 'rdc', null),
  ('Salle à manger', 'ROOM', null, 'rdc', null),
  ('Salle de repas', 'ROOM', null, 'rdc', null),
  ('Salle Portugal', 'ROOM', null, 'rdc', null),
  ('Libermann', 'ROOM', null, 'rdc', null),
  ('Sacristie', 'ROOM', null, 'rdc', null),
  ('Parloir', 'ROOM', null, 'rdc', null),
  ('Bureau', 'ROOM', null, 'rdc', null),
  ('Cuisine', 'ROOM', null, 'rdc', null),
  ('Relais cuisine (salle Bunker)', 'ROOM', null, 'rdc', null),
  ('Préau', 'OUTDOOR', null, 'rdc', null)
on conflict (name) do nothing;

-- The places already typed in the planning and the grand jeu stay valid.
insert into public.places (name)
select distinct trim(place) from public.slots
union
select distinct trim(location) from public.stations
on conflict (name) do nothing;

update public.slots set place = trim(place) where place <> trim(place);
update public.stations set location = trim(location) where location <> trim(location);

alter table public.slots
  add constraint slots_place_fkey foreign key (place)
    references public.places (name) on update cascade on delete restrict;
alter table public.stations
  add constraint stations_location_fkey foreign key (location)
    references public.places (name) on update cascade on delete restrict;
create index on public.slots (place);
create index on public.stations (location);

alter table public.places enable row level security;
create policy "places: read" on public.places
  for select to authenticated using ((select public.is_member()));
create policy "places: admin write" on public.places
  for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

alter publication supabase_realtime add table public.places;
