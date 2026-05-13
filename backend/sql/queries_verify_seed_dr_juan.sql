-- =============================================================================
-- VER DATOS INSERTADOS (seed Dr. Juan / CorpOS Monterrey)
-- Tenant del seed (cámbialo si usaste otro):
--   9e4860a5-d163-548d-8cb2-886f4d9e71f2
--
-- En Supabase SQL Editor: ejecuta UNA consulta a la vez.
-- Prefijo CACHE__: columnas persistidas en patients (fn_recompute).
-- has_active = hay próxima cita (next_appointment_starts_at no nulo); active_count = slots vigentes por ends_at.
-- Normalizar ends_at: 006_normalize_appointment_intervals.sql
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 0) INVENTARIO Y BÚSQUEDA — encontrar tenant, contar filas, localizar por teléfono/nombre
--     0.7 / 0.8: ver starts_at / ends_at y candidatas a normalizar (luego script 006).
-- -----------------------------------------------------------------------------

-- 0.1) Todos los tenants (elige el id si no sabes cuál usar)
select id as tenant_id, name as tenant_name, created_at
from tenants
order by name;

-- 0.2) Resumen de filas por tenant (reemplaza el UUID si buscas otro tenant)
select
  t.id as tenant_id,
  t.name as clinica,
  (select count(*) from locations l where l.tenant_id = t.id and l.deleted_at is null)::bigint as locations,
  (select count(*) from specialists s where s.tenant_id = t.id and s.deleted_at is null)::bigint as specialists,
  (select count(*) from contacts c where c.tenant_id = t.id and c.deleted_at is null)::bigint as contacts,
  (select count(*) from patients p where p.tenant_id = t.id and p.deleted_at is null)::bigint as patients,
  (select count(*) from contact_patient_links l where l.tenant_id = t.id and l.deleted_at is null)::bigint as contact_patient_links,
  (select count(*) from appointments a where a.tenant_id = t.id and a.deleted_at is null)::bigint as appointments_total,
  (select count(*) from appointments a
   where a.tenant_id = t.id and a.deleted_at is null
     and a.status in ('pending', 'confirmed', 'rescheduled'))::bigint as appointments_estado_activo_texto
from tenants t
where t.id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid;

-- 0.3) Mismo resumen pero para TODOS los tenants (vista rápida de toda la BD)
select
  t.id as tenant_id,
  t.name as clinica,
  (select count(*) from patients p where p.tenant_id = t.id and p.deleted_at is null)::bigint as patients,
  (select count(*) from appointments a where a.tenant_id = t.id and a.deleted_at is null)::bigint as appointments
from tenants t
order by t.name;

-- 0.4) Buscar paciente por teléfono (parcial) o nombre (edita los literales entre %)
select
  p.tenant_id,
  tn.name as tenant_name,
  p.id as patient_id,
  p.full_name,
  c.phone_digits,
  c.wa_id,
  p.email
from patients p
join tenants tn on tn.id = p.tenant_id
join contacts c on c.id = p.contact_id and c.tenant_id = p.tenant_id
where p.deleted_at is null
  and c.deleted_at is null
  and (
    c.phone_digits like '%4675'          -- ejemplo: termina en 4675
    or p.full_name ilike '%madeleine%'   -- ejemplo: nombre
  )
order by tn.name, c.phone_digits;

-- 0.5) Índice de citas con paciente y teléfono (útil para cruzar con CRM)
select
  a.tenant_id,
  a.id as appointment_id,
  a.booking_uid,
  a.status,
  to_char(a.starts_at at time zone 'America/Monterrey', 'YYYY-MM-DD HH24:MI') as inicio_mty,
  p.full_name as paciente,
  c.phone_digits,
  a.patient_id,
  a.specialist_id
from appointments a
left join patients p on p.id = a.patient_id
left join contacts c on c.id = p.contact_id and c.tenant_id = a.tenant_id
where a.tenant_id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid
  and a.deleted_at is null
order by a.starts_at nulls last;

