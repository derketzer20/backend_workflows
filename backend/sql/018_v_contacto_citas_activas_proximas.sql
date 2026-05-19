-- =============================================================================
-- 018 — Citas activas / próximas por contacto (vista + función de regla)
-- =============================================================================
-- "Activa" se evalúa al consultar (now()), no requiere trigger: el reloj avanza
-- sin cambios en appointments; el cache en patients (007) cubre otro caso.
--
-- Criterio de cita activa por fecha:
--   - Próxima: starts_at > now()
--   - En curso: starts_at <= now() y (ends_at es null o ends_at > now())
-- Estados operativos: pending, confirmed, rescheduled (no cancelada/completada).
--
-- Uso Make / PostgREST (HTTPS):
--   GET .../rest/v1/v_contacto_citas_activas_proximas
--       ?tenant_id=eq.<uuid>&contacto_id=eq.<uuid>
--       &order=cita_fecha_inicio.asc
--
-- Requiere: 001, 002, 004 o 007.
-- =============================================================================

-- ---------- Regla reutilizable (RPC opcional, tests, otras vistas) ----------

create or replace function fn_appointment_is_active_by_now(
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_status text,
  p_deleted_at timestamptz default null
)
returns boolean
language sql
stable
set search_path = public
as $$
  select
    p_deleted_at is null
    and p_status in ('pending', 'confirmed', 'rescheduled')
    and p_starts_at is not null
    and (
      p_starts_at > now()
      or (
        p_starts_at <= now()
        and (p_ends_at is null or p_ends_at > now())
      )
    );
$$;

comment on function fn_appointment_is_active_by_now(timestamptz, timestamptz, text, timestamptz) is
  'True si la cita está operativamente activa respecto a now(): próxima o slot en curso.';

-- ---------- Vista: una fila por cita activa ligada al contacto ----------

create or replace view v_contacto_citas_activas_proximas
with (security_invoker = true)
as
with linked_patients as (
  select cpl.tenant_id, cpl.contact_id, cpl.patient_id
  from contact_patient_links cpl
  where cpl.deleted_at is null
  union
  select p.tenant_id, p.contact_id, p.id as patient_id
  from patients p
  where p.deleted_at is null
    and p.contact_id is not null
)
select
  c.id as contacto_id,
  c.tenant_id,
  c.phone_digits as contacto_telefono_10_digitos,

  a.id as cita_id,
  a.booking_uid as cita_booking_uid,
  a.starts_at as cita_fecha_inicio,
  a.ends_at as cita_fecha_fin,
  (a.starts_at > now()) as cita_es_proxima,
  fn_appointment_is_active_by_now(a.starts_at, a.ends_at, a.status, a.deleted_at) as cita_esta_activa,

  a.status as cita_estado,
  case a.status
    when 'pending' then 'Pendiente'
    when 'confirmed' then 'Confirmada'
    when 'rescheduled' then 'Reagendada'
    else a.status
  end as cita_estado_etiqueta,

  p.id as paciente_id,
  p.full_name as paciente_nombre_completo,
  p.birth_date as paciente_fecha_nacimiento,
  p.gender as paciente_genero_codigo,
  case p.gender
    when 'male' then 'Masculino'
    when 'female' then 'Femenino'
    when 'other' then 'Otro'
    when 'unknown' then 'Sin especificar'
    else coalesce(p.gender, 'Sin especificar')
  end as paciente_genero,
  a.reason as motivo_consulta

from linked_patients lp
join contacts c
  on c.id = lp.contact_id
 and c.tenant_id = lp.tenant_id
 and c.deleted_at is null
join patients p
  on p.id = lp.patient_id
 and p.tenant_id = lp.tenant_id
 and p.deleted_at is null
join appointments a
  on a.tenant_id = lp.tenant_id
 and a.patient_id = lp.patient_id
where fn_appointment_is_active_by_now(a.starts_at, a.ends_at, a.status, a.deleted_at);

comment on view v_contacto_citas_activas_proximas is
  'Citas activas (próximas o en curso) por contacto: paciente, género, motivo, fechas y estado pending/confirmed/rescheduled.';

-- Solo citas estrictamente futuras (sin las que ya empezaron pero no terminan):
--   ... WHERE cita_es_proxima = true
-- Solo pendiente o confirmada (sin reagendada):
--   ... WHERE cita_estado IN ('pending', 'confirmed')

grant select on v_contacto_citas_activas_proximas to authenticated, service_role;
