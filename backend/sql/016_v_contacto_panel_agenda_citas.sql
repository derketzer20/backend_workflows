-- =============================================================================
-- 016 — Panel de agenda por contacto (citas próximas / en curso + familia +
--        historial de reagendamiento y cancelación)
-- =============================================================================
-- Requiere: 001_init_schema.sql, 002_omnichannel_model.sql, 004 o 007 (cache).
--
-- Contenido:
--   1) fn_reschedule_appointment_by_booking_uid: guarda horario anterior en
--      raw_payload del evento y append en appointments.metadata.reschedule_history.
--   2) fn_cancel_appointment_by_booking_uid: guarda horario cancelado en raw_payload.
--   3) Vista v_contacto_panel_agenda_citas (security_invoker).
--   4) Seed opcional DEMO (tenant aislado); ejecutar solo si necesita datos de prueba.
-- =============================================================================

-- ---------- 1) Reagendar: conservar fecha/hora previas (evento + metadata) ----------

create or replace function fn_reschedule_appointment_by_booking_uid(
  p_tenant_id uuid,
  p_booking_uid text,
  p_new_starts_at timestamptz,
  p_new_ends_at timestamptz,
  p_reason text,
  p_source text default 'system',
  p_actor_type text default 'system',
  p_actor_ref text default null,
  p_external_event_id text default null
)
returns uuid
language plpgsql
set search_path = public
as $$
declare
  v_appointment_id uuid;
  v_old_starts timestamptz;
  v_old_ends timestamptz;
  v_old_meta jsonb;
begin
  select a.id, a.starts_at, a.ends_at, coalesce(a.metadata, '{}'::jsonb)
  into v_appointment_id, v_old_starts, v_old_ends, v_old_meta
  from appointments a
  where a.tenant_id = p_tenant_id
    and a.booking_uid = p_booking_uid
    and a.deleted_at is null
    and a.status in ('pending', 'confirmed', 'rescheduled')
  for update;

  if v_appointment_id is null then
    return null;
  end if;

  update appointments a
  set
    starts_at = p_new_starts_at,
    ends_at = p_new_ends_at,
    status = 'rescheduled',
    metadata = v_old_meta
      || jsonb_build_object(
        'reschedule_reason', p_reason,
        'reschedule_history',
        coalesce(v_old_meta->'reschedule_history', '[]'::jsonb)
          || jsonb_build_array(
            jsonb_build_object(
              'at', now(),
              'from_starts_at', v_old_starts,
              'from_ends_at', v_old_ends,
              'to_starts_at', p_new_starts_at,
              'to_ends_at', p_new_ends_at,
              'reason', p_reason
            )
          )
      ),
    updated_at = now()
  where a.id = v_appointment_id;

  insert into appointment_events (
    id,
    tenant_id,
    appointment_id,
    source,
    event_type,
    external_ref,
    external_event_id,
    actor_type,
    actor_ref,
    raw_payload
  ) values (
    gen_random_uuid(),
    p_tenant_id,
    v_appointment_id,
    p_source,
    'appointment.rescheduled',
    p_booking_uid,
    p_external_event_id,
    p_actor_type,
    p_actor_ref,
    jsonb_build_object(
      'previous_starts_at', v_old_starts,
      'previous_ends_at', v_old_ends,
      'new_starts_at', p_new_starts_at,
      'new_ends_at', p_new_ends_at,
      'reason', p_reason
    )
  )
  on conflict do nothing;

  return v_appointment_id;
end;
$$;

-- ---------- 2) Cancelar: conservar horario de la cita cancelada en el evento ----------

create or replace function fn_cancel_appointment_by_booking_uid(
  p_tenant_id uuid,
  p_booking_uid text,
  p_cancel_reason text,
  p_source text default 'system',
  p_actor_type text default 'system',
  p_actor_ref text default null,
  p_external_event_id text default null
)
returns uuid
language plpgsql
set search_path = public
as $$
declare
  v_appointment_id uuid;
  v_starts timestamptz;
  v_ends timestamptz;
begin
  select a.id, a.starts_at, a.ends_at
  into v_appointment_id, v_starts, v_ends
  from appointments a
  where a.tenant_id = p_tenant_id
    and a.booking_uid = p_booking_uid
    and a.deleted_at is null
    and a.status in ('pending', 'confirmed', 'rescheduled')
  for update;

  if v_appointment_id is null then
    return null;
  end if;

  update appointments a
  set
    status = 'cancelled',
    cancel_reason = coalesce(p_cancel_reason, a.cancel_reason),
    updated_at = now()
  where a.id = v_appointment_id;

  insert into appointment_events (
    id,
    tenant_id,
    appointment_id,
    source,
    event_type,
    external_ref,
    external_event_id,
    actor_type,
    actor_ref,
    raw_payload
  ) values (
    gen_random_uuid(),
    p_tenant_id,
    v_appointment_id,
    p_source,
    'appointment.cancelled',
    p_booking_uid,
    p_external_event_id,
    p_actor_type,
    p_actor_ref,
    jsonb_build_object(
      'reason', p_cancel_reason,
      'booking_uid', p_booking_uid,
      'cancelled_starts_at', v_starts,
      'cancelled_ends_at', v_ends
    )
  )
  on conflict do nothing;

  return v_appointment_id;
