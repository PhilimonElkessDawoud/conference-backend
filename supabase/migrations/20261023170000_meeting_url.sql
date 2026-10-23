-- =====================================================================
-- Migration: the "Rejoindre la Tasbe7a" shortcut (Zoom / Meet link)
-- Applies on top of 20261023160000_workshop_answers_per_trial.sql.
--
-- An admin sets, from the app's settings page, the link of the online
-- meeting (Zoom, Google Meet…) that the home page's shortcut opens:
--   PATCH /rest/v1/app_settings?id=eq.true  {"meeting_url": "https://meet.google.com/abc-defg-hij"}
-- Empty: no shortcut on the home page.
--
-- The existing policies apply: everyone reads app_settings, admins
-- update it; realtime already publishes the table.
-- =====================================================================

alter table public.app_settings
  add column meeting_url text not null default ''
    check (meeting_url = '' or (meeting_url ~ '^https?://' and char_length(meeting_url) <= 500));
