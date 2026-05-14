-- Cache de agenda por paciente (lectura rápida desde Make / dashboards).

-- Fuente de verdad sigue siendo appointments; estas columnas se mantienen por trigger.

-- Rol titular/familiar: tabla contact_patient_links + vista v_patients_with_contact_role.

--

-- has_active_appointment: true si hay próxima cita (next_appointment_starts_at no nulo),

--   alineado a titular/asociado con cita futura en pending|confirmed|rescheduled.

-- active_appointment_count: número de citas con intervalo aún vigente (ends_at > now o equivalente).



-- ---------- Columnas en patients ----------



alter table patients

  add column if not exists last_appointment_starts_at timestamptz,

  add column if not exists next_appointment_starts_at timestamptz,

  add column if not exists active_appointment_count integer not null default 0;



-- has_active_appointment: columna persistida (no generada) para poder fijarla a

-- (v_next is not null) en fn_recompute. Migración desde versión generada (active_count > 0):

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



comment on column patients.last_appointment_starts_at is

  'Mayor starts_at <= now() entre citas no borradas (cualquier status).';

comment on column patients.next_appointment_starts_at is

  'Menor starts_at > now() entre citas con status pending|confirmed|rescheduled.';

comment on column patients.active_appointment_count is

  'Citas operativamente vigentes: status pending|confirmed|rescheduled, no borradas, y aún no terminadas (ends_at > now()) o sin ends_at pero starts_at > now().';

comment on column patients.has_active_appointment is

  'True si existe próxima cita agendada (equivalente a next_appointment_starts_at is not null al recomputar). No usa active_appointment_count.';



-- ---------- Recompute ----------



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



  -- Intervalo aún vigente: conviene ends_at poblado (script 006_normalize_appointment_intervals.sql).

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



-- ---------- Backfill ----------



do $$

declare

  r record;

begin

  for r in select id from patients where deleted_at is null

  loop

    perform fn_recompute_patient_appointment_cache(r.id);

  end loop;

end;

$$;



-- ---------- Vista: paciente + contacto canónico + rol titular/familiar ----------



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

