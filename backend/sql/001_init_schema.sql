-- Multi-tenant base schema for conversational appointment core
-- Catalog tables are created before appointments / appointment_events so FKs
-- resolve on first run. Re-run safe: IF NOT EXISTS + ADD COLUMN IF NOT EXISTS.

create table if not exists tenants (
  id uuid primary key,
  name text not null,
  created_at timestamptz not null default now()
);

create table if not exists specialists (
  id uuid primary key,
  tenant_id uuid not null references tenants(id),
  specialist_key text not null check (specialist_key in ('dr', 'dra')),
  display_name text not null,
  timezone text not null default 'America/Mexico_City',
  calcom_event_type_id text,
  unique (tenant_id, specialist_key)
);

create table if not exists contacts (
  id uuid primary key,
  tenant_id uuid not null references tenants(id),
  wa_id text not null,
  chat_id text,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  unique (tenant_id, wa_id)
);

create table if not exists patients (
  id uuid primary key,
  tenant_id uuid not null references tenants(id),
  contact_id uuid not null references contacts(id),
  full_name text,
  birth_date date,
  phone_e164 text,
  created_at timestamptz not null default now()
);

-- ---------- Lookup catalogs (referenced by appointments / events; also used by 002) ----------

create table if not exists appointment_source_types (
  id smallint primary key,
  code text not null unique,
  display_name text not null
);

create table if not exists appointment_status_types (
  id smallint primary key,
  code text not null unique,
  display_name text not null,
  is_active_status boolean not null default false
);

create table if not exists appointment_types (
  id smallint primary key,
  code text not null unique,
  display_name text not null,
  active boolean not null default true
);

create table if not exists relationship_types (
  id smallint primary key,
  code text not null unique,
  display_name text not null
);

create table if not exists policy_scope_types (
  id smallint primary key,
  code text not null unique,
  display_name text not null
);

create table if not exists policy_window_types (
  id smallint primary key,
  code text not null unique,
  display_name text not null,
  requires_days boolean not null default false
);

create table if not exists message_direction_types (
  id smallint primary key,
  code text not null unique,
  display_name text not null
);

create table if not exists actor_types (
  id smallint primary key,
  code text not null unique,
  display_name text not null
);

create table if not exists appointment_event_types (
  id smallint primary key,
  code text not null unique,
  display_name text not null
);

insert into appointment_source_types (id, code, display_name) values
  (1, 'whatsapp', 'WhatsApp'),
  (2, 'voice_dialora', 'Dialora Voice'),
  (3, 'calcom_web', 'Cal.com Web'),
  (4, 'staff', 'Staff')
on conflict (id) do update
set code = excluded.code,
    display_name = excluded.display_name;

insert into appointment_status_types (id, code, display_name, is_active_status) values
  (1, 'pending', 'Pending', true),
  (2, 'confirmed', 'Confirmed', true),
  (3, 'rescheduled', 'Rescheduled', true),
  (4, 'cancelled', 'Cancelled', false),
  (5, 'no_show', 'No Show', false),
  (6, 'completed', 'Completed', false)
on conflict (id) do update
set code = excluded.code,
    display_name = excluded.display_name,
    is_active_status = excluded.is_active_status;

insert into appointment_types (id, code, display_name, active) values
  (1, 'general_consultation', 'General Consultation', true),
  (2, 'first_time', 'First Time Consultation', true),
  (3, 'follow_up', 'Follow-up Consultation', true),
  (4, 'procedure', 'Procedure', true),
  (5, 'emergency', 'Emergency', true),
  (6, 'other', 'Other', true)
on conflict (id) do update
set code = excluded.code,
    display_name = excluded.display_name,
    active = excluded.active;

insert into relationship_types (id, code, display_name) values
  (1, 'titular', 'Titular'),
  (2, 'familiar', 'Familiar'),
  (3, 'dependiente', 'Dependent'),
  (4, 'otro', 'Other')
on conflict (id) do update
set code = excluded.code,
    display_name = excluded.display_name;

insert into policy_scope_types (id, code, display_name) values
  (1, 'same_specialist', 'Same Specialist'),
  (2, 'all_specialists', 'All Specialists')
