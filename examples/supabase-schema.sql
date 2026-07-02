-- Selfdeveloping System — Supabase-Schema für den Consumer-Ticket-Eingang.
-- Im Supabase SQL-Editor ausführen. Eine DB trägt beliebig viele Projekte
-- (project-Spalte); pro Projekt läuft eine Skill-Instanz mit SDS_SUPABASE_PROJECT.
--
-- Sicherheitsmodell:
--   * anon-Key (im Formular)      → darf NUR Tickets einfügen (RLS), nichts lesen.
--   * service_role-Key (.sds-env) → voller Zugriff, umgeht RLS. NIE ins Frontend!

create table if not exists sds_tickets (
  id             bigint generated always as identity primary key,
  project        text not null check (project ~ '^[a-z0-9-]{1,60}$'),
  title          text not null check (char_length(title) between 3 and 200),
  description    text check (char_length(description) <= 10000),
  type           text default 'bug' check (type in ('bug','feature')),  -- Reporter-Angabe; das Council entscheidet endgültig
  labels         text[] not null default '{}',
  status         text not null default 'open'
                 check (status in ('open','in-review','needs-approval','deployed','closed','escalated')),
  reporter_name  text check (char_length(reporter_name) <= 120),
  reporter_email text check (reporter_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  created_at     timestamptz not null default now()
);

create table if not exists sds_comments (
  id         bigint generated always as identity primary key,
  ticket_id  bigint not null references sds_tickets(id) on delete cascade,
  author     text not null default 'bot',      -- 'bot' | 'bot-notify' | 'human'
  body       text not null check (char_length(body) <= 10000),
  created_at timestamptz not null default now()
);

create index if not exists sds_tickets_poll_idx
  on sds_tickets (project, status, created_at);

-- ---------- RLS: anon darf melden, sonst nichts ----------
alter table sds_tickets  enable row level security;
alter table sds_comments enable row level security;

-- Formular (anon-Key): nur INSERT neuer, offener Tickets — kein Lesen, kein Ändern.
drop policy if exists sds_anon_report on sds_tickets;
create policy sds_anon_report on sds_tickets
  for insert to anon
  with check (status = 'open' and labels = '{}');

-- Kommentare: kein anon-Zugriff (nur service_role, die RLS ohnehin umgeht).
-- Bewusst KEINE select-Policies für anon: Reports anderer Nutzer bleiben privat.
