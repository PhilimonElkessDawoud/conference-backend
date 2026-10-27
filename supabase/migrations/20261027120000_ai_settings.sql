-- =====================================================================
-- AI settings ("Implement with AI", Settings > AI): the system prompt
-- Claude gets before every request (after the repository's CLAUDE.md) and
-- the token cap of a task, with the former prompts. Technical admins only.
--
--   GET   /rest/v1/ai_settings?id=eq.true
--   PATCH /rest/v1/ai_settings?id=eq.true  {"max_tokens_per_task": 500000}
--   GET   /rest/v1/ai_settings_history?order=edited_at.desc
-- =====================================================================
create table public.ai_settings (
  id                  boolean primary key default true check (id),   -- a single row
  system_prompt       text not null check (char_length(trim(system_prompt)) between 1 and 20000),
  max_tokens_per_task integer not null default 1000000
                      check (max_tokens_per_task between 50000 and 5000000),
  -- Who last changed the prompt (not the cap), and when; no author: the default prompt.
  prompt_updated_by   uuid references public.members (id) on delete set null,
  prompt_updated_at   timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  updated_by          uuid references public.members (id) on delete set null
);

-- The former prompts, newest first: filled by the trigger, never written by hand.
create table public.ai_settings_history (
  id            uuid primary key default gen_random_uuid(),
  system_prompt text not null,
  edited_by     uuid references public.members (id) on delete set null,  -- null: the default prompt
  edited_at     timestamptz not null
);
create index ai_settings_history_edited_at_idx on public.ai_settings_history (edited_at desc);

create function public.ai_settings_stamp()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  new.id := true;
  new.updated_at := now();
  new.updated_by := public.current_member_id();
  if new.system_prompt is distinct from old.system_prompt then
    insert into public.ai_settings_history (system_prompt, edited_by, edited_at)
    values (old.system_prompt, old.prompt_updated_by, old.prompt_updated_at);
    new.prompt_updated_by := public.current_member_id();
    new.prompt_updated_at := now();
  else
    new.prompt_updated_by := old.prompt_updated_by;
    new.prompt_updated_at := old.prompt_updated_at;
  end if;
  return new;
end;
$$;

create trigger ai_settings_stamp
before update on public.ai_settings
for each row execute function public.ai_settings_stamp();

alter table public.ai_settings enable row level security;
alter table public.ai_settings_history enable row level security;

create policy "ai_settings: tech admin reads" on public.ai_settings
  for select to authenticated using ((select public.is_tech_admin()));
create policy "ai_settings: tech admin update" on public.ai_settings
  for update to authenticated
  using ((select public.is_tech_admin())) with check ((select public.is_tech_admin()));
create policy "ai_settings_history: tech admin reads" on public.ai_settings_history
  for select to authenticated using ((select public.is_tech_admin()));

revoke all on public.ai_settings, public.ai_settings_history from anon;
revoke insert, delete on public.ai_settings from authenticated;
revoke insert, update, delete on public.ai_settings_history from authenticated;
revoke execute on function public.ai_settings_stamp() from public, anon, authenticated;

-- The default prompt and cap (same text as the frontend's Spring-mode stand-in).
insert into public.ai_settings (system_prompt) values ($prompt$Tu es le développeur de MaConference, l'application de la conférence des jeunes. Un admin technique te confie une tâche depuis l'app ; il n'est pas forcément développeur : réponds-lui en français, simplement.

## Périmètre
- Frontend : le repo MaConference, en mode Supabase (React 19, TypeScript, Vite).
- Backend : le repo conference-backend (migrations SQL Supabase, RPC, Edge Functions). Spring Boot est hors périmètre : son service reçoit seulement des stubs `TODO(spring)` avec des données de test.

## Règles à respecter
- Lis et respecte CLAUDE.md et architecture-rules.md de chaque repo avant de toucher un fichier.
- Un seul hook et une seule UI par fonctionnalité ; deux services avec la même API (`x.service.ts` et `x.service.supabase.ts`).
- Réutilise les composants de app/shared/components avant d'écrire du JSX.
- Supabase est la référence : ids uuid, règles RLS, `is_admin()` et `is_tech_admin()` côté serveur.
- Une migration doit rester compatible avec le front actuellement en production (elle est appliquée avant lui). Pas de `drop` ni de `truncate` sans le dire clairement dans le plan.
- Textes de l'interface en français, dans les fichiers i18n.

## Déroulé
1. Analyse le code concerné. Pose tes questions avec ask_admin dès qu'un point est ambigu, plutôt que de deviner.
2. Propose ton plan avec submit_plan : périmètre (front, back ou les deux), fichiers, migration, version cible. Attends sa validation.
3. Implémente, puis lance lint, types et tests (et Supabase local s'il y a une migration). Corrige jusqu'à 3 fois.
4. Commit sur la branche de la tâche, ouvre les PR liées, et rédige l'entrée « Quoi de neuf ? » (FR et EN) avec write_changelog, en langage utilisateur, sans jargon.

## Interdits
- Pas de git push --force, jamais de commit sur main, jamais de merge.
- Aucun accès à la production : seule la CI la touche, après l'approbation de l'admin technique.
- Garde ta consommation de tokens raisonnable : lis seulement les fichiers utiles.$prompt$);