on conflict (id) do update
set code = excluded.code,
    display_name = excluded.display_name;

insert into policy_window_types (id, code, display_name, requires_days) values
  (1, 'none', 'No Window Restriction', false),
  (2, 'exact_slot', 'Exact Slot', false),
  (3, 'week', 'Same Week', false),
  (4, 'month', 'Same Month', false),
  (5, 'quarter', 'Same Quarter', false),
  (6, 'rolling_days', 'Rolling Days', true)
on conflict (id) do update
set code = excluded.code,
    display_name = excluded.display_name,
    requires_days = excluded.requires_days;

insert into message_direction_types (id, code, display_name) values
  (1, 'inbound', 'Inbound'),
  (2, 'outbound', 'Outbound')
on conflict (id) do update
set code = excluded.code,
    display_name = excluded.display_name;

insert into actor_types (id, code, display_name) values
  (1, 'patient', 'Patient'),
  (2, 'specialist', 'Specialist'),
  (3, 'staff', 'Staff'),
  (4, 'system', 'System')
on conflict (id) do update
set code = excluded.code,
    display_name = excluded.display_name;

insert into appointment_event_types (id, code, display_name) values
  (1, 'appointment.created', 'Appointment Created'),
  (2, 'appointment.confirmed', 'Appointment Confirmed'),
  (3, 'appointment.rescheduled', 'Appointment Rescheduled'),
  (4, 'appointment.cancelled', 'Appointment Cancelled'),
  (5, 'appointment.completed', 'Appointment Completed'),
  (6, 'appointment.no_show', 'Appointment No Show'),
  (7, 'reminder.sent', 'Reminder Sent'),
  (8, 'reminder.confirmed', 'Reminder Confirmed'),
  (9, 'webhook.received', 'Webhook Received'),
  (10, 'other', 'Other')
on conflict (id) do update
set code = excluded.code,
    display_name = excluded.display_name;

-- ---------- Core tables (FKs to catalogs where aplicable) ----------

create table if not exists appointments (
  id uuid primary key,
  tenant_id uuid not null references tenants(id),
  specialist_id uuid not null references specialists(id),
  patient_id uuid references patients(id),
  source text not null check (source in ('whatsapp', 'voice_dialora', 'calcom_web', 'staff')),
  source_type_id smallint references appointment_source_types(id),
  status text not null check (status in ('pending', 'confirmed', 'rescheduled', 'cancelled', 'no_show', 'completed')),
  status_type_id smallint references appointment_status_types(id),
  appointment_type_id smallint references appointment_types(id),
  booking_uid text,
  starts_at timestamptz,
  ends_at timestamptz,
  pending_titular boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Bases creadas con una version anterior de 001 (sin *_type_id): agregar columnas.
alter table appointments
  add column if not exists source_type_id smallint references appointment_source_types(id),
  add column if not exists status_type_id smallint references appointment_status_types(id),
  add column if not exists appointment_type_id smallint references appointment_types(id);

create unique index if not exists idx_appointments_booking_uid
  on appointments (tenant_id, booking_uid)
  where booking_uid is not null;

create table if not exists appointment_events (
  id uuid primary key,
  tenant_id uuid not null references tenants(id),
  appointment_id uuid references appointments(id),
  source text not null,
  source_type_id smallint references appointment_source_types(id),
  event_type text not null,
  event_type_id smallint references appointment_event_types(id),
  actor_type_id smallint references actor_types(id),
  external_ref text,
  raw_payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table appointment_events
  add column if not exists source_type_id smallint references appointment_source_types(id),
  add column if not exists event_type_id smallint references appointment_event_types(id),
  add column if not exists actor_type_id smallint references actor_types(id);

create unique index if not exists idx_events_idempotency
  on appointment_events (tenant_id, source, event_type, external_ref)
  where external_ref is not null;

create table if not exists bot_sessions (
  id uuid primary key,
  tenant_id uuid not null references tenants(id),
  wa_id text not null,
  specialist_id uuid references specialists(id),
  current_step text not null default 'ask_day',
  state jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  unique (tenant_id, wa_id)
);
