-- Site Pre-Start: database setup for the Supabase project `site-prestart`.
-- Safe to run more than once.
--
-- Who can do what:
--   * The supervisor (the one account listed in app_owner) can read and change every table.
--   * Workers have no login. They can ONLY call two functions: get_prestart and sign_prestart.
--     Both check the QR code (token) and that the date is today in Sydney.
--   * Nobody else can read or change anything.

-- ---------- owner ----------
create table if not exists public.app_owner (
  user_id uuid primary key references auth.users(id) on delete cascade
);
alter table public.app_owner enable row level security;
drop policy if exists "owner reads own row" on public.app_owner;
create policy "owner reads own row" on public.app_owner for select to authenticated
  using (user_id = (select auth.uid()));

-- ---------- settings (one row: defaults for a new day, builder email) ----------
create table if not exists public.settings (
  id int primary key default 1 check (id = 1),
  project text not null default '',
  site_address text not null default '',
  work_location text not null default '',
  building text not null default '',
  level text not null default '',
  leader text not null default '',
  hazards text not null default '',
  notes text not null default '',
  builder_email text not null default '',
  risk_list jsonb not null default '[]'::jsonb,      -- standard list: [{name, controls[]}]
  default_risks jsonb not null default '[]'::jsonb,  -- risks a new day starts with: [{name, level, controls[]}]
  updated_at timestamptz not null default now()
);

-- ---------- people (the names workers pick from) ----------
create table if not exists public.people (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 80),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- ---------- prestarts (one per day) ----------
create table if not exists public.prestarts (
  day date primary key,
  project text not null default '',
  site_address text not null default '',
  work_location text not null default '',
  building text not null default '',
  level text not null default '',
  weather text not null default '',
  weather_manual boolean not null default false,
  leader text not null default '',
  issues boolean,                        -- true = YES, false = NO, null = not answered
  issues_details text not null default '',
  planned text not null default '',      -- one item per line
  hazards text not null default '',      -- one item per line (made from risks; shown to workers and in the PDF)
  risks jsonb not null default '[]'::jsonb, -- [{name, level: low|med|high, controls[]}]
  notes text not null default '',        -- one item per line
  token text unique check (token is null or token ~ '^[A-Za-z0-9]{8,64}$'),
  published_at timestamptz,
  completed_at timestamptz,
  supervisor_name text not null default '',
  supervisor_signature text check (supervisor_signature is null or char_length(supervisor_signature) <= 200000),
  updated_at timestamptz not null default now()
);

-- ---------- signoffs (one per person per day) ----------
create table if not exists public.signoffs (
  id uuid primary key default gen_random_uuid(),
  day date not null references public.prestarts(day) on delete cascade,
  person_id uuid references public.people(id) on delete set null,
  name text not null check (char_length(name) between 1 and 80),
  typed_by_worker boolean not null default false,
  signature text not null check (char_length(signature) <= 140000),
  signed_at timestamptz not null default now(),
  unique (day, person_id)
);
create unique index if not exists signoffs_day_name on public.signoffs (day, lower(name));
create index if not exists signoffs_person on public.signoffs (person_id);