-- 0.6) Cache en patients + verificación contra la misma regla que fn_recompute (004/005)
select
  now() as calc_referencia_now_utc,
  p.id as patient_id,
  p.full_name,
  c.phone_digits,
  p.last_appointment_starts_at as CACHE__last_appointment_starts_at,
  p.next_appointment_starts_at as CACHE__next_appointment_starts_at,
  p.active_appointment_count as CACHE__active_appointment_count,
  p.has_active_appointment as CACHE__has_active_appointment,
  to_char(p.last_appointment_starts_at at time zone 'America/Monterrey', 'YYYY-MM-DD HH24:MI') as ultima_mty,
  to_char(p.next_appointment_starts_at at time zone 'America/Monterrey', 'YYYY-MM-DD HH24:MI') as siguiente_mty,
  (
    select count(*)::int
    from appointments x
    where x.patient_id = p.id
      and x.tenant_id = p.tenant_id
      and x.deleted_at is null
      and x.status in ('pending', 'confirmed', 'rescheduled')
      and (
        (x.ends_at is not null and x.ends_at > now())
        or (x.ends_at is null and x.starts_at is not null and x.starts_at > now())
      )
  ) as verificacion_reconteo_activas_misma_regla_que_fn,
  (
    p.active_appointment_count = (
      select count(*)::int
      from appointments x
      where x.patient_id = p.id
        and x.tenant_id = p.tenant_id
        and x.deleted_at is null
        and x.status in ('pending', 'confirmed', 'rescheduled')
        and (
          (x.ends_at is not null and x.ends_at > now())
          or (x.ends_at is null and x.starts_at is not null and x.starts_at > now())
        )
    )
  ) as verificacion_active_count_coincide_reconteo_slots,
  (p.has_active_appointment = (p.next_appointment_starts_at is not null)) as verificacion_has_active_igual_proxima_cita
from patients p
join contacts c on c.id = p.contact_id and c.tenant_id = p.tenant_id
where p.tenant_id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid
  and p.deleted_at is null
order by c.phone_digits;

-- 0.7) Auditoría: columnas por cita para active_appointment_count (slot vigente) y contexto
select
  now() as calc_referencia_now_utc,
  a.id as appointment_id,
  a.tenant_id,
  a.patient_id,
  p.full_name as paciente,
  a.booking_uid,
  a.deleted_at as campo_deleted_at,
  a.status as campo_status,
  a.starts_at as campo_starts_at_utc,
  a.ends_at as campo_ends_at_utc,
  to_char(a.starts_at at time zone 'America/Monterrey', 'YYYY-MM-DD HH24:MI') as inicio_mty,
  to_char(a.ends_at at time zone 'America/Monterrey', 'YYYY-MM-DD HH24:MI') as fin_mty,
  round(
    case
      when a.ends_at is not null and a.starts_at is not null
      then extract(epoch from (a.ends_at - a.starts_at)) / 60.0
    end,
    1
  ) as duracion_minutos,
  (a.ends_at is null) as ends_null,
  (a.ends_at is not null and a.starts_at is not null and a.ends_at <= a.starts_at) as intervalo_invalido,
  (a.deleted_at is null) as regla_no_borrada,
  (a.status in ('pending', 'confirmed', 'rescheduled')) as regla_status_cuenta_para_activo,
  (a.ends_at is not null and a.ends_at > now()) as regla_ends_mayor_que_now,
  (a.ends_at is null and a.starts_at is not null and a.starts_at > now()) as regla_sin_ends_y_starts_futuro,
  (
    a.deleted_at is null
    and a.status in ('pending', 'confirmed', 'rescheduled')
    and (
      (a.ends_at is not null and a.ends_at > now())
      or (a.ends_at is null and a.starts_at is not null and a.starts_at > now())
    )
  ) as esta_cita_cuenta_para_CACHE__active_appointment_count,
  (
    a.deleted_at is null
    and a.status in ('pending', 'confirmed', 'rescheduled')
    and a.starts_at is not null
    and a.starts_at > now()
  ) as esta_cita_es_proxima_para_has_active
from appointments a
left join patients p on p.id = a.patient_id
where a.tenant_id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid
  and a.deleted_at is null
order by a.starts_at nulls last;

-- 0.8) Solo citas candidatas a normalización (ends null o ends <= starts); mismo criterio que 006
select
  a.id as appointment_id,
  a.patient_id,
  p.full_name,
  a.status,
  a.starts_at,
  a.ends_at
from appointments a
left join patients p on p.id = a.patient_id
where a.tenant_id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid
  and a.deleted_at is null
  and a.starts_at is not null
  and (
    a.ends_at is null
    or a.ends_at <= a.starts_at
  )
order by a.starts_at;

