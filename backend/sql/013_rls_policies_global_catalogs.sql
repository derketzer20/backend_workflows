-- =============================================================================
-- 013 — RLS: políticas de solo lectura en catálogos globales (sin tenant_id)
-- =============================================================================
-- Corrige Supabase Advisor: rls_enabled_no_policy (lint 0008).
-- Tablas: *_types y catálogos pequeños referenciados por FKs. Datos de
-- referencia; lectura para roles que pasan por PostgREST con RLS.
--
-- Ejecutar en Supabase SQL Editor después de tener RLS activado en esas tablas.
-- Idempotente: DROP POLICY IF EXISTS + CREATE POLICY.
--
-- Ajuste: si no quieres que `anon` lea catálogos, borra las líneas TO anon o
-- cambia cada política a solo TO authenticated.
-- =============================================================================

-- ---------- Catálogos: SELECT público en lectura (referencia) ----------

drop policy if exists "appointment_source_types_select_ref" on public.appointment_source_types;
create policy "appointment_source_types_select_ref"
  on public.appointment_source_types for select to anon, authenticated using (true);

drop policy if exists "appointment_status_types_select_ref" on public.appointment_status_types;
create policy "appointment_status_types_select_ref"
  on public.appointment_status_types for select to anon, authenticated using (true);

drop policy if exists "appointment_types_select_ref" on public.appointment_types;
create policy "appointment_types_select_ref"
  on public.appointment_types for select to anon, authenticated using (true);

drop policy if exists "relationship_types_select_ref" on public.relationship_types;
create policy "relationship_types_select_ref"
  on public.relationship_types for select to anon, authenticated using (true);

drop policy if exists "policy_scope_types_select_ref" on public.policy_scope_types;
create policy "policy_scope_types_select_ref"
  on public.policy_scope_types for select to anon, authenticated using (true);

drop policy if exists "policy_window_types_select_ref" on public.policy_window_types;
create policy "policy_window_types_select_ref"
  on public.policy_window_types for select to anon, authenticated using (true);

drop policy if exists "message_direction_types_select_ref" on public.message_direction_types;
create policy "message_direction_types_select_ref"
  on public.message_direction_types for select to anon, authenticated using (true);

drop policy if exists "actor_types_select_ref" on public.actor_types;
create policy "actor_types_select_ref"
  on public.actor_types for select to anon, authenticated using (true);

drop policy if exists "appointment_event_types_select_ref" on public.appointment_event_types;
create policy "appointment_event_types_select_ref"
  on public.appointment_event_types for select to anon, authenticated using (true);
