-- =============================================================================
-- 014 — RLS: aislamiento por tenant (JWT) en tablas con tenant_id
-- =============================================================================
-- Corrige rls_enabled_no_policy para datos multi-tenant.
--
-- Requisito: el JWT del usuario debe incluir tenant_id, por ejemplo:
--   auth.jwt() -> 'app_metadata' ->> 'tenant_id'
--   o auth.jwt() -> 'user_metadata' ->> 'tenant_id'
-- Si no existe, no verá filas (seguro por defecto). Configura el claim en
-- Auth (Custom Access Token Hooks / app_metadata al crear usuario).
--
-- NO afecta a la service_role: en Supabase bypassa RLS (Make / backend con
-- service key sigue igual).
--
-- Idempotente: DROP POLICY IF EXISTS + CREATE POLICY.
-- =============================================================================

create or replace function public.jwt_tenant_id()
returns uuid
language sql
stable
security invoker
set search_path = public
as $$
  select nullif(
    coalesce(
      auth.jwt() -> 'app_metadata' ->> 'tenant_id',
      auth.jwt() -> 'user_metadata' ->> 'tenant_id'
    ),
    ''
  )::uuid;
$$;

comment on function public.jwt_tenant_id() is
  'UUID de tenant desde JWT (app_metadata o user_metadata). Usado en políticas RLS.';

revoke all on function public.jwt_tenant_id() from public;
grant execute on function public.jwt_tenant_id() to authenticated;

-- ---------- tenants: solo la fila del propio tenant ----------

drop policy if exists "tenants_select_own" on public.tenants;
create policy "tenants_select_own"
  on public.tenants for select to authenticated
  using (id = public.jwt_tenant_id());

-- ---------- Plantilla: CRUD por tenant_id (repite por tabla) ----------

-- specialists
drop policy if exists "specialists_select_tenant" on public.specialists;
drop policy if exists "specialists_insert_tenant" on public.specialists;
drop policy if exists "specialists_update_tenant" on public.specialists;
drop policy if exists "specialists_delete_tenant" on public.specialists;
create policy "specialists_select_tenant" on public.specialists for select to authenticated
  using (tenant_id = public.jwt_tenant_id());
create policy "specialists_insert_tenant" on public.specialists for insert to authenticated
  with check (tenant_id = public.jwt_tenant_id());
create policy "specialists_update_tenant" on public.specialists for update to authenticated
  using (tenant_id = public.jwt_tenant_id()) with check (tenant_id = public.jwt_tenant_id());
create policy "specialists_delete_tenant" on public.specialists for delete to authenticated
  using (tenant_id = public.jwt_tenant_id());

-- contacts
drop policy if exists "contacts_select_tenant" on public.contacts;
drop policy if exists "contacts_insert_tenant" on public.contacts;
drop policy if exists "contacts_update_tenant" on public.contacts;
drop policy if exists "contacts_delete_tenant" on public.contacts;
create policy "contacts_select_tenant" on public.contacts for select to authenticated
  using (tenant_id = public.jwt_tenant_id());
create policy "contacts_insert_tenant" on public.contacts for insert to authenticated
  with check (tenant_id = public.jwt_tenant_id());
create policy "contacts_update_tenant" on public.contacts for update to authenticated
  using (tenant_id = public.jwt_tenant_id()) with check (tenant_id = public.jwt_tenant_id());
create policy "contacts_delete_tenant" on public.contacts for delete to authenticated
  using (tenant_id = public.jwt_tenant_id());

-- patients
drop policy if exists "patients_select_tenant" on public.patients;
drop policy if exists "patients_insert_tenant" on public.patients;
drop policy if exists "patients_update_tenant" on public.patients;
drop policy if exists "patients_delete_tenant" on public.patients;
create policy "patients_select_tenant" on public.patients for select to authenticated
  using (tenant_id = public.jwt_tenant_id());
create policy "patients_insert_tenant" on public.patients for insert to authenticated
  with check (tenant_id = public.jwt_tenant_id());