-- -----------------------------------------------------------------------------
-- A) TODO EN FILAS LEGIBLES — paciente + citas + columnas CACHE (fn_recompute) y verificación
-- -----------------------------------------------------------------------------
with seed_tenant as (
  select '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid as id,
         now() as tnow
)
select
  s.tnow as calc_referencia_now_utc,
  (select t.name from tenants t where t.id = s.id) as clinica,
  (select l.display_name || ' [' || l.code || ']' from locations l
   where l.tenant_id = s.id and l.deleted_at is null limit 1) as sede,
  (select sp.display_name || ' (' || sp.specialist_code || ')'
   from specialists sp
   where sp.tenant_id = s.id and sp.deleted_at is null limit 1) as doctor,
  p.full_name as paciente,
  c.phone_digits as telefono_10_digitos,
  c.wa_id as whatsapp_wa_id,
  coalesce(cpl.relationship_type, '?') as rol_titular_o_familiar,
  p.birth_date as fecha_nacimiento,
  p.email as correo_paciente,
  p.last_appointment_starts_at as CACHE__last_appointment_starts_at,
  p.next_appointment_starts_at as CACHE__next_appointment_starts_at,
  p.active_appointment_count as CACHE__active_appointment_count,
  p.has_active_appointment as CACHE__has_active_appointment,
  to_char(p.last_appointment_starts_at at time zone 'America/Monterrey', 'YYYY-MM-DD HH24:MI')
    as ultima_cita_hora_mty,
  to_char(p.next_appointment_starts_at at time zone 'America/Monterrey', 'YYYY-MM-DD HH24:MI')
    as siguiente_cita_hora_mty,
  (
    select count(*)::int
    from appointments x
    where x.patient_id = p.id
      and x.tenant_id = p.tenant_id
      and x.deleted_at is null
      and x.status in ('pending', 'confirmed', 'rescheduled')
      and (
        (x.ends_at is not null and x.ends_at > s.tnow)
        or (x.ends_at is null and x.starts_at is not null and x.starts_at > s.tnow)
      )
  ) as verificacion_reconteo_citas_activas_misma_regla_que_fn,
  (
    p.active_appointment_count = (
      select count(*)::int
      from appointments x
      where x.patient_id = p.id
        and x.tenant_id = p.tenant_id
        and x.deleted_at is null
        and x.status in ('pending', 'confirmed', 'rescheduled')
        and (
          (x.ends_at is not null and x.ends_at > s.tnow)
          or (x.ends_at is null and x.starts_at is not null and x.starts_at > s.tnow)
        )
    )
  ) as verificacion_active_count_coincide_reconteo_slots,
  (p.has_active_appointment = (p.next_appointment_starts_at is not null)) as verificacion_has_active_igual_proxima_cita,
  p.metadata as metadata_paciente_json,
  coalesce(
    (
      select string_agg(line, chr(10) order by starts_at)
      from (
        select
          a2.starts_at,
          to_char(a2.starts_at at time zone 'America/Monterrey', 'YYYY-MM-DD HH24:MI')
            || ' → '
            || to_char(a2.ends_at at time zone 'America/Monterrey', 'HH24:MI')
            || ' | '
            || a2.status
            || coalesce(' | uid:' || a2.booking_uid, '')
            || ' | slot_vigente_active_count:'
            || (
              case
                when a2.deleted_at is null
                  and a2.status in ('pending', 'confirmed', 'rescheduled')
                  and (
                    (a2.ends_at is not null and a2.ends_at > s.tnow)
                    or (a2.ends_at is null and a2.starts_at is not null and a2.starts_at > s.tnow)
                  )
                then 'si'
                else 'no'
              end
            )
            || ' | proxima_has_active:'
            || (
              case
                when a2.deleted_at is null
                  and a2.status in ('pending', 'confirmed', 'rescheduled')
                  and a2.starts_at is not null
                  and a2.starts_at > s.tnow
                then 'si'
                else 'no'
              end
            ) as line
        from appointments a2
        where a2.patient_id = p.id
          and a2.tenant_id = p.tenant_id
          and a2.deleted_at is null
      ) lines
    ),
    '(sin filas en appointments)'
  ) as citas_detalle_una_por_linea
from seed_tenant s
join patients p on p.tenant_id = s.id and p.deleted_at is null
join contacts c on c.id = p.contact_id and c.tenant_id = s.id and c.deleted_at is null
left join contact_patient_links cpl
  on cpl.patient_id = p.id
 and cpl.contact_id = p.contact_id
 and cpl.tenant_id = s.id
 and cpl.deleted_at is null