end;
$$;

-- ---------- 3) Vista: una fila por cita próxima o en curso ligada al contacto ----------

create or replace view v_contacto_panel_agenda_citas
with (security_invoker = true)
as
with
linked_patients as (
  select cpl.tenant_id, cpl.contact_id, cpl.patient_id
  from contact_patient_links cpl
  where cpl.deleted_at is null
  union
  select p.tenant_id, p.contact_id, p.id as patient_id
  from patients p
  where p.deleted_at is null
    and p.contact_id is not null
),
base as (
  select
    lp.tenant_id,
    lp.contact_id,
    lp.patient_id,
    a.id as cita_id,
    a.booking_uid,
    a.starts_at as cita_inicio,
    a.ends_at as cita_fin,
    a.status as estado_cita,
    a.reason as motivo_consulta_texto,
    a.source as canal_origen,
    a.metadata as cita_metadata,
    a.cancel_reason,
    a.updated_at as cita_actualizada_en
  from linked_patients lp
  join appointments a
    on a.tenant_id = lp.tenant_id
   and a.patient_id = lp.patient_id
  where a.deleted_at is null
    and a.status in ('pending', 'confirmed', 'rescheduled')
    and a.starts_at is not null
    and (
      a.starts_at > now()
      or (
        a.starts_at <= now()
        and (a.ends_at is null or a.ends_at > now())
      )
    )
),
last_reschedule_event as (
  select distinct on (e.appointment_id)
    e.appointment_id,
    e.created_at as reagendamiento_evento_en,
    e.raw_payload as reagendamiento_payload_evento
  from appointment_events e
  where e.event_type = 'appointment.rescheduled'
  order by e.appointment_id, e.created_at desc
),
meta_hist as (
  select
    b.cita_id,
    b.cita_metadata,
    case jsonb_typeof(b.cita_metadata->'reschedule_history')
      when 'array' then jsonb_array_length(b.cita_metadata->'reschedule_history')
      else 0
    end as reagendamientos_en_metadata
  from base b
)
select
  -- === Identificación del contacto ===
  c.id as contacto_id,
  c.tenant_id,
  c.wa_id as contacto_whatsapp_id,
  c.phone_e164 as contacto_telefono_e164,
  c.phone_digits as contacto_telefono_10_digitos,

  -- === Perfil del paciente en esta fila ===
  p.id as paciente_id,
  p.full_name as paciente_nombre_completo,
  case p.gender
    when 'male' then 'Masculino'
    when 'female' then 'Femenino'
    when 'other' then 'Otro'
    when 'unknown' then 'Sin especificar'
    else coalesce(p.gender, 'Sin especificar')
  end as paciente_genero,
  (coalesce(
    cpl.relationship_type,
    case when p.contact_id = b.contact_id then 'titular' else 'sin_vinculo_explicito' end
  ) = 'titular') as paciente_es_titular,
  coalesce(cpl.relationship_type, case when p.contact_id = b.contact_id then 'titular' else 'sin_vinculo_explicito' end)
    as paciente_relacion_con_contacto,
  coalesce(rt.display_name, coalesce(cpl.relationship_type, 'Titular'))
    as paciente_relacion_etiqueta,

  -- === Agregados: cuántos perfiles y si hay otros con cita ===
  (select count(distinct lp2.patient_id)::int
   from linked_patients lp2
   where lp2.tenant_id = b.tenant_id
     and lp2.contact_id = b.contact_id) as contacto_cantidad_pacientes_vinculados,
  exists (
    select 1
    from base b2
    where b2.tenant_id = b.tenant_id
      and b2.contact_id = b.contact_id
      and b2.patient_id <> b.patient_id
  ) as contacto_otro_familiar_tiene_cita_proxima_o_en_curso,
  (
    select string_agg(
      format(
        '%s | %s | inicio %s',
        coalesce(p3.full_name, p3.id::text),
        coalesce(b3.booking_uid, '(sin booking_uid)'),
        to_char(b3.cita_inicio at time zone 'America/Mexico_City', 'YYYY-MM-DD HH24:MI TZ')
      ),
      e'\n'
      order by b3.cita_inicio
    )
    from base b3
    join patients p3
      on p3.id = b3.patient_id
     and p3.tenant_id = b3.tenant_id
    where b3.tenant_id = b.tenant_id
      and b3.contact_id = b.contact_id
      and b3.patient_id <> b.patient_id
  ) as contacto_resumen_otras_citas_mismo_contacto,

  -- === Cita activa / próxima ===
  b.cita_id,
  b.booking_uid as cita_booking_uid,
  b.cita_inicio,
  b.cita_fin,
  b.estado_cita,
  b.motivo_consulta_texto,
  b.canal_origen as cita_canal_origen,
  loc.display_name as cita_consultorio,
  s.display_name as cita_especialista_nombre,
  s.specialist_code as cita_especialista_codigo,
  b.cita_actualizada_en,

  -- === Bloque: último reagendamiento (misma cita) ===
  (lre.reagendamiento_evento_en is not null or mh.reagendamientos_en_metadata > 0) as historial_hubo_reagendamiento,
  lre.reagendamiento_evento_en as historial_reagendamiento_fecha_evento,
  coalesce(
    (lre.reagendamiento_payload_evento->>'previous_starts_at')::timestamptz,
    (b.cita_metadata->'reschedule_history'->-1->>'from_starts_at')::timestamptz
  ) as historial_reagendamiento_fecha_hora_anterior,
  coalesce(
    (lre.reagendamiento_payload_evento->>'new_starts_at')::timestamptz,
    (b.cita_metadata->'reschedule_history'->-1->>'to_starts_at')::timestamptz,
    b.cita_inicio
  ) as historial_reagendamiento_fecha_hora_nueva,
  coalesce(
    lre.reagendamiento_payload_evento->>'reason',
    b.cita_metadata->'reschedule_history'->-1->>'reason',
    b.cita_metadata->>'reschedule_reason'
  ) as historial_reagendamiento_motivo_texto,
  mh.reagendamientos_en_metadata as historial_reagendamiento_entradas_en_metadata,

  -- === Bloque: última cancelación en el mismo contacto (puede ser otra cita) ===
  ca.cita_id as historial_ultima_cancelacion_cita_id,
  ca.booking_uid as historial_ultima_cancelacion_booking_uid,
  ca.estado_cita as historial_ultima_cancelacion_estado,
  ca.cita_inicio as historial_ultima_cancelacion_cita_inicio_prevista,
  ca.cita_actualizada_en as historial_ultima_cancelacion_fecha_registro,
  ca.cancel_reason as historial_ultima_cancelacion_motivo_tabla,
  lce.cancel_evento_en as historial_ultima_cancelacion_fecha_evento,
  lce.cancel_payload as historial_ultima_cancelacion_payload_evento

