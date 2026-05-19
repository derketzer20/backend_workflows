-- Omnichannel scheduling hardening for PostgreSQL
-- Scope: multi-location, robust integrity rules, soft delete, auditability,
-- and null-safe access patterns for Make/BotSailor integrations.

create extension if not exists pgcrypto;

-- ---------- Shared helpers ----------

create or replace function set_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create or replace function normalize_phone_e164(raw_phone text)
returns text
language plpgsql
immutable
set search_path = public
as $$
declare
  digits text;
begin
  digits := regexp_replace(coalesce(raw_phone, ''), '\D', '', 'g');

  if digits = '' then
    return null;
  end if;

  if length(digits) = 10 then
    return '+52' || digits;
  end if;

  if length(digits) = 12 and left(digits, 2) = '52' then
    return '+' || digits;
  end if;

  if length(digits) = 13 and left(digits, 3) = '521' then
    return '+' || digits;
  end if;

  if left(coalesce(raw_phone, ''), 1) = '+' then
    return '+' || digits;
  end if;

  return '+' || digits;
end;
$$;

create or replace function normalize_phone_digits(raw_phone text)
returns text
language plpgsql
immutable
set search_path = public
as $$
declare
  digits text;
begin
  digits := regexp_replace(coalesce(raw_phone, ''), '\D', '', 'g');

  if digits = '' then
    return null;
  end if;

  if length(digits) = 13 and left(digits, 3) = '521' then
    return substr(digits, 4, 10);
  end if;

  if length(digits) = 12 and left(digits, 2) = '52' then
    return substr(digits, 3, 10);
  end if;

  if length(digits) = 10 then
    return digits;
  end if;

  if length(digits) > 10 then
    return right(digits, 10);
  end if;

  return digits;
end;
$$;

-- ---------- New core entities ----------

create table if not exists locations (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  code text not null,
  display_name text not null,
  timezone text not null default 'America/Mexico_City',
  country_code text not null default 'MX',
  state_code text,
  city text,
  address_line text,
  active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  unique (tenant_id, code)
);