group by
  s.tnow,
  s.id,
  p.id, p.full_name, c.phone_digits, c.wa_id, cpl.relationship_type,
  p.birth_date, p.email,
  p.last_appointment_starts_at, p.next_appointment_starts_at,
  p.active_appointment_count, p.has_active_appointment, p.metadata
order by c.phone_digits;

-- -----------------------------------------------------------------------------
-- B) CADA CITA: reglas para active_appointment_count (slot) y para has_active (próximo inicio)
-- -----------------------------------------------------------------------------
select
  now() as calc_referencia_now_utc,
  a.id as cita_id,
  p.full_name as paciente,
  c.phone_digits as telefono,
  s.specialist_code as doctor_codigo,
  a.deleted_at as campo_deleted_at,
  a.status as campo_status,
  a.starts_at as campo_starts_at_utc,
  a.ends_at as campo_ends_at_utc,
  to_char(a.starts_at at time zone 'America/Monterrey', 'YYYY-MM-DD HH24:MI') as inicio_mty,
  to_char(a.ends_at at time zone 'America/Monterrey', 'YYYY-MM-DD HH24:MI') as fin_mty,
  a.booking_uid as cal_booking_uid,
  (a.deleted_at is null) as regla_no_borrada,
  (a.status in ('pending', 'confirmed', 'rescheduled')) as regla_status_cuenta_para_activo,
  (a.ends_at is not null and a.ends_at > now()) as regla_ends_mayor_que_now,
  (a.ends_at is null and a.starts_at is not null and a.starts_at > now()) as regla_sin_ends_y_starts_futuro,
  (
    a.deleted_at is null
    and a.status in ('pending', 'confirmed', 'rescheduled')
    and (
      (a.ends_at is not null and a.ends_at > now())
      or (a.ends_at is null and a.starts_at is not null and a.starts_at > now())
    )
  ) as esta_cita_cuenta_para_CACHE__active_appointment_count,
  (
    a.deleted_at is null
    and a.status in ('pending', 'confirmed', 'rescheduled')
    and a.starts_at is not null
    and a.starts_at > now()
  ) as esta_cita_es_proxima_para_has_active,
  a.source as canal,
  a.reason as motivo,
  a.metadata as metadata_cita_json
from appointments a
join patients p on p.id = a.patient_id
join contacts c on c.id = p.contact_id
join specialists s on s.id = a.specialist_id
where a.tenant_id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid
  and a.deleted_at is null
order by a.starts_at nulls last;

-- -----------------------------------------------------------------------------
-- C) CONTACTOS (teléfonos guardados)
-- -----------------------------------------------------------------------------
select
  id,
  wa_id,
  phone_digits,
  phone_e164,
  channel_primary,
  metadata,
  first_seen_at,
  last_seen_at
from contacts
where tenant_id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid
  and deleted_at is null
order by phone_digits;

-- -----------------------------------------------------------------------------
-- D) VÍNCULOS (quién es titular / familiar respecto al número)
-- -----------------------------------------------------------------------------
select
  l.id as link_id,
  c.phone_digits,
  p.full_name as paciente,
  l.relationship_type as rol,
  l.relationship_type_id,
  l.is_primary,
  l.can_manage_appointments,
  l.notes
from contact_patient_links l
join contacts c on c.id = l.contact_id
join patients p on p.id = l.patient_id
where l.tenant_id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid
  and l.deleted_at is null
order by c.phone_digits, p.full_name;

-- -----------------------------------------------------------------------------
-- E) TABLAS BASE (filas completas tal cual en BD)
-- -----------------------------------------------------------------------------
select * from tenants
where id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid;

select * from locations
where tenant_id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid
order by code;

select * from specialists
where tenant_id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid
order by specialist_code;

select * from specialist_duplicate_policies
where tenant_id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid
order by specialist_id;

select * from patients
where tenant_id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid
  and deleted_at is null
order by full_name;

select * from appointments
where tenant_id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid
order by starts_at nulls last;

-- -----------------------------------------------------------------------------
-- F) Vistas del modelo (misma data, formato ya armado)
-- -----------------------------------------------------------------------------
select * from v_active_appointments
where tenant_id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid
order by starts_at nulls last;

select * from v_patients_with_contact_role
where tenant_id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid
order by full_name;
