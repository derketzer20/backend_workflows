-- Consultas para revisar datos del seed (CorpOS Monterrey / Dr. Juan).
-- Reemplaza el UUID si tu tenant es otro.
-- Compatible con psql, Supabase SQL Editor, DBeaver, etc. (sin \set).

-- =============================================================================
-- Bloque 1: por tabla (mismo tenant_id en todas)
-- =============================================================================

select 'tenants' as tabla, count(*)::bigint as filas
from tenants
where id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid;

select *
from tenants
where id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid;

select 'locations' as tabla, count(*)::bigint as filas
from locations
where tenant_id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid;

select *
from locations
where tenant_id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid
order by code;

select 'specialists' as tabla, count(*)::bigint as filas
from specialists
where tenant_id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid;

select *
from specialists
where tenant_id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid
order by specialist_code;

select 'specialist_duplicate_policies' as tabla, count(*)::bigint as filas
from specialist_duplicate_policies
where tenant_id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid and deleted_at is null;

select *
from specialist_duplicate_policies
where tenant_id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid
order by specialist_id;

select 'contacts' as tabla, count(*)::bigint as filas
from contacts
where tenant_id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid;

select id, wa_id, phone_digits, phone_e164, channel_primary, deleted_at
from contacts
where tenant_id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid
order by phone_digits;

select 'patients' as tabla, count(*)::bigint as filas
from patients
where tenant_id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid;

select
  id,
  contact_id,
  full_name,
  birth_date,
  email,
  last_appointment_starts_at,
  next_appointment_starts_at,
  active_appointment_count,
  has_active_appointment,
  metadata->>'crm_rol_paciente' as crm_rol,
  metadata->>'crm_numero_citas' as crm_numero_citas
from patients
where tenant_id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid
  and deleted_at is null
order by full_name;

select 'contact_patient_links' as tabla, count(*)::bigint as filas
from contact_patient_links
where tenant_id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid and deleted_at is null;

select *
from contact_patient_links
where tenant_id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid
  and deleted_at is null
order by contact_id;

select 'appointments' as tabla, count(*)::bigint as filas
from appointments
where tenant_id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid;

select
  id,
  patient_id,
  status,
  booking_uid,
  starts_at,
  ends_at,
  source,
  deleted_at
from appointments
where tenant_id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid
order by starts_at nulls last;

-- =============================================================================
-- Bloque 2: vistas del repo (requieren migraciones 002 / 004)
-- =============================================================================

select * from v_active_appointments
where tenant_id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid
order by starts_at nulls last;

-- Requiere migración 004
select * from v_patients_with_contact_role
where tenant_id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid
order by full_name;

-- =============================================================================
-- Bloque 3: uniones (una fila por paciente con contexto)
-- =============================================================================

select
  p.id as patient_id,
  p.full_name,
  c.phone_digits,
  c.wa_id,
  coalesce(cpl.relationship_type, '(sin link)') as relationship_type,
  p.birth_date,
  p.email,
  p.last_appointment_starts_at,
  p.next_appointment_starts_at,
  p.active_appointment_count,
  p.has_active_appointment,
  s.specialist_code,
  loc.code as location_code,
  count(a.id) filter (where a.deleted_at is null) as appointments_count
from patients p
join contacts c on c.id = p.contact_id and c.tenant_id = p.tenant_id
left join contact_patient_links cpl
  on cpl.patient_id = p.id
 and cpl.contact_id = p.contact_id
 and cpl.tenant_id = p.tenant_id
 and cpl.deleted_at is null
left join specialists s
  on s.tenant_id = p.tenant_id and s.deleted_at is null
left join locations loc on loc.id = s.location_id and loc.tenant_id = p.tenant_id
left join appointments a on a.patient_id = p.id and a.tenant_id = p.tenant_id
where p.tenant_id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid
  and p.deleted_at is null
group by
  p.id, p.full_name, c.phone_digits, c.wa_id, cpl.relationship_type,
  p.birth_date, p.email,
  p.last_appointment_starts_at, p.next_appointment_starts_at,
  p.active_appointment_count, p.has_active_appointment,
  s.specialist_code, loc.code
order by c.phone_digits;

-- Citas con paciente, teléfono y doctor (detalle operativo)
select
  a.starts_at at time zone 'America/Monterrey' as inicio_local_mty,
  a.ends_at at time zone 'America/Monterrey' as fin_local_mty,
  a.status,
  p.full_name as paciente,
  c.phone_digits,
  s.specialist_code,
  a.booking_uid,
  a.id as appointment_id
from appointments a
join patients p on p.id = a.patient_id
join contacts c on c.id = p.contact_id
join specialists s on s.id = a.specialist_id
where a.tenant_id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid
  and a.deleted_at is null
order by a.starts_at nulls last;

-- =============================================================================
-- Bloque 4: resumen conteos en una sola fila (útil para Make / checklist)
-- =============================================================================

select
  (select count(*) from tenants where id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid) as tenants,
  (select count(*) from locations where tenant_id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid and deleted_at is null) as locations,
  (select count(*) from specialists where tenant_id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid and deleted_at is null) as specialists,
  (select count(*) from contacts where tenant_id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid and deleted_at is null) as contacts,
  (select count(*) from patients where tenant_id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid and deleted_at is null) as patients,
  (select count(*) from contact_patient_links where tenant_id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid and deleted_at is null) as links,
  (select count(*) from appointments where tenant_id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid and deleted_at is null) as appointments;