create policy "patients_update_tenant" on public.patients for update to authenticated
  using (tenant_id = public.jwt_tenant_id()) with check (tenant_id = public.jwt_tenant_id());
create policy "patients_delete_tenant" on public.patients for delete to authenticated
  using (tenant_id = public.jwt_tenant_id());

-- appointments
drop policy if exists "appointments_select_tenant" on public.appointments;
drop policy if exists "appointments_insert_tenant" on public.appointments;
drop policy if exists "appointments_update_tenant" on public.appointments;
drop policy if exists "appointments_delete_tenant" on public.appointments;
create policy "appointments_select_tenant" on public.appointments for select to authenticated
  using (tenant_id = public.jwt_tenant_id());
create policy "appointments_insert_tenant" on public.appointments for insert to authenticated
  with check (tenant_id = public.jwt_tenant_id());
create policy "appointments_update_tenant" on public.appointments for update to authenticated
  using (tenant_id = public.jwt_tenant_id()) with check (tenant_id = public.jwt_tenant_id());
create policy "appointments_delete_tenant" on public.appointments for delete to authenticated
  using (tenant_id = public.jwt_tenant_id());

-- appointment_events
drop policy if exists "appointment_events_select_tenant" on public.appointment_events;
drop policy if exists "appointment_events_insert_tenant" on public.appointment_events;
drop policy if exists "appointment_events_update_tenant" on public.appointment_events;
drop policy if exists "appointment_events_delete_tenant" on public.appointment_events;
create policy "appointment_events_select_tenant" on public.appointment_events for select to authenticated
  using (tenant_id = public.jwt_tenant_id());
create policy "appointment_events_insert_tenant" on public.appointment_events for insert to authenticated
  with check (tenant_id = public.jwt_tenant_id());
create policy "appointment_events_update_tenant" on public.appointment_events for update to authenticated
  using (tenant_id = public.jwt_tenant_id()) with check (tenant_id = public.jwt_tenant_id());
create policy "appointment_events_delete_tenant" on public.appointment_events for delete to authenticated
  using (tenant_id = public.jwt_tenant_id());

-- channel_messages
drop policy if exists "channel_messages_select_tenant" on public.channel_messages;
drop policy if exists "channel_messages_insert_tenant" on public.channel_messages;
drop policy if exists "channel_messages_update_tenant" on public.channel_messages;
drop policy if exists "channel_messages_delete_tenant" on public.channel_messages;
create policy "channel_messages_select_tenant" on public.channel_messages for select to authenticated
  using (tenant_id = public.jwt_tenant_id());
create policy "channel_messages_insert_tenant" on public.channel_messages for insert to authenticated
  with check (tenant_id = public.jwt_tenant_id());
create policy "channel_messages_update_tenant" on public.channel_messages for update to authenticated
  using (tenant_id = public.jwt_tenant_id()) with check (tenant_id = public.jwt_tenant_id());
create policy "channel_messages_delete_tenant" on public.channel_messages for delete to authenticated
  using (tenant_id = public.jwt_tenant_id());

-- contact_patient_links
drop policy if exists "contact_patient_links_select_tenant" on public.contact_patient_links;
drop policy if exists "contact_patient_links_insert_tenant" on public.contact_patient_links;
drop policy if exists "contact_patient_links_update_tenant" on public.contact_patient_links;
drop policy if exists "contact_patient_links_delete_tenant" on public.contact_patient_links;
create policy "contact_patient_links_select_tenant" on public.contact_patient_links for select to authenticated
  using (tenant_id = public.jwt_tenant_id());
create policy "contact_patient_links_insert_tenant" on public.contact_patient_links for insert to authenticated
  with check (tenant_id = public.jwt_tenant_id());
create policy "contact_patient_links_update_tenant" on public.contact_patient_links for update to authenticated
  using (tenant_id = public.jwt_tenant_id()) with check (tenant_id = public.jwt_tenant_id());
create policy "contact_patient_links_delete_tenant" on public.contact_patient_links for delete to authenticated
  using (tenant_id = public.jwt_tenant_id());

