-- =============================================================================
-- 025 — SOLO webhook ENTRANTE BotSailor → Supabase (confirm / cancel / no_response)
-- =============================================================================
-- NO modifica el body del recordatorio 4h saliente (sigue en 023: numero + hora).
--
-- BotSailor POST → /rest/v1/rpc/fn_botsailor_reminder_response
-- Body JSON (mismos campos para las 3 acciones; solo cambia "action"):
-- {
--   "p_webhook_secret": "<secreto>",
--   "p_body": {
--     "action": "confirmed",
--     "tenant_id": "uuid-tenant",
--     "numero": "5215565062809",
--     "specialist_code": "dr_juan"
--   }
-- }
-- action: confirmed | cancelled | no_response
-- specialist_code O specialist_id (uno obligatorio si no hay booking_id)
-- booking_id opcional si en el futuro lo envían
-- =============================================================================

-- ---------- Resolver cita activa próxima ----------

create or replace function fn_resolve_appointment_for_botsailor(
  p_tenant_id uuid,
  p_numero text,
  p_specialist_id uuid default null,
  p_specialist_code text default null,
  p_booking_uid text default null
)
returns table (
  appointment_id uuid,
  booking_uid text
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
    select a.id, a.booking_uid
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
  select a.id, a.booking_uid
  from appointments a
  join patients p
    on p.id = a.patient_id
   and p.tenant_id = a.tenant_id
   and p.deleted_at is null
  join contacts c
    on c.id = p.contact_id
   and c.tenant_id = a.tenant_id
   and c.deleted_at is null
  join specialists s
    on s.id = a.specialist_id
   and s.tenant_id = a.tenant_id
   and s.deleted_at is null
  where a.tenant_id = p_tenant_id
    and a.deleted_at is null
    and a.status in ('pending', 'confirmed', 'rescheduled')
    and a.starts_at is not null
    and a.starts_at > now() - interval '30 minutes'
    and normalize_wa_id_mx(coalesce(c.wa_id, c.phone_e164, c.phone_digits)) = v_numero
    and (
      (p_specialist_id is not null and s.id = p_specialist_id)
      or (
        p_specialist_code is not null
        and btrim(p_specialist_code) <> ''
        and lower(s.specialist_code) = lower(btrim(p_specialist_code))
      )
    )
  order by a.starts_at asc
  limit 1;
end;
$$;

-- Reemplazar RPC entrante (body JSON sin booking_id obligatorio)
drop function if exists fn_botsailor_reminder_response(text, text, text, uuid, text, jsonb);
drop function if exists fn_botsailor_reminder_response(text, text, uuid, text, text, uuid, text, text, jsonb);

create or replace function fn_botsailor_reminder_response(
  p_webhook_secret text,
  p_body jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_expected_secret text;
  v_action text;
  v_numero text;
  v_tenant_id uuid;
  v_specialist_code text;
  v_specialist_id uuid;
  v_booking_uid text;
  v_appointment_id uuid;
  v_resolved_booking_uid text;
begin
  select webhook_url into v_expected_secret
  from integration_webhook_config
  where key = 'botsailor_inbound_secret';

  if v_expected_secret is null
     or p_webhook_secret is null
     or p_webhook_secret <> v_expected_secret then
    raise exception 'webhook_secret invalid' using errcode = '28000';
  end if;

  if p_body is null then
    raise exception 'p_body is required';
  end if;

  v_action := lower(trim(coalesce(p_body->>'action', '')));
  if v_action not in ('confirmed', 'cancelled', 'no_response') then
    raise exception 'action debe ser confirmed, cancelled o no_response';
  end if;

  begin
    v_tenant_id := (p_body->>'tenant_id')::uuid;
  exception
    when others then
      return jsonb_build_object('ok', false, 'error', 'invalid_tenant_id');
  end;

  v_numero := normalize_wa_id_mx(p_body->>'numero');
  if v_numero is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_numero');
  end if;

  v_specialist_code := nullif(trim(p_body->>'specialist_code'), '');
  v_booking_uid := nullif(trim(p_body->>'booking_id'), '');
  if v_booking_uid is null then
    v_booking_uid := nullif(trim(p_body->>'booking_uid'), '');
  end if;

  if p_body ? 'specialist_id' and nullif(trim(p_body->>'specialist_id'), '') is not null then
    begin
      v_specialist_id := (p_body->>'specialist_id')::uuid;
    exception
      when others then
        return jsonb_build_object('ok', false, 'error', 'invalid_specialist_id');
    end;
  end if;

  select r.appointment_id, r.booking_uid
  into v_appointment_id, v_resolved_booking_uid
  from fn_resolve_appointment_for_botsailor(
    v_tenant_id,
    v_numero,
    v_specialist_id,
    v_specialist_code,
    v_booking_uid
  ) r;

  if v_appointment_id is null or v_resolved_booking_uid is null then
    return jsonb_build_object(
      'ok', false,
      'error', 'appointment_not_found',
      'action', v_action,
      'tenant_id', v_tenant_id,
      'numero', v_numero,
      'specialist_code', v_specialist_code,
      'specialist_id', v_specialist_id
    );
  end if;

  if v_action = 'confirmed' then
    v_appointment_id := fn_confirm_appointment_by_booking_uid(
      v_tenant_id,
      v_resolved_booking_uid,
      'whatsapp',
      'patient',
      v_numero,
      null,
      p_body
    );
    return jsonb_build_object(
      'ok', v_appointment_id is not null,
      'action', 'confirmed',
      'appointment_id', v_appointment_id,
      'booking_uid', v_resolved_booking_uid,
      'numero', v_numero
    );
  end if;

  v_appointment_id := fn_cancel_appointment_by_booking_uid(
    v_tenant_id,
    v_resolved_booking_uid,
    case v_action
      when 'no_response' then 'Cancelada: sin confirmación recordatorio 4h'
      else 'Cancelada por paciente (recordatorio 4h)'
    end,
    'whatsapp',
    'patient',
    v_numero,
    null
  );

  if v_appointment_id is not null then
    update appointments a
    set metadata = coalesce(a.metadata, '{}'::jsonb)
      || jsonb_build_object(
        'reminder_4h_response', v_action,
        'reminder_4h_cancelled_at', now()
      )
    where a.id = v_appointment_id;
  end if;

  return jsonb_build_object(
    'ok', v_appointment_id is not null,
    'action', v_action,
    'appointment_id', v_appointment_id,
    'booking_uid', v_resolved_booking_uid,
    'numero', v_numero
  );
end;
$$;

comment on function fn_botsailor_reminder_response(text, jsonb) is
  'BotSailor entrante: p_body con action, tenant_id, numero, specialist_code|specialist_id.';

revoke all on function fn_botsailor_reminder_response(text, jsonb)
  from public, anon, authenticated;

grant execute on function fn_botsailor_reminder_response(text, jsonb)
  to service_role;

grant execute on function fn_resolve_appointment_for_botsailor(uuid, text, uuid, text, text)
  to service_role;
