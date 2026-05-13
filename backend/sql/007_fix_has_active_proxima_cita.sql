-- =============================================================================
-- 007 — Fix: has_active_appointment = hay próxima cita futura (consolidado)
-- =============================================================================
-- Problema corregido:
--   En versiones anteriores `has_active_appointment` era columna GENERADA como
--   (active_appointment_count > 0), es decir “hay slot de cita aún vigente por
--   ends_at”. El modelo de negocio requiere: “titular o asociado tienen cita
--   activa” = existe una PRÓXIMA cita con inicio > ahora en estados operativos,
--   alineado a `next_appointment_starts_at`.
--
-- Este script (idempotente en bases ya corregidas):
--   1) Quita la vista que depende de la columna.
--   2) Si `has_active_appointment` es generada, la elimina y crea columna boolean
--      persistida con default false.
--   3) Reemplaza `fn_recompute_patient_appointment_cache` para asignar
--      `has_active_appointment = (v_next is not null)` junto con last/next/active_count.
--   4) Recrea el trigger en `appointments` (sin cambio de lógica).
--   5) Recrea `v_patients_with_contact_role`.
--   6) Backfill: recalcula cache de todos los pacientes no borrados.
--
-- Cuándo ejecutarlo:
--   - Una vez en Supabase / producción si aplicaste 004 antes de esta semántica.
--   - Tras 001 + 002 + (004 o 005); no sustituye 006 si necesitas normalizar ends_at.
--
-- Archivos fuente alineados en el repo (misma lógica):
--   backend/sql/004_patient_appointment_cache.sql
--   backend/sql/005_regularize_patient_appointment_cache.sql
--   backend/sql/DOC_cache_agenda_patients.md
--   backend/sql/queries_verify_seed_dr_juan.sql
-- =============================================================================

drop view if exists v_patients_with_contact_role;

do $$
begin
  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'patients'
      and column_name = 'has_active_appointment'
      and is_generated = 'ALWAYS'
  ) then
    alter table patients drop column has_active_appointment;
  end if;
end;
$$;

alter table patients
  add column if not exists has_active_appointment boolean not null default false;

comment on column patients.has_active_appointment is
  'True si existe próxima cita (next_appointment_starts_at no nulo al recomputar).';

create or replace function fn_recompute_patient_appointment_cache(p_patient_id uuid)
returns void
language plpgsql
as $$
declare
  v_last timestamptz;
  v_next timestamptz;
  v_active int;
  v_now timestamptz := now();
begin
  if p_patient_id is null then
    return;
  end if;

  select max(a.starts_at)
  into v_last
  from appointments a
  where a.patient_id = p_patient_id
    and a.deleted_at is null
    and a.starts_at is not null
    and a.starts_at <= v_now;

  select min(a.starts_at)
  into v_next
  from appointments a
  where a.patient_id = p_patient_id
    and a.deleted_at is null
    and a.starts_at is not null
    and a.starts_at > v_now
    and a.status in ('pending', 'confirmed', 'rescheduled');

  select count(*)::int
  into v_active
  from appointments a
  where a.patient_id = p_patient_id
    and a.deleted_at is null
    and a.status in ('pending', 'confirmed', 'rescheduled')
    and (
      (a.ends_at is not null and a.ends_at > v_now)
      or (a.ends_at is null and a.starts_at is not null and a.starts_at > v_now)
    );

  update patients p
  set
    last_appointment_starts_at = v_last,
    next_appointment_starts_at = v_next,
    active_appointment_count = coalesce(v_active, 0),
    has_active_appointment = (v_next is not null),
    updated_at = now()
  where p.id = p_patient_id;
end;
$$;

create or replace function tg_appointments_refresh_patient_cache()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    if old.patient_id is not null then
      perform fn_recompute_patient_appointment_cache(old.patient_id);
    end if;
    return old;
  end if;

  if tg_op = 'UPDATE' then
    if old.patient_id is not null and old.patient_id is distinct from new.patient_id then
      perform fn_recompute_patient_appointment_cache(old.patient_id);
    end if;
    if new.patient_id is not null then
      perform fn_recompute_patient_appointment_cache(new.patient_id);
    end if;
    return new;
  end if;

  if tg_op = 'INSERT' and new.patient_id is not null then
    perform fn_recompute_patient_appointment_cache(new.patient_id);
    return new;
  end if;

  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_appointments_refresh_patient_cache on appointments;
create trigger trg_appointments_refresh_patient_cache
after insert or delete or update of patient_id, starts_at, ends_at, status, deleted_at
on appointments
for each row execute function tg_appointments_refresh_patient_cache();

create or replace view v_patients_with_contact_role as
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

do $$
declare
  r record;
  n int := 0;
begin
  for r in select id from patients where deleted_at is null
  loop
    perform fn_recompute_patient_appointment_cache(r.id);
    n := n + 1;
  end loop;
  raise notice '007_fix_has_active: cache recalculado para % pacientes', n;
end;
$$;
