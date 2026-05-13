-- =============================================================================
-- 009 — actor_types (mock), relaciones catálogo en citas, evento de prueba
-- =============================================================================
-- Contenido:
--   1) Catálogo actor_types: fila code = 'mock' (pruebas / datos no clínicos).
--   2) Ajuste del CHECK en appointment_events.actor_type para permitir 'mock'.
--   3) Índices de apoyo a FKs ya definidos en 001/002 (si faltan).
--   4) Intento idempotente de añadir FKs con nombre en appointments y
--      appointment_events solo cuando la columna existe y aún no hay FK
--      hacia la tabla catálogo esperada (bases legadas sin REFERENCES).
--   5) Un registro mock en appointment_events (external_ref fijo), ligado a
--      la primera cita activa encontrada; raw_payload marca tipo mock/prueba.
--
-- Requiere: 001_init_schema.sql, 002_omnichannel_model.sql.
-- =============================================================================

-- ---------- 1) Catálogo actor: tipo mock / prueba ----------
insert into actor_types (id, code, display_name) values
  (5, 'mock', 'Mock / prueba (no clínico)')
on conflict (id) do update
  set code = excluded.code,
      display_name = excluded.display_name;

-- ---------- 2) CHECK actor_type en appointment_events: incluir 'mock' ----------
do $$
declare
  r record;
begin
  for r in
    select c.oid, c.conname
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    where t.relname = 'appointment_events'
      and t.relnamespace = (select oid from pg_namespace where nspname = 'public')
      and c.contype = 'c'
      and pg_get_constraintdef(c.oid) ilike '%actor_type%'
  loop
    execute format('alter table appointment_events drop constraint if exists %I', r.conname);
  end loop;
end;
$$;

alter table appointment_events
  add constraint appointment_events_actor_type_check
  check (
    actor_type is null
    or actor_type in ('patient', 'specialist', 'staff', 'system', 'mock')
  );

-- ---------- 3) Índices (FKs ya existen vía 001/002 en instalaciones estándar) ----------
create index if not exists idx_appointment_events_actor_type_id
  on appointment_events (actor_type_id)
  where actor_type_id is not null;

create index if not exists idx_appointments_status_type_id
  on appointments (status_type_id)
  where status_type_id is not null and deleted_at is null;

create index if not exists idx_appointments_source_type_id
  on appointments (source_type_id)
  where source_type_id is not null and deleted_at is null;

-- ---------- 4) FKs con nombre solo si faltan (bases legadas) ----------
create or replace function _009_add_fk_if_missing(
  p_table text,
  p_column text,
  p_fk_name text,
  p_ref_table text,
  p_ref_column text default 'id'
)
returns void
language plpgsql
as $$
declare
  v_has_fk boolean;
begin
  if not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = p_table
      and column_name = p_column
  ) then
    return;
  end if;

  select exists (
    select 1
    from pg_constraint c
    join pg_class rel on rel.oid = c.conrelid
    join unnest(c.conkey) as ck(attnum) on true
    join pg_attribute att on att.attrelid = rel.oid and att.attnum = ck.attnum
    join pg_class frel on frel.oid = c.confrelid
    join unnest(c.confkey) as fk(attnum) on true
    join pg_attribute fatt on fatt.attrelid = frel.oid and fatt.attnum = fk.attnum
    where rel.relname = p_table
      and rel.relnamespace = (select oid from pg_namespace where nspname = 'public')
      and c.contype = 'f'
      and att.attname = p_column
      and frel.relname = p_ref_table
      and fatt.attname = p_ref_column
  ) into v_has_fk;

  if v_has_fk then
    return;
  end if;

  if exists (
    select 1 from pg_constraint
    where conname = p_fk_name
      and connamespace = (select oid from pg_namespace where nspname = 'public')
  ) then
    return;
  end if;

  execute format(
    'alter table public.%I add constraint %I foreign key (%I) references public.%I(%I)',
    p_table,
    p_fk_name,
    p_column,
    p_ref_table,
    p_ref_column
  );
exception
  when duplicate_object then
    null;
  when undefined_table then
    null;
end;
$$;

select _009_add_fk_if_missing('appointments', 'source_type_id', 'fk_appointments_source_type_id', 'appointment_source_types', 'id');
select _009_add_fk_if_missing('appointments', 'status_type_id', 'fk_appointments_status_type_id', 'appointment_status_types', 'id');
select _009_add_fk_if_missing('appointments', 'appointment_type_id', 'fk_appointments_appointment_type_id', 'appointment_types', 'id');
select _009_add_fk_if_missing('appointments', 'location_id', 'fk_appointments_location_id', 'locations', 'id');
select _009_add_fk_if_missing('appointment_events', 'source_type_id', 'fk_appointment_events_source_type_id', 'appointment_source_types', 'id');
select _009_add_fk_if_missing('appointment_events', 'event_type_id', 'fk_appointment_events_event_type_id', 'appointment_event_types', 'id');
select _009_add_fk_if_missing('appointment_events', 'actor_type_id', 'fk_appointment_events_actor_type_id', 'actor_types', 'id');

drop function if exists _009_add_fk_if_missing(text, text, text, text, text);

-- appointment_events no tiene status_type_id en 001/002 — no añadir FK inexistente

-- ---------- 5) Evento mock / prueba (idempotente por external_ref) ----------
insert into appointment_events (
  id,
  tenant_id,
  appointment_id,
  source,
  source_type_id,
  event_type,
  event_type_id,
  actor_type,
  actor_type_id,
  external_ref,
  raw_payload,
  created_at
)
select
  gen_random_uuid(),
  a.tenant_id,
  a.id,
  'staff',
  4,
  'other',
  10,
  'mock',
  (select id from actor_types where code = 'mock' limit 1),
  'seed_mock_prueba_009',
  jsonb_build_object(
    'tipo_registro', 'mock',
    'descripcion', 'Evento de prueba (009); no usar como auditoría clínica',
    'origen', 'sql_seed_automatizado'
  ),
  now()
from appointments a
where a.deleted_at is null
  and not exists (
    select 1 from appointment_events e
    where e.external_ref = 'seed_mock_prueba_009'
  )
order by a.starts_at nulls last
limit 1;

comment on column actor_types.code is
  'Incluye patient, specialist, staff, system y mock (pruebas). appointment_events.actor_type alineado con actor_types vía trigger en 002.';
