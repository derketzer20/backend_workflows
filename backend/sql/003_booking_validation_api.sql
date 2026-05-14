-- Complemento operativo: resolución de identidad y comprobaciones de negocio
-- para Make/BotSailor sin duplicar tablas ya definidas en 001 + 002.
-- Requiere: 001_init_schema.sql y 002_omnichannel_model.sql aplicados.

-- ---------- Vista: cita + código de especialista (validación "con qué doctor") ----------

create or replace view v_booking_with_specialist
with (security_invoker = true)
as
select
  a.id as appointment_id,
  a.tenant_id,
  a.booking_uid,
  a.patient_id,
  a.specialist_id,
  s.specialist_code,
  s.display_name as specialist_display_name,
  a.status,
  a.status_type_id,
  a.starts_at,
  a.ends_at,
  a.source,
  a.deleted_at
from appointments a
join specialists s
  on s.id = a.specialist_id
 and s.tenant_id = a.tenant_id
where a.booking_uid is not null;

-- ---------- Contacto por teléfono normalizado (existencia vía número) ----------

create or replace function fn_resolve_contact_id_by_phone_digits(
  p_tenant_id uuid,
  p_phone_digits text
)
returns uuid
language sql
set search_path = public
as $$
  select c.id
  from contacts c
  where c.tenant_id = p_tenant_id
    and c.deleted_at is null
    and c.phone_digits = p_phone_digits
  order by c.last_seen_at desc nulls last
  limit 1;
$$;

-- ---------- ¿Hay al menos un paciente vinculado al contacto? ----------

create or replace function fn_contact_has_linked_patients(
  p_tenant_id uuid,
  p_contact_id uuid
)
returns boolean
language sql
set search_path = public
as $$
  select exists (
    select 1
    from contact_patient_links cpl
    where cpl.tenant_id = p_tenant_id
      and cpl.contact_id = p_contact_id
      and cpl.deleted_at is null
  )
  or exists (
    select 1
    from patients p
    where p.tenant_id = p_tenant_id
      and p.contact_id = p_contact_id
      and p.deleted_at is null
  );
$$;

-- ---------- Validar que un paciente pertenece al contacto (titular / vínculos) ----------

create or replace function fn_patient_belongs_to_contact(
  p_tenant_id uuid,
  p_contact_id uuid,
  p_patient_id uuid
)
returns boolean
language sql
set search_path = public
as $$
  select exists (
    select 1
    from contact_patient_links cpl
    where cpl.tenant_id = p_tenant_id
      and cpl.contact_id = p_contact_id
      and cpl.patient_id = p_patient_id
      and cpl.deleted_at is null
  )
  or exists (
    select 1
    from patients p
    where p.tenant_id = p_tenant_id
      and p.id = p_patient_id
      and p.contact_id = p_contact_id
      and p.deleted_at is null
  );
$$;

-- ---------- Cita por booking_uid con datos de doctor (lectura para validar) ----------

create or replace function fn_get_booking_snapshot(
  p_tenant_id uuid,
  p_booking_uid text
)
returns table (
  appointment_id uuid,
  patient_id uuid,
  specialist_id uuid,
  specialist_code text,
  status text,
  starts_at timestamptz,
  ends_at timestamptz,
  is_active boolean
)
language sql
set search_path = public
as $$
  select
    v.appointment_id,
    v.patient_id,
    v.specialist_id,
    v.specialist_code,
    v.status,
    v.starts_at,
    v.ends_at,
    (v.deleted_at is null and v.status in ('pending', 'confirmed', 'rescheduled')) as is_active
  from v_booking_with_specialist v
  where v.tenant_id = p_tenant_id
    and v.booking_uid = p_booking_uid
  limit 1;
$$;

-- ---------- booking_uid corresponde al specialist_code indicado ----------

create or replace function fn_booking_matches_specialist_code(
  p_tenant_id uuid,
  p_booking_uid text,
  p_specialist_code text
)
returns boolean
language sql
set search_path = public
as $$
  select exists (
    select 1
    from v_booking_with_specialist v
    where v.tenant_id = p_tenant_id
      and v.booking_uid = p_booking_uid
      and v.deleted_at is null
      and lower(v.specialist_code) = lower(p_specialist_code)
  );
$$;

-- ---------- Resumen previo a insertar cita: duplicado exacto + ventana (sin insertar) ----------
-- Devuelve una fila con flags para ramificar en Make.

create or replace function fn_precheck_new_appointment(
  p_tenant_id uuid,
  p_patient_id uuid,
  p_specialist_id uuid,
  p_starts_at timestamptz,
  p_source text default null,
  p_exclude_appointment_id uuid default null
)
returns table (
  duplicate_exact_id uuid,
  window_conflict_id uuid,
  can_insert boolean
)
language sql
set search_path = public
as $$
  with evaluated as (
    select
      fn_find_duplicate_active_appointment(
        p_tenant_id,
        p_patient_id,
        p_specialist_id,
        p_starts_at
      ) as duplicate_exact_id,
      fn_find_window_conflict_appointment(
        p_tenant_id,
        p_patient_id,
        p_specialist_id,
        p_starts_at,
        p_source,
        p_exclude_appointment_id
      ) as window_conflict_id
  )
  select
    e.duplicate_exact_id,
    e.window_conflict_id,
    (e.duplicate_exact_id is null and e.window_conflict_id is null) as can_insert
  from evaluated e;
$$;