-- ---------- Row Level Security: owner only ----------
do $$
declare t text;
begin
  foreach t in array array['settings','people','prestarts','signoffs'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists "owner only" on public.%I', t);
    execute format($p$create policy "owner only" on public.%I for all to authenticated
      using (exists (select 1 from public.app_owner o where o.user_id = (select auth.uid())))
      with check (exists (select 1 from public.app_owner o where o.user_id = (select auth.uid())))$p$, t);
  end loop;
end $$;

-- Workers (anon) get no table access at all, even before RLS is considered.
revoke all on public.app_owner, public.settings, public.people, public.prestarts, public.signoffs from anon;

-- ---------- protection against guessing QR codes ----------
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists private.token_fails (
  at timestamptz not null default now(),
  ip text not null
);
create index if not exists token_fails_ip_at on private.token_fails (ip, at);

create or replace function private.client_ip() returns text
language plpgsql stable set search_path = '' as $$
declare h json;
begin
  begin h := current_setting('request.headers', true)::json; exception when others then h := null; end;
  return coalesce(nullif(h->>'cf-connecting-ip',''), nullif(h->>'x-real-ip',''),
                  nullif(btrim(split_part(coalesce(h->>'x-forwarded-for',''), ',', 1)),''), 'unknown');
end $$;

-- Checks the QR code. Returns the day's row, or sets p_error to: locked / invalid / expired.
-- "invalid" (a code that never existed) counts as a guess: 1 s delay, and 30 guesses in
-- 15 minutes from one connection locks that connection out for a while.
create or replace function private.check_token(p_day date, p_token text, out r public.prestarts, out p_error text)
language plpgsql volatile set search_path = '' as $$
declare v_ip text := private.client_ip();
begin
  if (select count(*) from private.token_fails f where f.ip = v_ip and f.at > now() - interval '15 minutes') >= 30 then
    perform pg_sleep(1); p_error := 'locked'; return;
  end if;
  if p_token is not null and p_token ~ '^[A-Za-z0-9]{8,64}$' then
    select * into r from public.prestarts p where p.token = p_token and p.published_at is not null;
  end if;
  if r.day is null then
    insert into private.token_fails (ip) values (v_ip);
    delete from private.token_fails f where f.at < now() - interval '1 day';
    perform pg_sleep(1); p_error := 'invalid'; r := null; return;
  end if;
  if r.day <> p_day or r.day <> (now() at time zone 'Australia/Sydney')::date then
    p_error := 'expired'; r := null; return;
  end if;
end $$;

-- ---------- worker function 1: read today's pre-start ----------
create or replace function public.get_prestart(p_day date, p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c record;
begin
  select * into c from private.check_token(p_day, p_token);
  if c.p_error is not null then return jsonb_build_object('error', c.p_error); end if;
  return jsonb_build_object(
    'day', (c.r).day, 'project', (c.r).project, 'site_address', (c.r).site_address,
    'work_location', (c.r).work_location, 'building', (c.r).building, 'level', (c.r).level,
    'weather', (c.r).weather, 'leader', (c.r).leader, 'issues', (c.r).issues,
    'issues_details', (c.r).issues_details, 'planned', (c.r).planned, 'hazards', (c.r).hazards,
    'notes', (c.r).notes, 'completed', (c.r).completed_at is not null,
    'people', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name,
        'signed', exists (select 1 from public.signoffs s where s.day = (c.r).day and (s.person_id = p.id or lower(s.name) = lower(p.name))))
        order by lower(p.name)) from public.people p where p.active), '[]'::jsonb),
    'signed', coalesce((select jsonb_agg(s.name order by s.signed_at) from public.signoffs s where s.day = (c.r).day), '[]'::jsonb)
  );
end $$;

