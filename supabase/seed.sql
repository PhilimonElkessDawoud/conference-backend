-- =====================================================================
-- seed.sql — dummy data for local development & API testing
-- Runs automatically on `supabase start` / `supabase db reset`.
--
-- All phone numbers are DUMMY numbers in the +33 6 39 98 xx xx range,
-- reserved for fiction, so no real person receives an SMS. Map them to
-- fixed OTP codes in config.toml ([auth.sms.test_otp]) to log in as them.
-- To test real SMS delivery later, replace the "Admin Réel" / "Membre Réel"
-- numbers with real ones (E.164, e.g. +33612345678).
--
-- Program slots and dates are relative to today, so after every
-- `db reset` there is a live daily question and today's program.
-- =====================================================================


-- ---------------------------------------------------------------------
-- Members
-- ---------------------------------------------------------------------
insert into public.members (full_name, phone, is_admin) values
  -- Swap for real numbers to test real SMS delivery ----------------
  ('Admin Réel',        '+33639980013', true),
  ('Membre Réel',       '+33639980014', false),

  -- Dummy members ---------------------------------------------------
  ('Marc Hanna',        '+33639980001', true),    -- dummy admin
  ('Mariam Girgis',     '+33639980002', false),
  ('Youssef Tadros',    '+33639980003', false),
  ('Sara Mikhail',      '+33639980004', false),
  ('Bishoy Farag',      '+33639980005', false),
  ('Nardine Ibrahim',   '+33639980006', false),
  ('Kirollos Shenouda', '+33639980007', false),
  ('Marina Aziz',       '+33639980008', false),
  ('Mina Boutros',      '+33639980009', false),
  ('Irini Sobhy',       '+33639980010', false),
  ('Abanoub Ramzy',     '+33639980011', false),
  ('Verena Nashed',     '+33639980012', false),
  ('Georges Wassef',    '+33639980015', false);   -- deactivated below

-- A deactivated member: cannot register or see any data (PBI-15)
update public.members set is_active = false where full_name = 'Georges Wassef';

-- Optional fields: church and age (left empty for the others)
update public.members m set church = v.church, age = v.age
from (values
  ('Mariam Girgis',     'Saint-Marc de Lyon',     17),
  ('Youssef Tadros',    'Saint-Marc de Lyon',     19),
  ('Sara Mikhail',      'Saint-Georges de Paris', 16),
  ('Bishoy Farag',      'Saint-Georges de Paris', null),
  ('Kirollos Shenouda', null,                     22),
  ('Marc Hanna',        'Saint-Marc de Lyon',     28)
) as v(full_name, church, age)
where m.full_name = v.full_name;

-- Profile photos (database paths only; upload files at these paths to see them)
update public.members set avatar_path = id || '/avatar.webp'
where full_name in ('Mariam Girgis', 'Sara Mikhail', 'Marc Hanna');


-- ---------------------------------------------------------------------
-- Teams
-- ---------------------------------------------------------------------
insert into public.teams (name, type) values
  ('Saint Mark',      'game'),
  ('Saint George',    'game'),
  ('Saint Mina',      'game'),
  ('Saint Demiana',   'game'),
  ('Atelier Louange', 'workshop'),
  ('Atelier Bible',   'workshop'),
  ('Atelier Service', 'workshop');


-- ---------------------------------------------------------------------
-- Team membership: 1 game team + 1 workshop team each.
-- Admins are left without teams.
-- ---------------------------------------------------------------------
insert into public.team_members (team_id, team_type, member_id)
select t.id, t.type, m.id
from (values
  ('Membre Réel',       'Saint Mark',    'Atelier Louange'),
  ('Mariam Girgis',     'Saint Mark',    'Atelier Louange'),
  ('Youssef Tadros',    'Saint Mark',    'Atelier Bible'),
  ('Sara Mikhail',      'Saint George',  'Atelier Bible'),
  ('Bishoy Farag',      'Saint George',  'Atelier Service'),
  ('Nardine Ibrahim',   'Saint George',  'Atelier Louange'),
  ('Kirollos Shenouda', 'Saint Mina',    'Atelier Service'),
  ('Marina Aziz',       'Saint Mina',    'Atelier Bible'),
  ('Mina Boutros',      'Saint Mina',    'Atelier Louange'),
  ('Irini Sobhy',       'Saint Demiana', 'Atelier Service'),
  ('Abanoub Ramzy',     'Saint Demiana', 'Atelier Bible'),
  ('Verena Nashed',     'Saint Demiana', 'Atelier Service')
) as v(member_name, game_team, workshop_team)
join public.members m on m.full_name = v.member_name
join public.teams   t on (t.name = v.game_team     and t.type = 'game')
                      or (t.name = v.workshop_team and t.type = 'workshop');


