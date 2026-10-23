-- =====================================================================
-- Migration: the workshop's answers shown per team AND per trial
-- Applies on top of 20261023150000_workshop_answers_teams.sql.
--
-- An admin now shows the answers of one trial (moses, david, peter) to
-- one workshop team, e.g. David's answers to team A only:
--   app_settings.workshop_answers = {"<team uuid>": ["david"], ...}
-- It replaces `workshop_answers_team_ids` (a whole team, every trial),
-- added just before and never used.
--
-- The existing policies apply: everyone reads app_settings, admins
-- update it; realtime already publishes the table.
-- =====================================================================

alter table public.app_settings
  add column workshop_answers jsonb not null default '{}'
    check (jsonb_typeof(workshop_answers) = 'object'),
  drop column if exists workshop_answers_team_ids;