-- ---------- worker function 2: sign today's pre-start ----------
create or replace function public.sign_prestart(p_day date, p_token text, p_person_id uuid, p_typed_name text, p_signature text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c record; v_name text; v_pid uuid; v_typed boolean; v_at timestamptz;
begin
  select * into c from private.check_token(p_day, p_token);
  if c.p_error is not null then return jsonb_build_object('ok', false, 'error', c.p_error); end if;
  if (c.r).completed_at is not null then return jsonb_build_object('ok', false, 'error', 'closed'); end if;

  if p_signature is null or left(p_signature, 22) <> 'data:image/png;base64,'
     or char_length(p_signature) > 140000 or char_length(p_signature) < 200 then
    return jsonb_build_object('ok', false, 'error', 'signature');
  end if;

  if p_person_id is not null then
    select p.id, p.name into v_pid, v_name from public.people p where p.id = p_person_id and p.active;
    if v_pid is null then return jsonb_build_object('ok', false, 'error', 'person'); end if;
    v_typed := false;
  else
    v_name := left(btrim(regexp_replace(coalesce(p_typed_name, ''), '[[:space:][:cntrl:]]+', ' ', 'g')), 60);
    if char_length(v_name) < 2 then return jsonb_build_object('ok', false, 'error', 'name'); end if;
    -- A typed name that is already on the list counts as that person.
    select p.id, p.name into v_pid, v_name from public.people p where p.active and lower(p.name) = lower(v_name) limit 1;
    if v_pid is null then
      v_name := left(btrim(regexp_replace(coalesce(p_typed_name, ''), '[[:space:][:cntrl:]]+', ' ', 'g')), 60);
      v_typed := true;
    else
      v_typed := false;
    end if;
  end if;

  if (select count(*) from public.signoffs s where s.day = (c.r).day) >= 300 then
    return jsonb_build_object('ok', false, 'error', 'full');
  end if;

  insert into public.signoffs (day, person_id, name, typed_by_worker, signature)
  values ((c.r).day, v_pid, v_name, v_typed, p_signature)
  on conflict do nothing
  returning signed_at into v_at;
  if v_at is null then return jsonb_build_object('ok', false, 'error', 'duplicate'); end if;
  return jsonb_build_object('ok', true, 'name', v_name, 'signed_at', v_at);
end $$;

revoke all on function private.client_ip() from public;
revoke all on function private.check_token(date, text) from public;
revoke all on function public.get_prestart(date, text) from public;
revoke all on function public.sign_prestart(date, text, uuid, text, text) from public;
grant execute on function public.get_prestart(date, text) to anon, authenticated;
grant execute on function public.sign_prestart(date, text, uuid, text, text) to anon, authenticated;

-- ---------- starting defaults (Greenwich Hospital) ----------
-- New days start with project, site address, person leading and notes. Hazards, work location, building and level start blank.
insert into public.settings (id, project, site_address, notes)
values (1, 'Greenwich Hospital', '97-115 River Rd Greenwich',
$n$No parking on site. Hindmarsh encourages public transport and carpooling where possible. Public transport routes are available in the sheds, on the notice board and in the induction room.
Workers must be appropriately trained, competent, and experienced to undertake the works assigned to them. Any person unsure of a task or lacking the required competency must stop work and notify supervision immediately.
Workers requiring translation or assistance to understand site instructions, SWMS, hazards, or control measures must notify supervision prior to commencing work.
Changes to site conditions, access, sequencing, weather, or adjacent trades are to be reported immediately. Works must stop if conditions differ from the approved SWMS, drawings, or methodology.
Only current approved drawings and instructions are to be used. Do not proceed where information is unclear, incomplete, or unavailable.
No modification, removal, relocation, or overloading of formwork, temporary works, edge protection, screens, braces, or props without approval.
Exclusion zones are to be maintained during lifting, stripping, and other high-risk activities. No personnel are permitted beneath overhead works unless appropriate controls are in place.
Operators must hold the required licences/tickets and conduct pre-start inspections. Defective tools, lifting gear, or equipment must be tagged out and reported immediately.
All incidents, near misses, hazards, damaged equipment, and property damage must be reported immediately.
Workers must be fit for work and notify supervision if affected by fatigue, medication, drugs, alcohol, illness, or any condition that may impact their ability to work safely.$n$)
on conflict (id) do nothing;

-- Columns added after v1 (for databases made with the first version of this file)
alter table public.prestarts add column if not exists risks jsonb not null default '[]'::jsonb;
alter table public.settings add column if not exists risk_list jsonb not null default '[]'::jsonb;
alter table public.settings add column if not exists default_risks jsonb not null default '[]'::jsonb;
alter table public.people add column if not exists supervisor boolean not null default false; -- can sign off pre-starts (shown in the Complete dropdown)
