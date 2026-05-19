-- =============================================================================
-- Seed DEMO — alimenta v_contacto_panel_agenda_citas (tenant aislado)
-- =============================================================================
-- Ejecutar DESPUÉS de: 001, 002, 004 o 007, y 016_v_contacto_panel_agenda_citas.sql
-- Idempotente: UUID fijos + WHERE NOT EXISTS donde aplica.
-- =============================================================================

begin;

insert into tenants (id, name)
values ('b1000000-0000-4000-8000-000000000001', 'Tenant DEMO — vista panel')
on conflict (id) do nothing;

insert into locations (id, tenant_id, code, display_name, timezone, city, country_code)
values (
  'b1000000-0000-4000-8000-000000000002',
  'b1000000-0000-4000-8000-000000000001',
  'DEMO-CDMX',
  'Consultorio DEMO — Ciudad de México',
  'America/Mexico_City',
  'Ciudad de México',
  'MX'
)
-- Índice único en producción: (tenant_id, code) en tabla; usamos PK id para ON CONFLICT (portable).
on conflict (id) do nothing;

insert into specialists (id, tenant_id, specialist_key, display_name, timezone, specialist_code, location_id)
values (
  'b1000000-0000-4000-8000-000000000003',
  'b1000000-0000-4000-8000-000000000001',
  'dr',
  'Dra. Ana Pérez (demo)',
  'America/Mexico_City',
  'dra_demo_panel',
  'b1000000-0000-4000-8000-000000000002'
)
-- Tras 002 ya no existe UNIQUE(tenant_id, specialist_key); el único activo es (tenant_id, specialist_code) parcial.
on conflict (id) do update set
  tenant_id = excluded.tenant_id,
  specialist_key = excluded.specialist_key,
  display_name = excluded.display_name,
  timezone = excluded.timezone,
  specialist_code = excluded.specialist_code,
  location_id = excluded.location_id,
  updated_at = now();

insert into specialist_duplicate_policies (tenant_id, specialist_id, policy_scope, window_type, active)
select
  'b1000000-0000-4000-8000-000000000001',
  'b1000000-0000-4000-8000-000000000003',
  'same_specialist',
  'exact_slot',
  true
where not exists (
  select 1 from specialist_duplicate_policies p
  where p.tenant_id = 'b1000000-0000-4000-8000-000000000001'::uuid
    and p.specialist_id = 'b1000000-0000-4000-8000-000000000003'::uuid
    and p.deleted_at is null
    and p.active = true
);

insert into contacts (id, tenant_id, wa_id, phone_e164, phone_digits, channel_primary, metadata)
values (
  'b1000000-0000-4000-8000-000000000010',
  'b1000000-0000-4000-8000-000000000001',
  '5215550000001',
  '+525550000001',
  '5550000001',
  'whatsapp',
  '{"demo":"v_contacto_panel_agenda_citas"}'::jsonb
)
on conflict (id) do nothing;

insert into patients (id, tenant_id, contact_id, full_name, birth_date, gender, metadata)
values (
  'b1000000-0000-4000-8000-000000000011',
  'b1000000-0000-4000-8000-000000000001',
  'b1000000-0000-4000-8000-000000000010',
  'María Fernanda López',
  '1988-03-15'::date,
  'female',
  '{"demo":"titular"}'::jsonb
)
on conflict (id) do nothing;

insert into patients (id, tenant_id, contact_id, full_name, birth_date, gender, metadata)
values (
  'b1000000-0000-4000-8000-000000000012',
  'b1000000-0000-4000-8000-000000000001',
  'b1000000-0000-4000-8000-000000000010',
  'Diego López',
  '2015-11-02'::date,
  'male',
  '{"demo":"hijo"}'::jsonb
)
on conflict (id) do nothing;

insert into contact_patient_links (tenant_id, contact_id, patient_id, relationship_type, is_primary, relationship_type_id, relationship_type_code)
select
  'b1000000-0000-4000-8000-000000000001',
  'b1000000-0000-4000-8000-000000000010',
  'b1000000-0000-4000-8000-000000000011',
  'titular',
  true,
  1,
  'titular'
where not exists (
  select 1 from contact_patient_links l
  where l.tenant_id = 'b1000000-0000-4000-8000-000000000001'::uuid
    and l.contact_id = 'b1000000-0000-4000-8000-000000000010'::uuid
    and l.patient_id = 'b1000000-0000-4000-8000-000000000011'::uuid
    and l.deleted_at is null
);

insert into contact_patient_links (tenant_id, contact_id, patient_id, relationship_type, is_primary, relationship_type_id, relationship_type_code)
select
  'b1000000-0000-4000-8000-000000000001',
  'b1000000-0000-4000-8000-000000000010',
  'b1000000-0000-4000-8000-000000000012',
  'familiar',
  false,
  2,
  'familiar'
where not exists (
  select 1 from contact_patient_links l
  where l.tenant_id = 'b1000000-0000-4000-8000-000000000001'::uuid
    and l.contact_id = 'b1000000-0000-4000-8000-000000000010'::uuid
    and l.patient_id = 'b1000000-0000-4000-8000-000000000012'::uuid
    and l.deleted_at is null
);

