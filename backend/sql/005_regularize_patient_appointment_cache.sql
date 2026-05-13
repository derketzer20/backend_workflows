-- =============================================================================
-- 005 — Regularización del cache de citas en patients (idempotente)
-- =============================================================================
-- Objetivo:
--   1) Asegurar columnas en `patients` y columnas mínimas en `appointments`
--      usadas por el cache (compatible con bases que aplicaron 001/002 sin 004).
--   2) Instalar o actualizar `fn_recompute_patient_appointment_cache` con la
--      regla corregida: "cita activa" = pending|confirmed|rescheduled y aún
--      vigente en tiempo (ends_at > now() o sin ends_at y starts_at > now()),
--      no solo por estado sin mirar la fecha.
--   3) Trigger en `appointments` + backfill de todos los pacientes no borrados.
--   4) Vista `v_patients_with_contact_role` alineada con el cache.
--
-- Uso: ejecutar una vez (o las veces que haga falta) en Supabase / psql después
--      de 001–003; si ya corriste 004, este script solo actualiza función,
--      trigger, vista y recalcula filas.
-- =============================================================================

-- ---------- Defensa: columnas en appointments (002 / 001) ----------
alter table appointments
  add column if not exists deleted_at timestamptz,
  add column if not exists ends_at timestamptz;

-- ---------- Defensa: columnas en patients ----------
alter table patients
  add column if not exists deleted_at timestamptz,
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists last_appointment_starts_at timestamptz,
  add column if not exists next_appointment_starts_at timestamptz,
  add column if not exists active_appointment_count integer not null default 0;

-- Columna generada (solo si no existe)
do $$
begin
  if not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'patients'
      and column_name = 'has_active_appointment'
  ) then
    alter table patients
      add column has_active_appointment boolean
        generated always as (active_appointment_count > 0) stored;
  end if;
end;
$$;

comment on column patients.last_appointment_starts_at is
  'Mayor starts_at <= now() entre citas no borradas (cualquier status).';
comment on column patients.next_appointment_starts_at is
  'Menor starts_at > now() entre citas con status pending|confirmed|rescheduled.';
comment on column patients.active_appointment_count is
  'Citas operativamente vigentes: status pending|confirmed|rescheduled, no borradas, y aún no terminadas (ends_at > now()) o sin ends_at pero starts_at > now().';
comment on column patients.has_active_appointment is
  'Derivado: active_appointment_count > 0.';

-- ---------- Función de recálculo (misma lógica que 004 actualizado) ----------
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

-- ---------- Vista (misma definición que 004) ----------
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

-- ---------- Regularización de datos: recalcular cache por paciente ----------
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
  raise notice '005_regularize: cache recalculado para % pacientes', n;
end;
$$;
