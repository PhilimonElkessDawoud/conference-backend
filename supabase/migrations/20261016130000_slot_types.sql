-- =====================================================================
-- Migration: slot types matching the conference program
-- Applies on top of 20261016120000_push_notifications.sql.
--
-- Value      Label (app)  Program items
-- welcome    Accueil      Remise des clés, Réception Bienvenue
-- plenary    Plénière     Présentation du programme et de l'application, Clôture
-- prayer     Prière       Prière
-- liturgy    Messe        Messe
-- tasbeha    Tasbeha      Tasbeha
-- chants     Chants       Chants
-- sermon     Sermon       Sermon — sermon Q&A stays limited to these
-- workshop   Workshop     Workshop
-- activity   Activité     Activité manuelle
-- game       Jeux         Jeux (ice breaker), Grands Jeux, Jeux de société
-- meal       Repas        Petit-déjeuner, Déjeuner, Dîner
-- rest       Repos        Repos
-- other      Autre        anything else
--
-- The generic 'session' value is removed: existing 'session' slots become 'other'.
-- =====================================================================

alter type public.slot_type rename to slot_type_old;

create type public.slot_type as enum (
  'welcome', 'plenary', 'prayer', 'liturgy', 'tasbeha', 'chants', 'sermon',
  'workshop', 'activity', 'game', 'meal', 'rest', 'other'
);

alter table public.slots alter column type drop default;

alter table public.slots
  alter column type type public.slot_type
  using (case type::text when 'session' then 'other' else type::text end)::public.slot_type;

alter table public.slots alter column type set default 'other';

drop type public.slot_type_old;
