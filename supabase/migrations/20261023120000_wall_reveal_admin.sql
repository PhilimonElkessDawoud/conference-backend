-- =====================================================================
-- Migration: the admins set the wall's reveal date from the app
-- Applies on top of 20261022120000_member_notifications.sql.
--
-- `conference_settings.wall_reveal_at` (when the wall's photos are shown
-- unblurred to everyone) could only be set in SQL. Now an admin sets it
-- from the profile page: the single row is upserted (created when the
-- table is empty, updated otherwise). Members still only read it.
-- =====================================================================

create policy "conference_settings: admin insert" on public.conference_settings
  for insert to authenticated
  with check ((select public.is_admin()));

create policy "conference_settings: admin update" on public.conference_settings
  for update to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

revoke delete on public.conference_settings from anon, authenticated;
