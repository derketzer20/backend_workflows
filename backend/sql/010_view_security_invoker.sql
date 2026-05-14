-- =============================================================================
-- 010 — Vistas operativas con security_invoker (Supabase Advisor / RLS)
-- =============================================================================
-- Problema: en PostgreSQL 15+, una vista sin WITH (security_invoker = true) puede
--   hacer que RLS y permisos se evalúen en contexto del dueño de la vista
--   (equivalente a "Security Definer" en el linter de Supabase).
-- Solución: recrear la vista con WITH (security_invoker = true).
--
-- Requiere: PostgreSQL 15+ (Supabase Database por defecto).
-- Idempotente: CREATE OR REPLACE.
--
-- Si el Advisor marca otras vistas, alinear con 003_booking_validation_api.sql
-- y 004/005/007 (v_patients_with_contact_role), ya actualizadas en el repo.
-- =============================================================================

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
