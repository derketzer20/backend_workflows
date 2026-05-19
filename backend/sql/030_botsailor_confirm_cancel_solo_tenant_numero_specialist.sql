-- =============================================================================
-- 030 — BotSailor entrante: solo numero + tenant_id + specialist (sin booking, sin confirmacion_hora)
-- =============================================================================
-- DOS URLs / dos funciones (BotSailor elige según botón WhatsApp):
--   fn_botsailor_confirm_appointment(p_payload)
--   fn_botsailor_cancel_appointment(p_payload)
--
-- Body (PostgREST envuelve el array):
-- {"p_payload":[{"numero":"5215548649518","tenant_id":"uuid","specialist_code":"dr_juan"}]}
--
-- Recordatorio 4h/24h (023) NO llama estas funciones → no cambia status al enviar.
--
-- Varias citas mismo número (titular + familiares): se elige la cita activa
-- con recordatorio 4h pendiente de respuesta y starts_at más próximo; si no,
-- la próxima activa con ese especialista.
-- =============================================================================

create or replace function fn_resolve_appointment_for_botsailor(
  p_tenant_id uuid,
  p_numero text,
  p_specialist_id uuid default null,
  p_specialist_code text default null,
  p_booking_uid text default null,
  p_prefer_4h_pending boolean default true
)
returns table (
  appointment_id uuid,
  booking_uid text,
  patient_id uuid,
  starts_at timestamptz
)
language plpgsql
stable
set search_path = public
as $$
declare
  v_numero text;
begin
  if p_booking_uid is not null and btrim(p_booking_uid) <> '' then
    return query
    select a.id, a.booking_uid, a.patient_id, a.starts_at
    from appointments a
    where a.tenant_id = p_tenant_id
      and a.booking_uid = p_booking_uid
      and a.deleted_at is null
      and a.status in ('pending', 'confirmed', 'rescheduled')
    limit 1;
    return;
  end if;

  v_numero := normalize_wa_id_mx(p_numero);
  if v_numero is null then
    return;
  end if;

  if p_specialist_id is null and (p_specialist_code is null or btrim(p_specialist_code) = '') then
    raise exception 'indique p_specialist_id o p_specialist_code';
  end if;

  return query
  with contacto as (
    select c.id as contact_id
    from contacts c
    where c.tenant_id = p_tenant_id
      and c.deleted_at is null
      and normalize_wa_id_mx(coalesce(c.wa_id, c.phone_e164, c.phone_digits)) = v_numero
    order by c.last_seen_at desc nulls last
    limit 1
  ),
  pacientes as (
    select p.id as patient_id
    from contacto co
    join patients p
      on p.tenant_id = p_tenant_id
     and p.deleted_at is null
     and p.contact_id = co.contact_id
    union
    select p.id
    from contacto co
    join contact_patient_links l
      on l.tenant_id = p_tenant_id
     and l.contact_id = co.contact_id
     and l.deleted_at is null
    join patients p
      on p.id = l.patient_id
     and p.tenant_id = p_tenant_id
     and p.deleted_at is null
  )
  select
    a.id,
    a.booking_uid,
    a.patient_id,
    a.starts_at
  from appointments a
  join pacientes px on px.patient_id = a.patient_id
  join specialists s
    on s.id = a.specialist_id
   and s.tenant_id = a.tenant_id
   and s.deleted_at is null
  left join appointment_reminder_dispatches d4
    on d4.appointment_id = a.id
   and d4.reminder_kind = '4h'
  where a.tenant_id = p_tenant_id
    and a.deleted_at is null
    and a.status in ('pending', 'confirmed', 'rescheduled')
    and a.starts_at is not null
    and a.starts_at > now() - interval '30 minutes'
    and (
      (p_specialist_id is not null and s.id = p_specialist_id)
      or (
        p_specialist_code is not null
        and btrim(p_specialist_code) <> ''
        and lower(s.specialist_code) = lower(btrim(p_specialist_code))
      )
    )
    and (
      not p_prefer_4h_pending
      or (
        d4.id is not null
        and coalesce(a.metadata->>'reminder_4h_confirmed_at', '') = ''
        and coalesce(a.metadata->>'reminder_4h_response', '') not in ('confirmed', 'cancelled')
      )
    )
  order by
    case when p_prefer_4h_pending and d4.id is not null then 0 else 1 end,
    a.starts_at asc
  limit 1;
end;
$$;

-- ---------- Parsear payload array [{ numero, tenant_id, specialist_* }] ----------