from base b
join contacts c
  on c.id = b.contact_id
 and c.tenant_id = b.tenant_id
 and c.deleted_at is null
join patients p
  on p.id = b.patient_id
 and p.tenant_id = b.tenant_id
 and p.deleted_at is null
left join contact_patient_links cpl
  on cpl.tenant_id = b.tenant_id
 and cpl.contact_id = b.contact_id
 and cpl.patient_id = b.patient_id
 and cpl.deleted_at is null
left join relationship_types rt
  on rt.id = cpl.relationship_type_id
join appointments a
  on a.id = b.cita_id
left join specialists s
  on s.id = a.specialist_id
 and s.tenant_id = a.tenant_id
left join locations loc
  on loc.id = a.location_id
 and loc.tenant_id = a.tenant_id
left join last_reschedule_event lre
  on lre.appointment_id = b.cita_id
left join meta_hist mh
  on mh.cita_id = b.cita_id
left join lateral (
  select
    a5.id as cita_id,
    a5.booking_uid,
    a5.starts_at as cita_inicio,
    a5.ends_at as cita_fin,
    a5.status as estado_cita,
    a5.cancel_reason,
    a5.updated_at as cita_actualizada_en
  from appointments a5
  join linked_patients lp4
    on lp4.patient_id = a5.patient_id
   and lp4.tenant_id = a5.tenant_id
   and lp4.contact_id = b.contact_id
  where a5.tenant_id = b.tenant_id
    and a5.deleted_at is null
    and a5.status = 'cancelled'
  order by a5.updated_at desc nulls last
  limit 1
) ca on true
left join lateral (
  select
    e2.created_at as cancel_evento_en,
    e2.raw_payload as cancel_payload
  from appointment_events e2
  where ca.cita_id is not null
    and e2.appointment_id = ca.cita_id
    and e2.event_type = 'appointment.cancelled'
  order by e2.created_at desc
  limit 1
) lce on true;

comment on view v_contacto_panel_agenda_citas is
  'Panel por contacto: citas próximas o en curso de pacientes vinculados; resumen de otras citas del mismo contacto; último reagendamiento (evento/metadata) y última cancelación en la familia.';

-- Datos de prueba opcionales: ejecutar 016_seed_demo_panel_agenda.sql después de este script.
