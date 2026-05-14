-- =============================================================================
-- 011 — v_patients_with_contact_role con security_invoker (Supabase Advisor)
-- =============================================================================
-- Misma alerta que v_active_appointments: sin security_invoker, PG15+ puede
-- evaluar RLS como el dueño de la vista. Esto recrea la vista como INVOKER.
--
-- Requiere: PostgreSQL 15+ (Supabase). Tablas patients, contacts, contact_patient_links.
-- Idempotente: CREATE OR REPLACE.
-- =============================================================================

create or replace view v_patients_with_contact_role
with (security_invoker = true)
as
select
  p.id as patient_id,
  p.tenant_id,
  p.full_name,
  p.contact_id,
  c.phone_digits,
  c.wa_id,
  c.phone_e164,
  coalesce(cpl.relationship_type, 'titular') as relationship_type,
  coalesce(cpl.relationship_type_id, 1) as relationship_type_id,
  coalesce(cpl.relationship_type_code, cpl.relationship_type, 'titular') as relationship_type_code,
  coalesce(cpl.is_primary, true) as is_primary,
  p.last_appointment_starts_at,
  p.next_appointment_starts_at,
  p.active_appointment_count,
  p.has_active_appointment,
  p.metadata
from patients p
join contacts c
  on c.id = p.contact_id
 and c.tenant_id = p.tenant_id
 and c.deleted_at is null
left join contact_patient_links cpl
  on cpl.patient_id = p.id
 and cpl.contact_id = p.contact_id
 and cpl.tenant_id = p.tenant_id
 and cpl.deleted_at is null
where p.deleted_at is null;

comment on view v_patients_with_contact_role is
  'Paciente con teléfono del contacto canónico y rol (titular/familiar/…) desde contact_patient_links; más cache de citas.';