-- ---------------------------------------------------------------------
-- Settings: wall reveal in 3 days (edit to test before/after reveal)
-- ---------------------------------------------------------------------
insert into public.conference_settings (wall_reveal_at)
values (now() + interval '3 days');


-- ---------------------------------------------------------------------
-- Daily questions (relative to now(), so there's always a live one).
-- Fixed UUIDs make them easy to call from Postman / tests.
-- ---------------------------------------------------------------------
insert into public.daily_questions (id, body, publish_at, closes_at) values
  ('00000000-0000-0000-0000-00000000d001',
   'Combien de livres compte le Nouveau Testament ?',
   now() - interval '1 day', now() - interval '1 day' + interval '2 hours'),  -- yesterday, closed
  ('00000000-0000-0000-0000-00000000d002',
   'Qui a écrit le livre de l''Apocalypse ?',
   now() - interval '10 minutes', null),                                       -- live now
  ('00000000-0000-0000-0000-00000000d003',
   'Dans quelle ville est né saint Marc ?',
   now() + interval '1 day', null);                                            -- tomorrow, hidden


-- ---------------------------------------------------------------------
-- Daily answers — yesterday: several attempts, 3 teams awarded
-- ---------------------------------------------------------------------
insert into public.daily_answers (question_id, member_id, team_id, answer, earned_point, submitted_at)
select q.id, m.id, tm.team_id, v.answer, v.earned, q.publish_at + v.after
from (values
  ('Mariam Girgis',     '25', false, interval '12 seconds'),
  ('Mariam Girgis',     '27', true,  interval '20 seconds'),
  ('Sara Mikhail',      '27', true,  interval '31 seconds'),
  ('Youssef Tadros',    '27', false, interval '35 seconds'),  -- same team as Mariam: no point
  ('Kirollos Shenouda', '26', false, interval '40 seconds'),
  ('Kirollos Shenouda', '27', true,  interval '52 seconds'),
  ('Irini Sobhy',       '27', false, interval '58 seconds')   -- 4th team: too late
) as v(member_name, answer, earned, after)
join public.members m       on m.full_name = v.member_name
join public.team_members tm on tm.member_id = m.id and tm.team_type = 'game'
cross join public.daily_questions q
where q.id = '00000000-0000-0000-0000-00000000d001';

-- Today's live question: a few attempts, nothing awarded yet
insert into public.daily_answers (question_id, member_id, team_id, answer, submitted_at)
select '00000000-0000-0000-0000-00000000d002', m.id, tm.team_id, v.answer, now() - v.ago
from (values
  ('Bishoy Farag',  'Saint Paul', interval '8 minutes'),
  ('Bishoy Farag',  'Saint Jean', interval '7 minutes'),
  ('Marina Aziz',   'Saint Jean', interval '6 minutes'),
  ('Abanoub Ramzy', 'Jean',       interval '5 minutes')
) as v(member_name, answer, ago)
join public.members m       on m.full_name = v.member_name
join public.team_members tm on tm.member_id = m.id and tm.team_type = 'game';


-- ---------------------------------------------------------------------
-- Score events: daily-question points (match the answers above)
-- + manual admin points from games
-- ---------------------------------------------------------------------
insert into public.score_events (team_id, delta, reason, source, daily_question_id, created_by, created_at)
select a.team_id, 1, 'Daily question', 'daily_question', a.question_id,
       (select id from public.members where full_name = 'Marc Hanna'),
       a.submitted_at + interval '5 minutes'
from public.daily_answers a
where a.earned_point;

insert into public.score_events (team_id, delta, reason, source, created_by, created_at)
select t.id, v.delta, v.reason, 'admin',
       (select id from public.members where full_name = 'Marc Hanna'), now() - v.ago
from (values
  ('Saint Mark',    10, 'Jeu de piste — 1ère place', interval '20 hours'),
  ('Saint Mina',     7, 'Jeu de piste — 2ème place', interval '20 hours'),
  ('Saint George',   5, 'Jeu de piste — 3ème place', interval '20 hours'),
  ('Saint Demiana',  3, 'Jeu de piste — 4ème place', interval '20 hours'),
  ('Saint Mina',    -2, 'Pénalité — retard',         interval '4 hours')
) as v(team_name, delta, reason, ago)
join public.teams t on t.name = v.team_name and t.type = 'game';


-- ---------------------------------------------------------------------
-- Program slots (PBI-7, PBI-16): today and tomorrow, no overlaps.
-- Fixed UUIDs make them easy to call from Postman / tests.
-- ---------------------------------------------------------------------
insert into public.slots (id, title, type, slot_date, start_time, end_time, place) values
  ('00000000-0000-0000-0000-00000000b001', 'Accueil & installation', 'welcome',  current_date,     '14:00', '15:30', 'Hall d''entrée'),
  ('00000000-0000-0000-0000-00000000b002', 'Ateliers — session 1',    'workshop', current_date,     '15:30', '17:00', 'Salles A, B, C'),
  ('00000000-0000-0000-0000-00000000b003', 'Jeu de piste',            'game',     current_date,     '17:00', '18:30', 'Parc'),
  ('00000000-0000-0000-0000-00000000b004', 'Dîner',                   'meal',     current_date,     '19:00', '20:00', 'Réfectoire'),
  ('00000000-0000-0000-0000-00000000b005', 'Sermon du soir',          'sermon',   current_date,     '20:15', '21:30', 'Grande salle'),
  ('00000000-0000-0000-0000-00000000b006', 'Chants du matin',        'chants',   current_date + 1, '08:30', '09:00', 'Grande salle'),
  ('00000000-0000-0000-0000-00000000b007', 'Sermon du matin',         'sermon',   current_date + 1, '09:00', '10:15', 'Grande salle'),
  ('00000000-0000-0000-0000-00000000b008', 'Ateliers — session 2',    'workshop', current_date + 1, '10:30', '12:00', 'Salles A, B, C');

insert into public.slot_teams (slot_id, team_id)
select v.slot_id::uuid, t.id
from (values
  ('00000000-0000-0000-0000-00000000b002', 'Atelier Louange'),
  ('00000000-0000-0000-0000-00000000b002', 'Atelier Bible'),
  ('00000000-0000-0000-0000-00000000b002', 'Atelier Service'),
  ('00000000-0000-0000-0000-00000000b003', 'Saint Mark'),
  ('00000000-0000-0000-0000-00000000b003', 'Saint George'),
  ('00000000-0000-0000-0000-00000000b008', 'Atelier Bible'),
  ('00000000-0000-0000-0000-00000000b008', 'Atelier Service')
) as v(slot_id, team_name)
join public.teams t on t.name = v.team_name;


-- ---------------------------------------------------------------------
-- Sermon Q&A, attached to the sermon slots above
-- ---------------------------------------------------------------------
insert into public.sermon_questions (id, slot_id, body, status, created_at, reviewed_at) values
  ('00000000-0000-0000-0000-00000000a001', '00000000-0000-0000-0000-00000000b005',
   'Comment rester fidèle dans la prière quand on ne ressent rien ?', 'approved', now() - interval '5 hours', now() - interval '4 hours'),
  ('00000000-0000-0000-0000-00000000a002', '00000000-0000-0000-0000-00000000b005',
   'Quelle est la différence entre la foi et l''espérance ?',          'approved', now() - interval '5 hours', now() - interval '4 hours'),
  ('00000000-0000-0000-0000-00000000a003', '00000000-0000-0000-0000-00000000b005',
   'Comment pardonner à quelqu''un qui ne s''excuse pas ?',            'approved', now() - interval '4 hours', now() - interval '3 hours'),
  ('00000000-0000-0000-0000-00000000a004', '00000000-0000-0000-0000-00000000b005',
   'Question hors sujet',                                                'rejected', now() - interval '4 hours', now() - interval '3 hours'),
  ('00000000-0000-0000-0000-00000000a005', '00000000-0000-0000-0000-00000000b007',
   'Pourquoi le jeûne est-il important ?',                              'pending',  now() - interval '30 minutes', null),
  ('00000000-0000-0000-0000-00000000a006', '00000000-0000-0000-0000-00000000b007',
   'Comment lire la Bible quand on débute ?',                           'pending',  now() - interval '10 minutes', null);

insert into public.sermon_question_authors (question_id, member_id)
select v.qid::uuid, m.id
from (values
  ('00000000-0000-0000-0000-00000000a001', 'Mariam Girgis'),
  ('00000000-0000-0000-0000-00000000a002', 'Bishoy Farag'),
  ('00000000-0000-0000-0000-00000000a003', 'Marina Aziz'),
  ('00000000-0000-0000-0000-00000000a004', 'Abanoub Ramzy'),
  ('00000000-0000-0000-0000-00000000a005', 'Sara Mikhail'),
  ('00000000-0000-0000-0000-00000000a006', 'Membre Réel')
) as v(qid, member_name)
join public.members m on m.full_name = v.member_name;

-- Likes (the trigger updates like_count automatically)
insert into public.sermon_question_likes (question_id, member_id)
select v.qid::uuid, m.id
from (values
  ('00000000-0000-0000-0000-00000000a001', 'Youssef Tadros'),
  ('00000000-0000-0000-0000-00000000a001', 'Sara Mikhail'),
  ('00000000-0000-0000-0000-00000000a001', 'Nardine Ibrahim'),
  ('00000000-0000-0000-0000-00000000a001', 'Mina Boutros'),
  ('00000000-0000-0000-0000-00000000a003', 'Irini Sobhy'),
  ('00000000-0000-0000-0000-00000000a003', 'Verena Nashed'),
  ('00000000-0000-0000-0000-00000000a002', 'Kirollos Shenouda')
) as v(qid, member_name)
join public.members m on m.full_name = v.member_name;


-- ---------------------------------------------------------------------
-- Social wall — database rows only. No image files exist at these paths:
-- upload images there (or go through the upload flow) to see them render.
-- ---------------------------------------------------------------------
insert into public.wall_photos (member_id, original_path, blurred_path, status, created_at, reviewed_at)
select m.id,
       m.id || '/' || v.file,
       case when v.status = 'approved' then m.id || '/blurred-' || v.file end,
       v.status::public.moderation_status,
       now() - v.ago,
       case when v.status <> 'pending' then now() - v.ago + interval '30 minutes' end
from (values
  ('Mariam Girgis', 'photo1.jpg', 'approved', interval '6 hours'),
  ('Sara Mikhail',  'photo2.jpg', 'approved', interval '5 hours'),
  ('Mina Boutros',  'photo3.jpg', 'pending',  interval '1 hour'),
  ('Verena Nashed', 'photo4.jpg', 'rejected', interval '3 hours')
) as v(member_name, file, status, ago)
join public.members m on m.full_name = v.member_name;


-- ---------------------------------------------------------------------
-- Chants (PBI-11, PBI-18) — database rows only. Upload PDFs at these paths
-- in the 'chants' bucket (or test the upload flow) to open them.
-- ---------------------------------------------------------------------
insert into public.chants (id, title, file_path, sort_order, created_by) values
  ('00000000-0000-0000-0000-00000000c001', 'Chant d''ouverture',  'chant-ouverture.pdf', 1,
   (select id from public.members where full_name = 'Marc Hanna')),
  ('00000000-0000-0000-0000-00000000c002', 'Louange du matin',    'louange-matin.pdf',   2,
   (select id from public.members where full_name = 'Marc Hanna')),
  ('00000000-0000-0000-0000-00000000c003', 'Chant de clôture',    'chant-cloture.pdf',   3,
   (select id from public.members where full_name = 'Marc Hanna'));


-- ---------------------------------------------------------------------
-- Notifications history
-- ---------------------------------------------------------------------
insert into public.notifications (title, body, target_team_id, sent_by, sent_at)
select v.title, v.body, t.id,
       (select id from public.members where full_name = 'Marc Hanna'), now() - v.ago
from (values
  ('Bienvenue !',   'La conférence commence à 18h dans la grande salle.', null,         interval '1 day'),
  ('Rappel équipe', 'Rendez-vous devant l''accueil à 14h.',               'Saint Mark', interval '3 hours')
) as v(title, body, team_name, ago)
left join public.teams t on t.name = v.team_name and t.type = 'game';


-- ---------------------------------------------------------------------
-- Grand Jeu (PBI-19): 4 stations, each game team in a different order,
-- one head-to-head station. Codes/clues are dummy values.
-- Fixed station UUIDs make them easy to call from Postman.
-- Mariam (test member) is in Saint Mark: her codes are SM-1 … SM-4.
-- ---------------------------------------------------------------------
insert into public.stations (id, name, location) values
  ('00000000-0000-0000-0000-00000000e001', 'Station du Puits',     'Derrière la chapelle'),
  ('00000000-0000-0000-0000-00000000e002', 'Station de l''Arche',  'Terrain de foot'),
  ('00000000-0000-0000-0000-00000000e003', 'Tir à la corde',       'Pelouse principale'),
  ('00000000-0000-0000-0000-00000000e004', 'Station des Rouleaux', 'Salle B');

insert into public.team_stations (team_id, station_id, visit_order, opponent_team_id)
select t.id, v.station_id::uuid, v.visit_order,
       (select id from public.teams where name = v.opponent and type = 'game')
from (values
  ('Saint Mark',    '00000000-0000-0000-0000-00000000e001', 1, null),
  ('Saint Mark',    '00000000-0000-0000-0000-00000000e002', 2, null),
  ('Saint Mark',    '00000000-0000-0000-0000-00000000e003', 3, 'Saint George'),
  ('Saint Mark',    '00000000-0000-0000-0000-00000000e004', 4, null),
  ('Saint George',  '00000000-0000-0000-0000-00000000e002', 1, null),
  ('Saint George',  '00000000-0000-0000-0000-00000000e001', 2, null),
  ('Saint George',  '00000000-0000-0000-0000-00000000e003', 3, 'Saint Mark'),
  ('Saint George',  '00000000-0000-0000-0000-00000000e004', 4, null),
  ('Saint Mina',    '00000000-0000-0000-0000-00000000e004', 1, null),
  ('Saint Mina',    '00000000-0000-0000-0000-00000000e003', 2, 'Saint Demiana'),
  ('Saint Mina',    '00000000-0000-0000-0000-00000000e001', 3, null),
  ('Saint Mina',    '00000000-0000-0000-0000-00000000e002', 4, null),
  ('Saint Demiana', '00000000-0000-0000-0000-00000000e004', 1, null),
  ('Saint Demiana', '00000000-0000-0000-0000-00000000e003', 2, 'Saint Mina'),
  ('Saint Demiana', '00000000-0000-0000-0000-00000000e002', 3, null),
  ('Saint Demiana', '00000000-0000-0000-0000-00000000e001', 4, null)
) as v(team_name, station_id, visit_order, opponent)
join public.teams t on t.name = v.team_name and t.type = 'game';

-- Code = team initials + station number (e.g. SM-1); clue = a different word per team
insert into public.team_station_secrets (team_station_id, code, clue)
select ts.id,
       upper(left(split_part(t.name, ' ', 1), 1) || left(split_part(t.name, ' ', 2), 1)) || '-' || right(s.id::text, 1),
       'Indice ' || s.name || ' pour ' || t.name || ' : ' ||
       (array['la lumière', 'le pain', 'la vigne', 'le berger'])[ts.visit_order]
from public.team_stations ts
join public.teams t    on t.id = ts.team_id
join public.stations s on s.id = ts.station_id;

-- Saint George already won its first station (to see a revealed clue in the seed)
update public.team_stations set status = 'gagnee'
where team_id = (select id from public.teams where name = 'Saint George')
  and visit_order = 1;

insert into public.team_bonus_clues (team_id, clue, revealed)
select id, 'Bonus pour ' || name || ' : cherchez sous l''autel de pierre', name = 'Saint George'
from public.teams where type = 'game';