-- locations
drop policy if exists "locations_select_tenant" on public.locations;
drop policy if exists "locations_insert_tenant" on public.locations;
drop policy if exists "locations_update_tenant" on public.locations;
drop policy if exists "locations_delete_tenant" on public.locations;
create policy "locations_select_tenant" on public.locations for select to authenticated
  using (tenant_id = public.jwt_tenant_id());
create policy "locations_insert_tenant" on public.locations for insert to authenticated
  with check (tenant_id = public.jwt_tenant_id());
create policy "locations_update_tenant" on public.locations for update to authenticated
  using (tenant_id = public.jwt_tenant_id()) with check (tenant_id = public.jwt_tenant_id());
create policy "locations_delete_tenant" on public.locations for delete to authenticated
  using (tenant_id = public.jwt_tenant_id());

-- specialist_codes
drop policy if exists "specialist_codes_select_tenant" on public.specialist_codes;
drop policy if exists "specialist_codes_insert_tenant" on public.specialist_codes;
drop policy if exists "specialist_codes_update_tenant" on public.specialist_codes;
drop policy if exists "specialist_codes_delete_tenant" on public.specialist_codes;
create policy "specialist_codes_select_tenant" on public.specialist_codes for select to authenticated
  using (tenant_id = public.jwt_tenant_id());
create policy "specialist_codes_insert_tenant" on public.specialist_codes for insert to authenticated
  with check (tenant_id = public.jwt_tenant_id());
create policy "specialist_codes_update_tenant" on public.specialist_codes for update to authenticated
  using (tenant_id = public.jwt_tenant_id()) with check (tenant_id = public.jwt_tenant_id());
create policy "specialist_codes_delete_tenant" on public.specialist_codes for delete to authenticated
  using (tenant_id = public.jwt_tenant_id());

-- specialist_duplicate_policies
drop policy if exists "specialist_duplicate_policies_select_tenant" on public.specialist_duplicate_policies;
drop policy if exists "specialist_duplicate_policies_insert_tenant" on public.specialist_duplicate_policies;
drop policy if exists "specialist_duplicate_policies_update_tenant" on public.specialist_duplicate_policies;
drop policy if exists "specialist_duplicate_policies_delete_tenant" on public.specialist_duplicate_policies;
create policy "specialist_duplicate_policies_select_tenant" on public.specialist_duplicate_policies for select to authenticated
  using (tenant_id = public.jwt_tenant_id());
create policy "specialist_duplicate_policies_insert_tenant" on public.specialist_duplicate_policies for insert to authenticated
  with check (tenant_id = public.jwt_tenant_id());
create policy "specialist_duplicate_policies_update_tenant" on public.specialist_duplicate_policies for update to authenticated
  using (tenant_id = public.jwt_tenant_id()) with check (tenant_id = public.jwt_tenant_id());
create policy "specialist_duplicate_policies_delete_tenant" on public.specialist_duplicate_policies for delete to authenticated
  using (tenant_id = public.jwt_tenant_id());

-- bot_sessions
drop policy if exists "bot_sessions_select_tenant" on public.bot_sessions;
drop policy if exists "bot_sessions_insert_tenant" on public.bot_sessions;
drop policy if exists "bot_sessions_update_tenant" on public.bot_sessions;
drop policy if exists "bot_sessions_delete_tenant" on public.bot_sessions;
create policy "bot_sessions_select_tenant" on public.bot_sessions for select to authenticated
  using (tenant_id = public.jwt_tenant_id());
create policy "bot_sessions_insert_tenant" on public.bot_sessions for insert to authenticated
  with check (tenant_id = public.jwt_tenant_id());
create policy "bot_sessions_update_tenant" on public.bot_sessions for update to authenticated
  using (tenant_id = public.jwt_tenant_id()) with check (tenant_id = public.jwt_tenant_id());
create policy "bot_sessions_delete_tenant" on public.bot_sessions for delete to authenticated
  using (tenant_id = public.jwt_tenant_id());
