-- =====================================================================
-- Migration: the admin chooses how many points a question of the day earns
-- Applies on top of 20261023130000_slot_overlap_per_team.sql.
--
-- `daily_questions.points` is set when the question is created (1 for the
-- existing ones). award_daily_point() now gives that many points to the
-- team instead of always 1; revoke_daily_point() deletes the score event,
-- so it takes back whatever was given.
-- =====================================================================

alter table public.daily_questions
  add column points integer not null default 1 check (points between 1 and 100);

create or replace function public.award_daily_point(p_answer_id bigint)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_a      public.daily_answers%rowtype;
  v_points integer;
begin
  if not public.is_admin() then
    raise exception 'Admins only' using errcode = '42501';
  end if;

  select * into v_a from public.daily_answers where id = p_answer_id;
  if not found then
    raise exception 'Answer not found';
  end if;

  select points into v_points from public.daily_questions where id = v_a.question_id for update;

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
  values (v_a.team_id, v_points, 'Daily question', 'daily_question', v_a.question_id);
end;
$$;
