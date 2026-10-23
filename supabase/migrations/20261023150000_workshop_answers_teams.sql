-- =====================================================================
-- Migration: the workshop teams that see the workshop's answers
-- Applies on top of 20261023140000_daily_question_points.sql.
--
-- In the workshop's step 3, members only see the reference of each
-- exhibit; the admins see everything (arguments and verses). An admin
-- can show everything to some workshop teams too, from the profile
-- page: `app_settings.workshop_answers_team_ids` lists them.
--
-- `members_can_edit_team_name` (members may rename their own teams) is
-- read by the app but was in no migration: added here when missing.
--
-- The existing policies apply: everyone reads app_settings, admins
-- update it; realtime already publishes the table.
-- =====================================================================

alter table public.app_settings
  add column if not exists workshop_answers_team_ids uuid[] not null default '{}',
  add column if not exists members_can_edit_team_name boolean not null default false;