create table if not exists contact_patient_links (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  contact_id uuid not null references contacts(id),
  patient_id uuid not null references patients(id),
  relationship_type text not null default 'titular'
    check (relationship_type in ('titular', 'familiar', 'dependiente', 'otro')),
  can_manage_appointments boolean not null default true,
  is_primary boolean not null default false,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table if not exists channel_messages (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  contact_id uuid references contacts(id),
  patient_id uuid references patients(id),
  appointment_id uuid references appointments(id),
  source text not null check (source in ('whatsapp', 'voice_dialora', 'calcom_web', 'staff')),
  direction text not null check (direction in ('inbound', 'outbound')),
  external_message_id text,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- ---------- Lookup catalogs (type tables by ID) ----------

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

create table if not exists specialist_duplicate_policies (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  specialist_id uuid not null references specialists(id),
  policy_scope text not null default 'same_specialist'
    check (policy_scope in ('same_specialist', 'all_specialists')),
  window_type text not null default 'exact_slot'
    check (window_type in ('none', 'exact_slot', 'week', 'month', 'quarter', 'rolling_days')),
  window_days integer,
  enforce_for_sources text[],
  active boolean not null default true,
  allow_override_by_staff boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint specialist_duplicate_policies_days_check
    check (
      (window_type = 'rolling_days' and coalesce(window_days, 0) > 0)
      or (window_type <> 'rolling_days' and window_days is null)
    )
);

-- ---------- Existing table evolution ----------

alter table specialists
  drop constraint if exists specialists_specialist_key_check;

alter table specialists
  drop constraint if exists specialists_tenant_id_specialist_key_key;

alter table specialists
  add column if not exists specialist_code text,
  add column if not exists location_id uuid references locations(id),
  add column if not exists email text,
  add column if not exists phone_e164 text,
  add column if not exists deleted_at timestamptz,
  add column if not exists updated_at timestamptz not null default now();

update specialists
set specialist_code = coalesce(nullif(specialist_code, ''), specialist_key)
where specialist_code is null;

alter table specialists
  alter column specialist_code set not null;

alter table contacts
  alter column wa_id drop not null;

alter table contacts
  drop constraint if exists contacts_tenant_id_wa_id_key;

alter table contacts
  add column if not exists phone_e164 text,
  add column if not exists phone_digits text,
  add column if not exists channel_primary text check (channel_primary in ('whatsapp', 'voice_dialora', 'calcom_web', 'staff')),
  add column if not exists metadata jsonb not null default '{}'::jsonb,
  add column if not exists deleted_at timestamptz;

alter table contact_patient_links
  add column if not exists relationship_type_id smallint references relationship_types(id),
  add column if not exists relationship_type_code text;

alter table patients
  add column if not exists phone_digits text,
  add column if not exists email text,
  add column if not exists gender text check (gender in ('male', 'female', 'other', 'unknown')),
  add column if not exists metadata jsonb not null default '{}'::jsonb,
  add column if not exists deleted_at timestamptz,
  add column if not exists updated_at timestamptz not null default now();

alter table appointments
  add column if not exists source_type_id smallint references appointment_source_types(id),
  add column if not exists status_type_id smallint references appointment_status_types(id),
  add column if not exists location_id uuid references locations(id),
  add column if not exists reason text,
  add column if not exists cancel_reason text,
  add column if not exists created_by text,
  add column if not exists deleted_at timestamptz,
  add column if not exists channel_ref text,
  add column if not exists metadata jsonb not null default '{}'::jsonb;

alter table appointments
  drop constraint if exists appointments_time_order_check;

alter table appointments
  add constraint appointments_time_order_check
  check (starts_at is null or ends_at is null or starts_at < ends_at);

alter table appointment_events
  add column if not exists source_type_id smallint references appointment_source_types(id),
  add column if not exists actor_type_id smallint references actor_types(id),
  add column if not exists event_type_id smallint references appointment_event_types(id),
  add column if not exists external_event_id text,
  add column if not exists actor_type text check (actor_type in ('patient', 'specialist', 'staff', 'system')),
  add column if not exists actor_ref text;

alter table channel_messages
  add column if not exists source_type_id smallint references appointment_source_types(id),
  add column if not exists direction_type_id smallint references message_direction_types(id);

alter table specialist_duplicate_policies
  add column if not exists policy_scope_type_id smallint references policy_scope_types(id),
  add column if not exists window_type_id smallint references policy_window_types(id);

-- Backfill ID-based types from current text fields
update contact_patient_links cpl
set relationship_type_id = rt.id,
    relationship_type_code = rt.code
from relationship_types rt
where lower(coalesce(cpl.relationship_type, '')) = rt.code
  and cpl.relationship_type_id is null;

update appointments a
set source_type_id = st.id
from appointment_source_types st
where lower(coalesce(a.source, '')) = st.code
  and a.source_type_id is null;

update appointments a
set status_type_id = ss.id
from appointment_status_types ss
where lower(coalesce(a.status, '')) = ss.code
  and a.status_type_id is null;

update appointment_events e
set source_type_id = st.id
from appointment_source_types st
where lower(coalesce(e.source, '')) = st.code
  and e.source_type_id is null;

update appointment_events e
set actor_type_id = at.id
from actor_types at
where lower(coalesce(e.actor_type, '')) = at.code
  and e.actor_type_id is null;

update appointment_events e
set event_type_id = et.id
from appointment_event_types et
where lower(coalesce(e.event_type, '')) = et.code
  and e.event_type_id is null;

update appointment_events
set event_type_id = coalesce(event_type_id, 10);

update channel_messages m
set source_type_id = st.id
from appointment_source_types st
where lower(coalesce(m.source, '')) = st.code
  and m.source_type_id is null;

update channel_messages m
set direction_type_id = dt.id
from message_direction_types dt
where lower(coalesce(m.direction, '')) = dt.code
  and m.direction_type_id is null;

update specialist_duplicate_policies p
set policy_scope_type_id = ps.id
from policy_scope_types ps
where lower(coalesce(p.policy_scope, '')) = ps.code
  and p.policy_scope_type_id is null;

update specialist_duplicate_policies p
set window_type_id = pw.id
from policy_window_types pw
where lower(coalesce(p.window_type, '')) = pw.code
  and p.window_type_id is null;

-- Synchronize text values with type IDs for backward-compatible flows
create or replace function tg_sync_appointment_types()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.source_type_id is null and new.source is not null then
    select id into new.source_type_id
    from appointment_source_types
    where code = lower(new.source)
    limit 1;
  elsif new.source is null and new.source_type_id is not null then
    select code into new.source from appointment_source_types where id = new.source_type_id;
  end if;

  if new.status_type_id is null and new.status is not null then
    select id into new.status_type_id
    from appointment_status_types
    where code = lower(new.status)
    limit 1;
  elsif new.status is null and new.status_type_id is not null then
    select code into new.status from appointment_status_types where id = new.status_type_id;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_sync_appointment_types on appointments;
create trigger trg_sync_appointment_types
before insert or update of source, source_type_id, status, status_type_id
on appointments
for each row execute function tg_sync_appointment_types();

create or replace function tg_sync_contact_patient_link_types()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.relationship_type_id is null and new.relationship_type is not null then
    select id, code
    into new.relationship_type_id, new.relationship_type_code
    from relationship_types
    where code = lower(new.relationship_type)
    limit 1;
  elsif new.relationship_type is null and new.relationship_type_id is not null then
    select code into new.relationship_type from relationship_types where id = new.relationship_type_id;
    new.relationship_type_code := new.relationship_type;
  else
    new.relationship_type_code := coalesce(new.relationship_type_code, new.relationship_type);
  end if;

  return new;
end;
$$;

drop trigger if exists trg_sync_contact_patient_link_types on contact_patient_links;
create trigger trg_sync_contact_patient_link_types
before insert or update of relationship_type, relationship_type_id
on contact_patient_links
for each row execute function tg_sync_contact_patient_link_types();

create or replace function tg_sync_specialist_policy_types()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.policy_scope_type_id is null and new.policy_scope is not null then
    select id into new.policy_scope_type_id
    from policy_scope_types
    where code = lower(new.policy_scope)
    limit 1;
  elsif new.policy_scope is null and new.policy_scope_type_id is not null then
    select code into new.policy_scope from policy_scope_types where id = new.policy_scope_type_id;
  end if;

  if new.window_type_id is null and new.window_type is not null then
    select id into new.window_type_id
    from policy_window_types
    where code = lower(new.window_type)
    limit 1;
  elsif new.window_type is null and new.window_type_id is not null then
    select code into new.window_type from policy_window_types where id = new.window_type_id;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_sync_specialist_policy_types on specialist_duplicate_policies;
create trigger trg_sync_specialist_policy_types
before insert or update of policy_scope, policy_scope_type_id, window_type, window_type_id
on specialist_duplicate_policies
for each row execute function tg_sync_specialist_policy_types();

create or replace function tg_sync_channel_message_types()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.source_type_id is null and new.source is not null then
    select id into new.source_type_id
    from appointment_source_types
    where code = lower(new.source)
    limit 1;
  elsif new.source is null and new.source_type_id is not null then
    select code into new.source from appointment_source_types where id = new.source_type_id;
  end if;

  if new.direction_type_id is null and new.direction is not null then
    select id into new.direction_type_id
    from message_direction_types
    where code = lower(new.direction)
    limit 1;
  elsif new.direction is null and new.direction_type_id is not null then
    select code into new.direction from message_direction_types where id = new.direction_type_id;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_sync_channel_message_types on channel_messages;
create trigger trg_sync_channel_message_types
before insert or update of source, source_type_id, direction, direction_type_id
on channel_messages
for each row execute function tg_sync_channel_message_types();

create or replace function tg_sync_appointment_event_types()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.source_type_id is null and new.source is not null then
    select id into new.source_type_id
    from appointment_source_types
    where code = lower(new.source)
    limit 1;
  elsif new.source is null and new.source_type_id is not null then
    select code into new.source from appointment_source_types where id = new.source_type_id;
  end if;

  if new.actor_type_id is null and new.actor_type is not null then
    select id into new.actor_type_id
    from actor_types
    where code = lower(new.actor_type)
    limit 1;
  elsif new.actor_type is null and new.actor_type_id is not null then
    select code into new.actor_type from actor_types where id = new.actor_type_id;
  end if;

  if new.event_type_id is null and new.event_type is not null then
    select id into new.event_type_id
    from appointment_event_types
    where code = lower(new.event_type)
    limit 1;
  elsif new.event_type is null and new.event_type_id is not null then
    select code into new.event_type from appointment_event_types where id = new.event_type_id;
  end if;

  if new.event_type_id is null then
    new.event_type_id := 10;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_sync_appointment_event_types on appointment_events;
create trigger trg_sync_appointment_event_types
before insert or update of source, source_type_id, actor_type, actor_type_id, event_type, event_type_id
on appointment_events
for each row execute function tg_sync_appointment_event_types();

-- ---------- Phone normalization triggers ----------

create or replace function tg_sync_contacts_phone()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.phone_e164 is null and new.wa_id is not null then
    new.phone_e164 := normalize_phone_e164(new.wa_id);
  else
    new.phone_e164 := normalize_phone_e164(new.phone_e164);
  end if;

  new.phone_digits := normalize_phone_digits(coalesce(new.phone_e164, new.wa_id));
  return new;
end;
$$;

drop trigger if exists trg_contacts_sync_phone on contacts;
create trigger trg_contacts_sync_phone
before insert or update of phone_e164, wa_id on contacts
for each row execute function tg_sync_contacts_phone();

create or replace function tg_sync_patients_phone()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.phone_e164 := normalize_phone_e164(new.phone_e164);
  new.phone_digits := normalize_phone_digits(new.phone_e164);
  return new;
end;
$$;

drop trigger if exists trg_patients_sync_phone on patients;
create trigger trg_patients_sync_phone
before insert or update of phone_e164 on patients
for each row execute function tg_sync_patients_phone();

-- ---------- Updated_at triggers ----------

drop trigger if exists trg_locations_updated_at on locations;
create trigger trg_locations_updated_at
before update on locations
for each row execute function set_updated_at();

drop trigger if exists trg_specialists_updated_at on specialists;
create trigger trg_specialists_updated_at
before update on specialists
for each row execute function set_updated_at();

drop trigger if exists trg_patients_updated_at on patients;
create trigger trg_patients_updated_at
before update on patients
for each row execute function set_updated_at();

drop trigger if exists trg_appointments_updated_at on appointments;
create trigger trg_appointments_updated_at
before update on appointments
for each row execute function set_updated_at();

drop trigger if exists trg_contact_patient_links_updated_at on contact_patient_links;
create trigger trg_contact_patient_links_updated_at
before update on contact_patient_links
for each row execute function set_updated_at();

-- ---------- Constraints and indexes ----------

drop index if exists idx_specialists_tenant_key_active;
create unique index if not exists idx_specialists_tenant_code_active
  on specialists (tenant_id, specialist_code)
  where deleted_at is null;

create index if not exists idx_specialists_tenant_location
  on specialists (tenant_id, location_id)
  where deleted_at is null;

create unique index if not exists idx_contacts_tenant_wa_active
  on contacts (tenant_id, wa_id)
  where wa_id is not null and deleted_at is null;

create index if not exists idx_contacts_tenant_phone_digits_active
  on contacts (tenant_id, phone_digits)
  where phone_digits is not null and deleted_at is null;

create unique index if not exists idx_contact_patient_links_primary_active
  on contact_patient_links (tenant_id, contact_id, patient_id)
  where deleted_at is null;

create index if not exists idx_contact_patient_links_contact_active
  on contact_patient_links (tenant_id, contact_id)
  where deleted_at is null;

create index if not exists idx_contact_patient_links_patient_active
  on contact_patient_links (tenant_id, patient_id)
  where deleted_at is null;

create index if not exists idx_appointments_tenant_specialist_starts
  on appointments (tenant_id, specialist_id, starts_at);

create index if not exists idx_appointments_tenant_patient_starts
  on appointments (tenant_id, patient_id, starts_at);

create index if not exists idx_appointments_active_for_reminders
  on appointments (tenant_id, status, starts_at)
  where deleted_at is null and status in ('pending', 'confirmed', 'rescheduled');

create index if not exists idx_appointments_active_for_reminders_type_ids
  on appointments (tenant_id, status_type_id, starts_at)
  where deleted_at is null;

create unique index if not exists idx_appointments_active_exact_duplicate_guard
  on appointments (tenant_id, patient_id, specialist_id, starts_at)
  where deleted_at is null
    and starts_at is not null
    and patient_id is not null
    and specialist_id is not null
    and status in ('pending', 'confirmed', 'rescheduled');

drop index if exists idx_events_idempotency;
create unique index if not exists idx_events_external_event_id
  on appointment_events (tenant_id, source, event_type, external_event_id)
  where external_event_id is not null;

create index if not exists idx_events_tenant_appointment_created
  on appointment_events (tenant_id, appointment_id, created_at);

create unique index if not exists idx_channel_messages_external
  on channel_messages (tenant_id, source, direction, external_message_id)
  where external_message_id is not null;

create unique index if not exists idx_channel_messages_external_type_ids
  on channel_messages (tenant_id, source_type_id, direction_type_id, external_message_id)
  where external_message_id is not null;

create index if not exists idx_channel_messages_contact_created
  on channel_messages (tenant_id, contact_id, created_at desc);

create unique index if not exists idx_specialist_duplicate_policy_active
  on specialist_duplicate_policies (tenant_id, specialist_id)
  where deleted_at is null and active = true;

create index if not exists idx_specialist_duplicate_policy_lookup
  on specialist_duplicate_policies (tenant_id, specialist_id, window_type)
  where deleted_at is null and active = true;

create index if not exists idx_specialist_duplicate_policy_lookup_type_ids
  on specialist_duplicate_policies (tenant_id, specialist_id, window_type_id)
  where deleted_at is null and active = true;

drop trigger if exists trg_specialist_duplicate_policies_updated_at on specialist_duplicate_policies;
create trigger trg_specialist_duplicate_policies_updated_at
before update on specialist_duplicate_policies
for each row execute function set_updated_at();

-- ---------- Duplicate policy enforcement ----------

create or replace function fn_find_window_conflict_appointment(
  p_tenant_id uuid,
  p_patient_id uuid,
  p_specialist_id uuid,
  p_starts_at timestamptz,
  p_source text default null,
  p_exclude_appointment_id uuid default null
)
returns uuid
language plpgsql
set search_path = public
as $$
declare
  v_policy_scope text;
  v_window_type text;
  v_window_days integer;
  v_timezone text;
  v_period_start timestamptz;
  v_period_end timestamptz;
  v_local_starts timestamp;
  v_conflict_id uuid;
begin
  select
    coalesce(p.policy_scope, pst.code),
    coalesce(p.window_type, pwt.code),
    p.window_days,
    coalesce(loc.timezone, s.timezone, 'America/Mexico_City')
  into
    v_policy_scope,
    v_window_type,
    v_window_days,
    v_timezone
  from specialist_duplicate_policies p
  join specialists s
    on s.id = p.specialist_id
   and s.tenant_id = p.tenant_id
  left join policy_scope_types pst
    on pst.id = p.policy_scope_type_id
  left join policy_window_types pwt
    on pwt.id = p.window_type_id
  left join locations loc
    on loc.id = s.location_id
   and loc.tenant_id = s.tenant_id
  where p.tenant_id = p_tenant_id
    and p.specialist_id = p_specialist_id
    and p.deleted_at is null
    and p.active = true
    and (
      p.enforce_for_sources is null
      or p_source is null
      or p_source = any(p.enforce_for_sources)
    )
  limit 1;

  if v_window_type is null or v_window_type = 'none' then
    return null;
  end if;

  if v_window_type = 'exact_slot' then
    select a.id
    into v_conflict_id
    from appointments a
    where a.tenant_id = p_tenant_id
      and a.patient_id = p_patient_id
      and a.deleted_at is null
      and a.status in ('pending', 'confirmed', 'rescheduled')
      and (p_exclude_appointment_id is null or a.id <> p_exclude_appointment_id)
      and (
        (v_policy_scope = 'same_specialist' and a.specialist_id = p_specialist_id)
        or v_policy_scope = 'all_specialists'
      )
      and a.starts_at = p_starts_at
    limit 1;

    return v_conflict_id;
  end if;

  if v_window_type = 'rolling_days' then
    v_period_start := p_starts_at;
    v_period_end := p_starts_at + make_interval(days => v_window_days);
  else
    v_local_starts := p_starts_at at time zone v_timezone;
    v_period_start := (
      case v_window_type
        when 'week' then date_trunc('week', v_local_starts)
        when 'month' then date_trunc('month', v_local_starts)
        when 'quarter' then date_trunc('quarter', v_local_starts)
        else v_local_starts
      end
    ) at time zone v_timezone;
    v_period_end := (
      case v_window_type
        when 'week' then date_trunc('week', v_local_starts) + interval '1 week'
        when 'month' then date_trunc('month', v_local_starts) + interval '1 month'
        when 'quarter' then date_trunc('quarter', v_local_starts) + interval '3 months'
        else v_local_starts + interval '1 second'
      end
    ) at time zone v_timezone;
  end if;

  select a.id
  into v_conflict_id
  from appointments a
  where a.tenant_id = p_tenant_id
    and a.patient_id = p_patient_id
    and a.deleted_at is null
    and a.status in ('pending', 'confirmed', 'rescheduled')
    and (p_exclude_appointment_id is null or a.id <> p_exclude_appointment_id)
    and (
      (v_policy_scope = 'same_specialist' and a.specialist_id = p_specialist_id)
      or v_policy_scope = 'all_specialists'
    )
    and a.starts_at >= v_period_start
    and a.starts_at < v_period_end
  limit 1;

  return v_conflict_id;
end;
$$;

create or replace function tg_enforce_duplicate_policy()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_conflict_id uuid;
begin
  if new.deleted_at is not null then
    return new;
  end if;

  if new.status not in ('pending', 'confirmed', 'rescheduled') then
    return new;
  end if;

  if new.tenant_id is null or new.patient_id is null or new.specialist_id is null or new.starts_at is null then
    return new;
  end if;

  v_conflict_id := fn_find_window_conflict_appointment(
    new.tenant_id,
    new.patient_id,
    new.specialist_id,
    new.starts_at,
    new.source,
    new.id
  );

  if v_conflict_id is not null then
    raise exception using
      errcode = '23514',
      message = 'Active appointment window conflict for patient',
      detail = 'Policy blocks more than one active appointment in the configured time window.',
      hint = 'Adjust specialist_duplicate_policies or reschedule/cancel the previous active appointment.';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_appointments_enforce_duplicate_policy on appointments;
create trigger trg_appointments_enforce_duplicate_policy
before insert or update of tenant_id, patient_id, specialist_id, starts_at, status, deleted_at, source
on appointments
for each row execute function tg_enforce_duplicate_policy();

-- ---------- Operational views ----------

-- security_invoker: RLS y permisos se evalúan como el usuario que consulta (Supabase / PG15+).
create or replace view v_active_appointments
with (security_invoker = true)
as
select
  a.id,
  a.tenant_id,
  a.patient_id,
  a.specialist_id,
  a.location_id,
  a.source,
  a.booking_uid,
  a.status,
  a.starts_at,
  a.ends_at,
  a.reason,
  a.created_at,
  a.updated_at
from appointments a
where a.deleted_at is null
  and a.status in ('pending', 'confirmed', 'rescheduled');

create or replace view v_contact_active_appointments
with (security_invoker = true)
as
with linked_patients as (
  select cpl.tenant_id, cpl.contact_id, cpl.patient_id
  from contact_patient_links cpl
  where cpl.deleted_at is null
  union
  select p.tenant_id, p.contact_id, p.id as patient_id
  from patients p
  where p.deleted_at is null and p.contact_id is not null
)
select
  lp.tenant_id,
  lp.contact_id,
  a.id as appointment_id,
  a.patient_id,
  a.specialist_id,
  a.location_id,
  a.booking_uid,
  a.status,
  a.starts_at,
  a.ends_at,
  a.source
from linked_patients lp
join appointments a
  on a.tenant_id = lp.tenant_id
 and a.patient_id = lp.patient_id
where a.deleted_at is null
  and a.status in ('pending', 'confirmed', 'rescheduled');

-- ---------- Safe workflow functions ----------

create or replace function fn_get_active_appointments_for_contact(
  p_tenant_id uuid,
  p_contact_id uuid
)
returns table (
  appointment_id uuid,
  patient_id uuid,
  specialist_id uuid,
  location_id uuid,
  booking_uid text,
  status text,
  starts_at timestamptz,
  ends_at timestamptz,
  source text
)
language sql
set search_path = public
as $$
  select
    v.appointment_id,
    v.patient_id,
    v.specialist_id,
    v.location_id,
    v.booking_uid,
    v.status,
    v.starts_at,
    v.ends_at,
    v.source
  from v_contact_active_appointments v
  where v.tenant_id = p_tenant_id
    and v.contact_id = p_contact_id
  order by v.starts_at asc nulls last;
$$;

create or replace function fn_cancel_appointment_by_booking_uid(
  p_tenant_id uuid,
  p_booking_uid text,
  p_cancel_reason text,
  p_source text default 'system',
  p_actor_type text default 'system',
  p_actor_ref text default null,
  p_external_event_id text default null
)
returns uuid
language plpgsql
set search_path = public
as $$
declare
  v_appointment_id uuid;
begin
  update appointments a
  set
    status = 'cancelled',
    cancel_reason = coalesce(p_cancel_reason, a.cancel_reason),
    updated_at = now()
  where a.tenant_id = p_tenant_id
    and a.booking_uid = p_booking_uid
    and a.deleted_at is null
    and a.status in ('pending', 'confirmed', 'rescheduled')
  returning a.id into v_appointment_id;

  if v_appointment_id is null then
    return null;
  end if;

  insert into appointment_events (
    id,
    tenant_id,
    appointment_id,
    source,
    event_type,
    external_ref,
    external_event_id,
    actor_type,
    actor_ref,
    raw_payload
  ) values (
    gen_random_uuid(),
    p_tenant_id,
    v_appointment_id,
    p_source,
    'appointment.cancelled',
    p_booking_uid,
    p_external_event_id,
    p_actor_type,
    p_actor_ref,
    jsonb_build_object('reason', p_cancel_reason)
  )
  on conflict do nothing;

  return v_appointment_id;
end;
$$;

create or replace function fn_reschedule_appointment_by_booking_uid(
  p_tenant_id uuid,
  p_booking_uid text,
  p_new_starts_at timestamptz,
  p_new_ends_at timestamptz,
  p_reason text,
  p_source text default 'system',
  p_actor_type text default 'system',
  p_actor_ref text default null,
  p_external_event_id text default null
)
returns uuid
language plpgsql
set search_path = public
as $$
declare
  v_appointment_id uuid;
begin
  update appointments a
  set
    starts_at = p_new_starts_at,
    ends_at = p_new_ends_at,
    status = 'rescheduled',
    metadata = coalesce(a.metadata, '{}'::jsonb) || jsonb_build_object('reschedule_reason', p_reason),
    updated_at = now()
  where a.tenant_id = p_tenant_id
    and a.booking_uid = p_booking_uid
    and a.deleted_at is null
    and a.status in ('pending', 'confirmed', 'rescheduled')
  returning a.id into v_appointment_id;

  if v_appointment_id is null then
    return null;
  end if;

  insert into appointment_events (
    id,
    tenant_id,
    appointment_id,
    source,
    event_type,
    external_ref,
    external_event_id,
    actor_type,
    actor_ref,
    raw_payload
  ) values (
    gen_random_uuid(),
    p_tenant_id,
    v_appointment_id,
    p_source,
    'appointment.rescheduled',
    p_booking_uid,
    p_external_event_id,
    p_actor_type,
    p_actor_ref,
    jsonb_build_object(
      'new_starts_at', p_new_starts_at,
      'new_ends_at', p_new_ends_at,
      'reason', p_reason
    )
  )
  on conflict do nothing;

  return v_appointment_id;
end;
$$;

create or replace function fn_find_duplicate_active_appointment(
  p_tenant_id uuid,
  p_patient_id uuid,
  p_specialist_id uuid,
  p_starts_at timestamptz
)
returns uuid
language sql
set search_path = public
as $$
  select a.id
  from appointments a
  where a.tenant_id = p_tenant_id
    and a.patient_id = p_patient_id
    and a.specialist_id = p_specialist_id
    and a.starts_at = p_starts_at
    and a.deleted_at is null
    and a.status in ('pending', 'confirmed', 'rescheduled')
  limit 1;
$$;
