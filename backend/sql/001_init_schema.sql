-- Multi-tenant base schema for conversational appointment core

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

create table if not exists appointments (
  id uuid primary key,
  tenant_id uuid not null references tenants(id),
  specialist_id uuid not null references specialists(id),
  patient_id uuid references patients(id),
  source text not null check (source in ('whatsapp', 'voice_dialora', 'calcom_web', 'staff')),
  booking_uid text,
  starts_at timestamptz,
  ends_at timestamptz,
  status text not null check (status in ('pending', 'confirmed', 'rescheduled', 'cancelled', 'no_show', 'completed')),
  pending_titular boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists idx_appointments_booking_uid
  on appointments (tenant_id, booking_uid)
  where booking_uid is not null;

create table if not exists appointment_events (
  id uuid primary key,
  tenant_id uuid not null references tenants(id),
  appointment_id uuid references appointments(id),
  source text not null,
  event_type text not null,
  external_ref text,
  raw_payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

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
