-- =============================================================================
-- 019 — Eliminar appointments.appointment_type_id
-- =============================================================================
-- Quita la FK/columna y actualiza el trigger de sincronía de tipos.
-- Recrea vistas que dependían de appointment_types vía esa columna.
--
-- Ejecutar en Supabase SQL Editor (un solo script).
-- Después, en el repo conviene alinear seeds (016_seed, seed_dr_juan) sin esa columna.
-- =============================================================================

-- ---------- 1) Vistas que referencian appointment_type_id ----------

drop view if exists v_contacto_citas_activas_proximas;
drop view if exists v_contacto_panel_agenda_citas;

-- ---------- 2) Trigger: ya no asignar ni vigilar appointment_type_id ----------

create or replace function tg_sync_appointment_types()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.source_type_id is null and new.source is not null then
    select id into new.source_type_id
    from appointment_source_types
    where code = lower(new.source)
    limit 1;
  elsif new.source is null and new.source_type_id is not null then
    select code into new.source from appointment_source_types where id = new.source_type_id;
  end if;

  if new.status_type_id is null and new.status is not null then
    select id into new.status_type_id
    from appointment_status_types
    where code = lower(new.status)
    limit 1;
  elsif new.status is null and new.status_type_id is not null then
    select code into new.status from appointment_status_types where id = new.status_type_id;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_sync_appointment_types on appointments;
create trigger trg_sync_appointment_types
before insert or update of source, source_type_id, status, status_type_id
on appointments
for each row execute function tg_sync_appointment_types();

-- ---------- 3) FK, índice y columna ----------

do $$
declare
  r record;
begin
  for r in
    select c.conname
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
    join unnest(c.conkey) as ck(attnum) on true
    join pg_attribute a on a.attrelid = t.oid and a.attnum = ck.attnum
    where n.nspname = 'public'
      and t.relname = 'appointments'
      and c.contype = 'f'
      and a.attname = 'appointment_type_id'
  loop
    execute format('alter table public.appointments drop constraint if exists %I', r.conname);
  end loop;
end;
$$;

drop index if exists public.idx_appointments_appointment_type_id;

alter table public.appointments
  drop column if exists appointment_type_id;

-- ---------- 4) Recrear vistas (sin appointment_type_id) ----------
-- En el mismo SQL Editor, ejecuta después (en este orden):
--   • 018_v_contacto_citas_activas_proximas.sql
--   • 016_v_contacto_panel_agenda_citas.sql
