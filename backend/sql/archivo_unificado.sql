-- WARNING: This schema is for context only and is not meant to be run.
-- Table order and constraints may not be valid for execution.

CREATE TABLE public.actor_types (
  id smallint NOT NULL,
  code text NOT NULL UNIQUE,
  display_name text NOT NULL,
  CONSTRAINT actor_types_pkey PRIMARY KEY (id)
);
CREATE TABLE public.appointment_event_types (
  id smallint NOT NULL,
  code text NOT NULL UNIQUE,
  display_name text NOT NULL,
  CONSTRAINT appointment_event_types_pkey PRIMARY KEY (id)
);
CREATE TABLE public.appointment_events (
  id uuid NOT NULL,
  tenant_id uuid NOT NULL,
  appointment_id uuid,
  source text NOT NULL,
  source_type_id smallint,
  event_type text NOT NULL,
  event_type_id smallint,
  actor_type_id smallint,
  external_ref text,
  raw_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  external_event_id text,
  actor_type text CHECK (actor_type = ANY (ARRAY['patient'::text, 'specialist'::text, 'staff'::text, 'system'::text])),
  actor_ref text,
  CONSTRAINT appointment_events_pkey PRIMARY KEY (id),
  CONSTRAINT appointment_events_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id),
  CONSTRAINT appointment_events_appointment_id_fkey FOREIGN KEY (appointment_id) REFERENCES public.appointments(id),
  CONSTRAINT appointment_events_source_type_id_fkey FOREIGN KEY (source_type_id) REFERENCES public.appointment_source_types(id),
  CONSTRAINT appointment_events_event_type_id_fkey FOREIGN KEY (event_type_id) REFERENCES public.appointment_event_types(id),
  CONSTRAINT appointment_events_actor_type_id_fkey FOREIGN KEY (actor_type_id) REFERENCES public.actor_types(id)
);
CREATE TABLE public.appointment_source_types (
  id smallint NOT NULL,
  code text NOT NULL UNIQUE,
  display_name text NOT NULL,
  CONSTRAINT appointment_source_types_pkey PRIMARY KEY (id)
);
CREATE TABLE public.appointment_status_types (
  id smallint NOT NULL,
  code text NOT NULL UNIQUE,
  display_name text NOT NULL,
  is_active_status boolean NOT NULL DEFAULT false,
  CONSTRAINT appointment_status_types_pkey PRIMARY KEY (id)
);
CREATE TABLE public.appointment_types (
  id smallint NOT NULL,
  code text NOT NULL UNIQUE,
  display_name text NOT NULL,
  active boolean NOT NULL DEFAULT true,
  CONSTRAINT appointment_types_pkey PRIMARY KEY (id)
);
CREATE TABLE public.appointments (
  id uuid NOT NULL,
  tenant_id uuid NOT NULL,
  specialist_id uuid NOT NULL,
  patient_id uuid,
  source text NOT NULL CHECK (source = ANY (ARRAY['whatsapp'::text, 'voice_dialora'::text, 'calcom_web'::text, 'staff'::text])),
  source_type_id smallint,
  status text NOT NULL CHECK (status = ANY (ARRAY['pending'::text, 'confirmed'::text, 'rescheduled'::text, 'cancelled'::text, 'no_show'::text, 'completed'::text])),
  status_type_id smallint,
  appointment_type_id smallint,
  booking_uid text,
  starts_at timestamp with time zone,
  ends_at timestamp with time zone,
  pending_titular boolean NOT NULL DEFAULT false,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  location_id uuid,
  reason text,
  cancel_reason text,
  created_by text,
  deleted_at timestamp with time zone,
  channel_ref text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  CONSTRAINT appointments_pkey PRIMARY KEY (id),
  CONSTRAINT appointments_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id),
  CONSTRAINT appointments_specialist_id_fkey FOREIGN KEY (specialist_id) REFERENCES public.specialists(id),
  CONSTRAINT appointments_patient_id_fkey FOREIGN KEY (patient_id) REFERENCES public.patients(id),
  CONSTRAINT appointments_source_type_id_fkey FOREIGN KEY (source_type_id) REFERENCES public.appointment_source_types(id),
  CONSTRAINT appointments_status_type_id_fkey FOREIGN KEY (status_type_id) REFERENCES public.appointment_status_types(id),
  CONSTRAINT appointments_appointment_type_id_fkey FOREIGN KEY (appointment_type_id) REFERENCES public.appointment_types(id),
  CONSTRAINT appointments_location_id_fkey FOREIGN KEY (location_id) REFERENCES public.locations(id)
);
CREATE TABLE public.bot_sessions (
  id uuid NOT NULL,
  tenant_id uuid NOT NULL,
  wa_id text NOT NULL,
  specialist_id uuid,
  current_step text NOT NULL DEFAULT 'ask_day'::text,
  state jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT bot_sessions_pkey PRIMARY KEY (id),
  CONSTRAINT bot_sessions_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id),
  CONSTRAINT bot_sessions_specialist_id_fkey FOREIGN KEY (specialist_id) REFERENCES public.specialists(id)
);
CREATE TABLE public.channel_messages (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  contact_id uuid,
  patient_id uuid,
  appointment_id uuid,
  source text NOT NULL CHECK (source = ANY (ARRAY['whatsapp'::text, 'voice_dialora'::text, 'calcom_web'::text, 'staff'::text])),
  direction text NOT NULL CHECK (direction = ANY (ARRAY['inbound'::text, 'outbound'::text])),
  external_message_id text,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  source_type_id smallint,
  direction_type_id smallint,
  CONSTRAINT channel_messages_pkey PRIMARY KEY (id),
  CONSTRAINT channel_messages_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id),
  CONSTRAINT channel_messages_contact_id_fkey FOREIGN KEY (contact_id) REFERENCES public.contacts(id),
  CONSTRAINT channel_messages_patient_id_fkey FOREIGN KEY (patient_id) REFERENCES public.patients(id),
  CONSTRAINT channel_messages_appointment_id_fkey FOREIGN KEY (appointment_id) REFERENCES public.appointments(id),
  CONSTRAINT channel_messages_source_type_id_fkey FOREIGN KEY (source_type_id) REFERENCES public.appointment_source_types(id),
  CONSTRAINT channel_messages_direction_type_id_fkey FOREIGN KEY (direction_type_id) REFERENCES public.message_direction_types(id)
);
CREATE TABLE public.contact_patient_links (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  contact_id uuid NOT NULL,
  patient_id uuid NOT NULL,
  relationship_type text NOT NULL DEFAULT 'titular'::text CHECK (relationship_type = ANY (ARRAY['titular'::text, 'familiar'::text, 'dependiente'::text, 'otro'::text])),
  can_manage_appointments boolean NOT NULL DEFAULT true,
  is_primary boolean NOT NULL DEFAULT false,
  notes text,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  deleted_at timestamp with time zone,
  relationship_type_id smallint,
  relationship_type_code text,
  CONSTRAINT contact_patient_links_pkey PRIMARY KEY (id),
  CONSTRAINT contact_patient_links_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id),
  CONSTRAINT contact_patient_links_contact_id_fkey FOREIGN KEY (contact_id) REFERENCES public.contacts(id),
  CONSTRAINT contact_patient_links_patient_id_fkey FOREIGN KEY (patient_id) REFERENCES public.patients(id),
  CONSTRAINT contact_patient_links_relationship_type_id_fkey FOREIGN KEY (relationship_type_id) REFERENCES public.relationship_types(id)
);
CREATE TABLE public.contacts (
  id uuid NOT NULL,
  tenant_id uuid NOT NULL,
  wa_id text,
  chat_id text,
  first_seen_at timestamp with time zone NOT NULL DEFAULT now(),
  last_seen_at timestamp with time zone NOT NULL DEFAULT now(),
  phone_e164 text,
  phone_digits text,
  channel_primary text CHECK (channel_primary = ANY (ARRAY['whatsapp'::text, 'voice_dialora'::text, 'calcom_web'::text, 'staff'::text])),
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  deleted_at timestamp with time zone,
  CONSTRAINT contacts_pkey PRIMARY KEY (id),
  CONSTRAINT contacts_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id)
);
CREATE TABLE public.locations (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  code text NOT NULL,
  display_name text NOT NULL,
  timezone text NOT NULL DEFAULT 'America/Mexico_City'::text,
  country_code text NOT NULL DEFAULT 'MX'::text,
  state_code text,
  city text,
  address_line text,
  active boolean NOT NULL DEFAULT true,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  deleted_at timestamp with time zone,
  CONSTRAINT locations_pkey PRIMARY KEY (id),
  CONSTRAINT locations_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id)
);
CREATE TABLE public.message_direction_types (
  id smallint NOT NULL,
  code text NOT NULL UNIQUE,
  display_name text NOT NULL,
  CONSTRAINT message_direction_types_pkey PRIMARY KEY (id)
);
CREATE TABLE public.patients (
  id uuid NOT NULL,
  tenant_id uuid NOT NULL,
  contact_id uuid NOT NULL,
  full_name text,
  birth_date date,
  phone_e164 text,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  phone_digits text,
  email text,
  gender text CHECK (gender = ANY (ARRAY['male'::text, 'female'::text, 'other'::text, 'unknown'::text])),
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  deleted_at timestamp with time zone,
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  last_appointment_starts_at timestamp with time zone,
  next_appointment_starts_at timestamp with time zone,
  active_appointment_count integer NOT NULL DEFAULT 0,
  has_active_appointment boolean NOT NULL DEFAULT false,
  CONSTRAINT patients_pkey PRIMARY KEY (id),
  CONSTRAINT patients_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id),
  CONSTRAINT patients_contact_id_fkey FOREIGN KEY (contact_id) REFERENCES public.contacts(id)
);
CREATE TABLE public.policy_scope_types (
  id smallint NOT NULL,
  code text NOT NULL UNIQUE,
  display_name text NOT NULL,
  CONSTRAINT policy_scope_types_pkey PRIMARY KEY (id)
);
CREATE TABLE public.policy_window_types (
  id smallint NOT NULL,
  code text NOT NULL UNIQUE,
  display_name text NOT NULL,
  requires_days boolean NOT NULL DEFAULT false,
  CONSTRAINT policy_window_types_pkey PRIMARY KEY (id)
);
CREATE TABLE public.relationship_types (
  id smallint NOT NULL,
  code text NOT NULL UNIQUE,
  display_name text NOT NULL,
  CONSTRAINT relationship_types_pkey PRIMARY KEY (id)
);
CREATE TABLE public.specialist_duplicate_policies (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  specialist_id uuid NOT NULL,
  policy_scope text NOT NULL DEFAULT 'same_specialist'::text CHECK (policy_scope = ANY (ARRAY['same_specialist'::text, 'all_specialists'::text])),
  window_type text NOT NULL DEFAULT 'exact_slot'::text CHECK (window_type = ANY (ARRAY['none'::text, 'exact_slot'::text, 'week'::text, 'month'::text, 'quarter'::text, 'rolling_days'::text])),
  window_days integer,
  enforce_for_sources ARRAY,
  active boolean NOT NULL DEFAULT true,
  allow_override_by_staff boolean NOT NULL DEFAULT false,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  deleted_at timestamp with time zone,
  policy_scope_type_id smallint,
  window_type_id smallint,
  CONSTRAINT specialist_duplicate_policies_pkey PRIMARY KEY (id),
  CONSTRAINT specialist_duplicate_policies_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id),
  CONSTRAINT specialist_duplicate_policies_specialist_id_fkey FOREIGN KEY (specialist_id) REFERENCES public.specialists(id),
  CONSTRAINT specialist_duplicate_policies_policy_scope_type_id_fkey FOREIGN KEY (policy_scope_type_id) REFERENCES public.policy_scope_types(id),
  CONSTRAINT specialist_duplicate_policies_window_type_id_fkey FOREIGN KEY (window_type_id) REFERENCES public.policy_window_types(id)
);
CREATE TABLE public.specialists (
  id uuid NOT NULL,
  tenant_id uuid NOT NULL,
  specialist_key text NOT NULL,
  display_name text NOT NULL,
  timezone text NOT NULL DEFAULT 'America/Mexico_City'::text,
  calcom_event_type_id text,
  specialist_code text NOT NULL,
  location_id uuid,
  email text,
  phone_e164 text,
  deleted_at timestamp with time zone,
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT specialists_pkey PRIMARY KEY (id),
  CONSTRAINT specialists_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id),
  CONSTRAINT specialists_location_id_fkey FOREIGN KEY (location_id) REFERENCES public.locations(id)
);
CREATE TABLE public.tenants (
  id uuid NOT NULL,
  name text NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT tenants_pkey PRIMARY KEY (id)
);