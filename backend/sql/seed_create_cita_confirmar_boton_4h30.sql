-- =============================================================================
-- Nueva cita de prueba — contacto 90b5cc77… — inicio en 4h 30m (hora MX → UTC +00)
-- Para recordatorio 4h en ~30 min (cron cada 15 min) y confirmar por botón WhatsApp.
-- =============================================================================
-- contact_id:  90b5cc77-b08d-450c-b492-ce0d89ff78e7
-- patient_id:  b2000000-0000-4000-8000-000000000098
-- appointment: a1000000-0000-4000-8000-000000000099 (reutiliza fila de prueba)
-- specialist:  dr_juan_carlos
-- BotSailor confirmar:
--   p_numero: 5215565062809
--   p_specialist_code: dr_juan_carlos
--   p_status: confirmado
-- =============================================================================

begin;

update contacts
set
  phone_e164 = coalesce(nullif(trim(phone_e164), ''), '+525565062809'),
  wa_id = coalesce(nullif(trim(wa_id), ''), '5215565062809'),
  channel_primary = coalesce(channel_primary, 'whatsapp'),
  last_seen_at = now()
where id = '90b5cc77-b08d-450c-b492-ce0d89ff78e7'::uuid
  and deleted_at is null;

insert into patients (
  id, tenant_id, contact_id, full_name, phone_e164, gender, metadata
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
  contact_id = excluded.contact_id,
  deleted_at = null,
  updated_at = now();

delete from appointment_reminder_dispatches
where appointment_id = 'a1000000-0000-4000-8000-000000000099'::uuid;

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
  cancel_reason,
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
  'pending',
  1,
  'TEST-REMINDER-4H-CONFIRM-5565062809',
  (
    date_trunc('minute', (timezone('America/Monterrey', now()) + interval '4 hours 30 minutes'))
    at time zone 'America/Monterrey'
  ),
  (
    date_trunc('minute', (timezone('America/Monterrey', now()) + interval '5 hours'))
    at time zone 'America/Monterrey'
  ),
  'Cita prueba: recordatorio 4h + confirmar botón',
  null,
  jsonb_build_object(
    'test_reminder', true,
    'contact_id', c.id::text
  )
from contacts c
cross join lateral (
  select s.id, s.location_id
  from specialists s
  where s.tenant_id = c.tenant_id
    and s.deleted_at is null
    and lower(s.specialist_code) = 'dr_juan_carlos'
  limit 1
) sp
where c.id = '90b5cc77-b08d-450c-b492-ce0d89ff78e7'::uuid
  and c.deleted_at is null
on conflict (id) do update set
  tenant_id = excluded.tenant_id,
  specialist_id = excluded.specialist_id,
  patient_id = excluded.patient_id,
  location_id = excluded.location_id,
  status = excluded.status,
  status_type_id = excluded.status_type_id,
  booking_uid = excluded.booking_uid,
  starts_at = excluded.starts_at,
  ends_at = excluded.ends_at,
  reason = excluded.reason,
  cancel_reason = null,
  deleted_at = null,
  metadata = excluded.metadata,
  updated_at = now();

commit;

select
  'cita' as paso,
  a.id,
  a.booking_uid,
  a.status,
  a.status_type_id,
  s.specialist_code,
  a.starts_at,
  a.ends_at,
  a.starts_at at time zone 'America/Monterrey' as inicio_mx,
  a.ends_at at time zone 'America/Monterrey' as fin_mx,
  a.starts_at - now() as falta_para_cita,
  now() + interval '4 hours' as ventana_recordatorio_4h_desde
from appointments a
join specialists s on s.id = a.specialist_id
where a.id = 'a1000000-0000-4000-8000-000000000099'::uuid;

-- Opcional: forzar recordatorio 4h cuando falten ~4h (o esperar cron ~30 min):
-- select fn_dispatch_appointment_reminders('4h', 15);