create or replace function fn_botsailor_parse_payload(p_payload jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  v_item jsonb;
begin
  v_item := case jsonb_typeof(p_payload)
    when 'array' then p_payload->0
    when 'object' then p_payload
    else null
  end;
  if v_item is null then
    return null;
  end if;
  return jsonb_build_object(
    'numero', v_item->>'numero',
    'tenant_id', v_item->>'tenant_id',
    'specialist_code', v_item->>'specialist_code',
    'specialist_id', v_item->>'specialist_id'
  );
end;
$$;

create or replace function fn_botsailor_confirm_appointment(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_p jsonb;
  v_numero text;
  v_tenant_id uuid;
  v_specialist_code text;
  v_specialist_id uuid;
  v_appointment_id uuid;
  v_booking_uid text;
begin
  v_p := fn_botsailor_parse_payload(p_payload);
  if v_p is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_payload');
  end if;

  v_numero := normalize_wa_id_mx(v_p->>'numero');
  if v_numero is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_numero');
  end if;

  begin
    v_tenant_id := (v_p->>'tenant_id')::uuid;
  exception
    when others then
      return jsonb_build_object('ok', false, 'error', 'invalid_tenant_id');
  end if;

  v_specialist_code := nullif(trim(v_p->>'specialist_code'), '');
  if v_p ? 'specialist_id' and nullif(trim(v_p->>'specialist_id'), '') is not null then
    v_specialist_id := (v_p->>'specialist_id')::uuid;
  end if;

  select r.appointment_id, r.booking_uid
  into v_appointment_id, v_booking_uid
  from fn_resolve_appointment_for_botsailor(
    v_tenant_id, v_numero, v_specialist_id, v_specialist_code, null, true
  ) r;

  if v_appointment_id is null then
    select r.appointment_id, r.booking_uid
    into v_appointment_id, v_booking_uid
    from fn_resolve_appointment_for_botsailor(
      v_tenant_id, v_numero, v_specialist_id, v_specialist_code, null, false
    ) r;
  end if;

  if v_appointment_id is null or v_booking_uid is null then
    return jsonb_build_object(
      'ok', false,
      'error', 'appointment_not_found',
      'numero', v_numero,
      'tenant_id', v_tenant_id
    );
  end if;

  v_appointment_id := fn_confirm_appointment_by_booking_uid(
    v_tenant_id,
    v_booking_uid,
    'whatsapp',
    'patient',
    v_numero,
    null,
    jsonb_build_object('via', 'botsailor_confirm', 'numero', v_numero)
  );

  return jsonb_build_object(
    'ok', v_appointment_id is not null,
    'action', 'confirmed',
    'appointment_id', v_appointment_id,
    'booking_uid', v_booking_uid,
    'numero', v_numero
  );
end;
$$;

create or replace function fn_botsailor_cancel_appointment(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_p jsonb;
  v_numero text;
  v_tenant_id uuid;
  v_specialist_code text;
  v_specialist_id uuid;
  v_appointment_id uuid;
  v_booking_uid text;
begin
  v_p := fn_botsailor_parse_payload(p_payload);
  if v_p is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_payload');
  end if;

  v_numero := normalize_wa_id_mx(v_p->>'numero');
  if v_numero is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_numero');
  end if;

  begin
    v_tenant_id := (v_p->>'tenant_id')::uuid;
  exception
    when others then
      return jsonb_build_object('ok', false, 'error', 'invalid_tenant_id');
  end if;

  v_specialist_code := nullif(trim(v_p->>'specialist_code'), '');
  if v_p ? 'specialist_id' and nullif(trim(v_p->>'specialist_id'), '') is not null then
    v_specialist_id := (v_p->>'specialist_id')::uuid;
  end if;

  select r.appointment_id, r.booking_uid
  into v_appointment_id, v_booking_uid
  from fn_resolve_appointment_for_botsailor(
    v_tenant_id, v_numero, v_specialist_id, v_specialist_code, null, true
  ) r;

  if v_appointment_id is null then
    select r.appointment_id, r.booking_uid
    into v_appointment_id, v_booking_uid
    from fn_resolve_appointment_for_botsailor(
      v_tenant_id, v_numero, v_specialist_id, v_specialist_code, null, false
    ) r;
  end if;

  if v_appointment_id is null or v_booking_uid is null then
    return jsonb_build_object(
      'ok', false,
      'error', 'appointment_not_found',
      'numero', v_numero,
      'tenant_id', v_tenant_id
    );
  end if;

  v_appointment_id := fn_cancel_appointment_by_booking_uid(
    v_tenant_id,
    v_booking_uid,
    'Cancelada por paciente (BotSailor cancel)',
    'whatsapp',
    'patient',
    v_numero,
    null
  );

  if v_appointment_id is not null then
    update appointments a
    set metadata = coalesce(a.metadata, '{}'::jsonb)
      || jsonb_build_object(
        'reminder_4h_response', 'cancelled',
        'reminder_4h_cancelled_at', now()
      )
    where a.id = v_appointment_id;
  end if;

  return jsonb_build_object(
    'ok', v_appointment_id is not null,
    'action', 'cancelled',
    'appointment_id', v_appointment_id,
    'booking_uid', v_booking_uid,
    'numero', v_numero
  );
end;
$$;

revoke all on function fn_botsailor_confirm_appointment(jsonb) from public, anon, authenticated;
revoke all on function fn_botsailor_cancel_appointment(jsonb) from public, anon, authenticated;
grant execute on function fn_botsailor_confirm_appointment(jsonb) to service_role;
grant execute on function fn_botsailor_cancel_appointment(jsonb) to service_role;

-- Opcional: desactivar webhook único viejo que infería por confirmacion_hora
-- drop function if exists fn_botsailor_reminder_webhook(jsonb);