insert into appointments (
  id, tenant_id, specialist_id, patient_id, location_id,
  source, source_type_id, status, status_type_id,
  booking_uid, starts_at, ends_at, reason, metadata
)
values (
  'b1000000-0000-4000-8000-000000000021',
  'b1000000-0000-4000-8000-000000000001',
  'b1000000-0000-4000-8000-000000000003',
  'b1000000-0000-4000-8000-000000000011',
  'b1000000-0000-4000-8000-000000000002',
  'whatsapp', 1, 'rescheduled', 3,
  'DEMO-BK-TITULAR-001',
  ('2026-05-22 09:30:00'::timestamp at time zone 'America/Mexico_City'),
  ('2026-05-22 10:00:00'::timestamp at time zone 'America/Mexico_City'),
  'Primera valoración ortodoncia',
  jsonb_build_object(
    'demo', true,
    'reschedule_history', jsonb_build_array(
      jsonb_build_object(
        'at', '2026-05-10T18:00:00Z',
        'from_starts_at', ('2026-05-20 09:00:00'::timestamp at time zone 'America/Mexico_City'),
        'from_ends_at', ('2026-05-20 09:30:00'::timestamp at time zone 'America/Mexico_City'),
        'to_starts_at', ('2026-05-22 09:30:00'::timestamp at time zone 'America/Mexico_City'),
        'to_ends_at', ('2026-05-22 10:00:00'::timestamp at time zone 'America/Mexico_City'),
        'reason', 'Paciente solicitó mover por trabajo'
      )
    )
  )
)
on conflict (id) do nothing;

insert into appointment_events (
  id, tenant_id, appointment_id, source, source_type_id,
  event_type, event_type_id, actor_type, actor_type_id,
  external_ref, raw_payload, created_at
)
select
  gen_random_uuid(),
  'b1000000-0000-4000-8000-000000000001',
  'b1000000-0000-4000-8000-000000000021',
  'staff',
  4,
  'appointment.rescheduled',
  3,
  'staff',
  3,
  'DEMO-EVT-RSH-TITULAR-001',
  jsonb_build_object(
    'previous_starts_at', ('2026-05-20 09:00:00'::timestamp at time zone 'America/Mexico_City'),
    'previous_ends_at', ('2026-05-20 09:30:00'::timestamp at time zone 'America/Mexico_City'),
    'new_starts_at', ('2026-05-22 09:30:00'::timestamp at time zone 'America/Mexico_City'),
    'new_ends_at', ('2026-05-22 10:00:00'::timestamp at time zone 'America/Mexico_City'),
    'reason', 'Reagendamiento demo (evento)'
  ),
  ('2026-05-10 18:00:00'::timestamp at time zone 'America/Mexico_City')
where not exists (
  select 1 from appointment_events e where e.external_ref = 'DEMO-EVT-RSH-TITULAR-001'
);

insert into appointments (
  id, tenant_id, specialist_id, patient_id, location_id,
  source, source_type_id, status, status_type_id,
  booking_uid, starts_at, ends_at, reason, metadata
)
values (
  'b1000000-0000-4000-8000-000000000022',
  'b1000000-0000-4000-8000-000000000001',
  'b1000000-0000-4000-8000-000000000003',
  'b1000000-0000-4000-8000-000000000012',
  'b1000000-0000-4000-8000-000000000002',
  'whatsapp', 1, 'confirmed', 2,
  'DEMO-BK-HIJO-001',
  ('2026-05-22 11:00:00'::timestamp at time zone 'America/Mexico_City'),
  ('2026-05-22 11:30:00'::timestamp at time zone 'America/Mexico_City'),
  'Control brackets',
  '{"demo":true}'::jsonb
)
on conflict (id) do nothing;

insert into appointments (
  id, tenant_id, specialist_id, patient_id, location_id,
  source, source_type_id, status, status_type_id,
  booking_uid, starts_at, ends_at, reason, cancel_reason, metadata
)
values (
  'b1000000-0000-4000-8000-000000000023',
  'b1000000-0000-4000-8000-000000000001',
  'b1000000-0000-4000-8000-000000000003',
  'b1000000-0000-4000-8000-000000000011',
  'b1000000-0000-4000-8000-000000000002',
  'whatsapp', 1, 'cancelled', 4,
  'DEMO-BK-CANCEL-OLD',
  ('2026-05-18 16:00:00'::timestamp at time zone 'America/Mexico_City'),
  ('2026-05-18 16:30:00'::timestamp at time zone 'America/Mexico_City'),
  'Limpieza',
  'Paciente avisó que saldrá de viaje',
  '{"demo":true}'::jsonb
)
on conflict (id) do nothing;

insert into appointment_events (
  id, tenant_id, appointment_id, source, source_type_id,
  event_type, event_type_id, actor_type, actor_type_id,
  external_ref, raw_payload, created_at
)
select
  gen_random_uuid(),
  'b1000000-0000-4000-8000-000000000001',
  'b1000000-0000-4000-8000-000000000023',
  'staff',
  4,
  'appointment.cancelled',
  4,
  'staff',
  3,
  'DEMO-EVT-CANCEL-001',
  jsonb_build_object(
    'booking_uid', 'DEMO-BK-CANCEL-OLD',
    'reason', 'Paciente avisó que saldrá de viaje',
    'cancelled_starts_at', ('2026-05-18 16:00:00'::timestamp at time zone 'America/Mexico_City'),
    'cancelled_ends_at', ('2026-05-18 16:30:00'::timestamp at time zone 'America/Mexico_City')
  ),
  ('2026-05-08 12:00:00'::timestamp at time zone 'America/Mexico_City')
where not exists (
  select 1 from appointment_events e where e.external_ref = 'DEMO-EVT-CANCEL-001'
);

do $$
declare
  r record;
begin
  for r in
    select id from patients
    where tenant_id = 'b1000000-0000-4000-8000-000000000001'::uuid
      and deleted_at is null
  loop
    perform fn_recompute_patient_appointment_cache(r.id);
  end loop;
end $$;

commit;
