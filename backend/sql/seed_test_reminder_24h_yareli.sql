-- =============================================================================
-- Prueba recordatorio — paciente + cita (contacto existente)
-- =============================================================================
-- contact_id: 90b5cc77-b08d-450c-b492-ce0d89ff78e7
-- patient_id:  b2000000-0000-4000-8000-000000000098
-- appointment: a1000000-0000-4000-8000-000000000099
--
-- Ejecutar en Supabase SQL Editor (bloque completo).
-- Prueba recordatorio: select fn_dispatch_appointment_reminders('24h', 15);
-- (Para probar ya: cita a now()+24h — ver UPDATE opcional al final)
-- =============================================================================

begin;

-- Teléfono en contacto (fn_dispatch lee contacts vía patients.contact_id)
update contacts
set
  phone_e164 = '+525565062809',
  wa_id = coalesce(nullif(trim(wa_id), ''), '5215565062809'),
  channel_primary = coalesce(channel_primary, 'whatsapp'),
  last_seen_at = now()
where id = '90b5cc77-b08d-450c-b492-ce0d89ff78e7'::uuid
  and deleted_at is null;

-- ---------- 1) Paciente ----------
insert into patients (
  id,
  tenant_id,
  contact_id,
  full_name,
  phone_e164,
  gender,
  metadata
)
select
  'b2000000-0000-4000-8000-000000000098'::uuid,
  c.tenant_id,
  c.id,
  coalesce(nullif(trim(c.metadata->>'full_name'), ''), 'Paciente prueba recordatorio'),
  '+525565062809',
  'unknown',
  '{"test_reminder": true}'::jsonb
from contacts c
where c.id = '90b5cc77-b08d-450c-b492-ce0d89ff78e7'::uuid
  and c.deleted_at is null
on conflict (id) do update set
  tenant_id = excluded.tenant_id,
  contact_id = excluded.contact_id,
  full_name = excluded.full_name,
  phone_e164 = excluded.phone_e164,
  deleted_at = null,
  updated_at = now();

-- Si 0 filas arriba: el contact_id no existe o está borrado (deleted_at).

-- ---------- 2) Cita (mañana 08:00 CDMX) ----------
insert into appointments (
  id,
  tenant_id,
  specialist_id,
  patient_id,
  location_id,
  source,
  source_type_id,
  status,
  status_type_id,
  booking_uid,
  starts_at,
  ends_at,
  reason,
  metadata
)
select
  'a1000000-0000-4000-8000-000000000099'::uuid,
  c.tenant_id,
  sp.id,
  'b2000000-0000-4000-8000-000000000098'::uuid,
  sp.location_id,
  'whatsapp',
  1,
  'confirmed',
  2,
  'TEST-REMINDER-24H-5565062809',
  ((current_date + interval '1 day')::date + time '08:00') at time zone 'America/Mexico_City',
  ((current_date + interval '1 day')::date + time '08:30') at time zone 'America/Mexico_City',
  'Cita prueba recordatorio 24h',
  jsonb_build_object('test_reminder', true, 'contact_id', c.id::text)
from contacts c
cross join lateral (
  select s.id, s.location_id
  from specialists s
  where s.tenant_id = c.tenant_id
    and s.deleted_at is null
  order by s.id
  limit 1
) sp
where c.id = '90b5cc77-b08d-450c-b492-ce0d89ff78e7'::uuid
  and c.deleted_at is null
on conflict (id) do update set
  patient_id = excluded.patient_id,
  specialist_id = excluded.specialist_id,
  location_id = excluded.location_id,
  starts_at = excluded.starts_at,
  ends_at = excluded.ends_at,
  status = excluded.status,
  status_type_id = excluded.status_type_id,
  booking_uid = excluded.booking_uid,
  deleted_at = null,
  updated_at = now();

delete from appointment_reminder_dispatches
where appointment_id = 'a1000000-0000-4000-8000-000000000099'::uuid
  and reminder_kind = '24h';

commit;

-- ---------- Verificación ----------
select 'contacto' as paso, c.id, c.tenant_id, c.phone_e164, c.wa_id
from contacts c
where c.id = '90b5cc77-b08d-450c-b492-ce0d89ff78e7'::uuid;

select 'paciente' as paso, p.id, p.tenant_id, p.contact_id, p.full_name
from patients p
where p.id = 'b2000000-0000-4000-8000-000000000098'::uuid;

select
  'cita' as paso,
  a.id,
  a.patient_id,
  a.booking_uid,
  a.starts_at at time zone 'America/Mexico_City' as inicio_cdmx,
  a.status,
  a.starts_at - now() as falta_para_cita
from appointments a
where a.id = 'a1000000-0000-4000-8000-000000000099'::uuid;

-- Si "paciente" o "cita" no devuelven filas, revisa:
--   select id, tenant_id, deleted_at from contacts where id = '90b5cc77-...';
--   select id, tenant_id from specialists where tenant_id = '<tenant del contacto>';

-- ---------- Opcional: forzar ventana 24h para probar fn_dispatch YA ----------
/*
update appointments
set
  starts_at = now() + interval '24 hours',
  ends_at = now() + interval '24 hours 30 minutes'
where id = 'a1000000-0000-4000-8000-000000000099'::uuid;

delete from appointment_reminder_dispatches
where appointment_id = 'a1000000-0000-4000-8000-000000000099'::uuid;

select fn_dispatch_appointment_reminders('24h', 15);
*/
