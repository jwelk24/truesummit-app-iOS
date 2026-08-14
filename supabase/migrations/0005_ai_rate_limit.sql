-- Rate-limit state for the AI proxy.
--
-- Serves the `ai` Edge Function, which lives in the Android repo — the AI
-- features are Android-only for now. The migration lives here because this
-- Supabase project is shared by both apps, and a shared schema needs a single
-- owner for its history: Supabase keys applied migrations on the version
-- prefix, so two repos numbering independently will eventually collide and
-- silently skip one of them.
--
-- The Render version kept these counters in a JavaScript Map. That was already
-- unreliable there (the free instance sleeps and the map resets), and it is
-- worse on Edge Functions, where every invocation may land on a fresh isolate.
-- Postgres is the only thing that actually persists across invocations.

create table if not exists public.ai_usage (
    id          bigserial primary key,
    user_id     uuid        not null,
    created_at  timestamptz not null default now()
);

create index if not exists ai_usage_user_time_idx on public.ai_usage (user_id, created_at desc);
create index if not exists ai_usage_time_idx      on public.ai_usage (created_at desc);

-- No policies: clients must never read or write this directly. The Edge
-- Function reaches it with the service role, which bypasses RLS.
alter table public.ai_usage enable row level security;

-- Counts and records one use atomically. Returns null when the call is allowed,
-- otherwise a message suitable for showing the user.
create or replace function public.check_ai_rate_limit(p_user uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
    user_hits   int;
    global_hits int;
    -- Gemini's free tier allows 15 req/min and 1500 req/day for the whole
    -- project, so stay comfortably under both.
    user_window  constant interval := interval '5 minutes';
    user_max     constant int      := 20;
    global_max   constant int      := 1200;
begin
    select count(*) into user_hits
      from public.ai_usage
     where user_id = p_user
       and created_at > now() - user_window;

    if user_hits >= user_max then
        return 'Too many AI requests. Try again in a few minutes.';
    end if;

    select count(*) into global_hits
      from public.ai_usage
     where created_at >= date_trunc('day', now());

    if global_hits >= global_max then
        return 'Daily AI limit reached. Try again tomorrow.';
    end if;

    insert into public.ai_usage (user_id) values (p_user);

    -- Keep the table bounded; nothing here is interesting after a couple days.
    delete from public.ai_usage where created_at < now() - interval '2 days';

    return null;
end;
$$;
