-- =============================================================================
-- 029 — Evitar confirmar/cancelar al solo enviar recordatorio (BotSailor)
-- =============================================================================
-- fn_dispatch (4h/24h) NO cambia status. El cambio venía del webhook entrante:
-- BotSailor copiaba "hora" del recordatorio en "confirmacion_hora" → Supabase
-- lo interpretaba como confirmación.
--
-- Ahora hace falta campo explícito accion:
--   "confirmado" → status confirmed
--   "cancelado"  → status cancelled (+ limpieza opcional en otro flujo)
-- Sin accion o valor inválido → NO toca la cita (ignored)
-- =============================================================================

create or replace function fn_botsailor_reminder_webhook(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item jsonb;
  v_numero text;
  v_confirm_hora text;
  v_accion text;
  v_tenant_id uuid;
  v_specialist_code text;
  v_specialist_id uuid;
  v_appointment_id uuid;
  v_booking_uid text;
  v_appt_hora text;
begin
  if p_payload is null then
    return jsonb_build_object('ok', false, 'error', 'payload_required');
  end if;

  v_item := case jsonb_typeof(p_payload)
    when 'array' then p_payload->0
    when 'object' then p_payload
    else null
  end;

  if v_item is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_payload_shape');
  end if;

  v_numero := normalize_wa_id_mx(v_item->>'numero');
  if v_numero is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_numero');
  end if;

  v_accion := lower(trim(coalesce(
    v_item->>'accion',
    v_item->>'action',
    ''
  )));

  if v_accion not in ('confirmado', 'cancelado') then
    return jsonb_build_object(
      'ok', true,
      'action', 'ignored',
      'reason', 'accion_requerida',
      'hint', 'Use accion=confirmado o accion=cancelado. No llamar este webhook al enviar el recordatorio.',
      'numero', v_numero
    );
  end if;

  v_confirm_hora := nullif(trim(v_item->>'confirmacion_hora'), '');

  if v_item ? 'tenant_id' and nullif(trim(v_item->>'tenant_id'), '') is not null then
    begin
      v_tenant_id := (v_item->>'tenant_id')::uuid;
    exception
      when others then
        return jsonb_build_object('ok', false, 'error', 'invalid_tenant_id');
    end;
  end if;

  v_specialist_code := nullif(trim(v_item->>'specialist_code'), '');

  if v_item ? 'specialist_id' and nullif(trim(v_item->>'specialist_id'), '') is not null then
    begin
      v_specialist_id := (v_item->>'specialist_id')::uuid;
    exception
      when others then
        return jsonb_build_object('ok', false, 'error', 'invalid_specialist_id');
    end;
  end if;

  if v_tenant_id is null then
    select c.tenant_id into v_tenant_id
    from contacts c
    where c.deleted_at is null
      and normalize_wa_id_mx(coalesce(c.wa_id, c.phone_e164, c.phone_digits)) = v_numero
    order by c.last_seen_at desc nulls last
    limit 1;
  end if;

  if v_tenant_id is null then
    return jsonb_build_object('ok', false, 'error', 'tenant_not_found', 'numero', v_numero);
  end if;

  select r.appointment_id, r.booking_uid
  into v_appointment_id, v_booking_uid
  from fn_resolve_appointment_for_botsailor(
    v_tenant_id,
    v_numero,
    v_specialist_id,
    v_specialist_code,
    null
  ) r;

  if v_appointment_id is null or v_booking_uid is null then
    return jsonb_build_object(
      'ok', false,
      'error', 'appointment_not_found',
      'numero', v_numero,
      'tenant_id', v_tenant_id,
      'accion', v_accion
    );
  end if;

  select trim(to_char(a.starts_at at time zone 'America/Monterrey', 'HH12:MI AM'))
  into v_appt_hora
  from appointments a
  where a.id = v_appointment_id;

  if v_accion = 'confirmado' then
    if v_confirm_hora is not null
       and v_appt_hora is not null
       and lower(v_confirm_hora) = lower(v_appt_hora) then
      return jsonb_build_object(
        'ok', true,
        'action', 'ignored',
        'reason', 'confirmacion_hora_igual_a_hora_cita',
        'hint', 'Parece eco del recordatorio; use accion=confirmado solo al pulsar Confirmar en WhatsApp.',
        'appointment_id', v_appointment_id
      );
    end if;

    v_appointment_id := fn_confirm_appointment_by_booking_uid(
      v_tenant_id,
      v_booking_uid,
      'whatsapp',
      'patient',
      v_numero,
      null,
      jsonb_build_object(
        'numero', v_numero,
        'confirmacion_hora', v_confirm_hora,
        'accion', 'confirmado',
        'via', 'botsailor_array_webhook'
      )
    );
    return jsonb_build_object(
      'ok', v_appointment_id is not null,
      'action', 'confirmed',
      'appointment_id', v_appointment_id,
      'booking_uid', v_booking_uid,
      'numero', v_numero
    );
  end if;

  v_appointment_id := fn_cancel_appointment_by_booking_uid(
    v_tenant_id,
    v_booking_uid,
    'Cancelada por paciente (recordatorio 4h, accion=cancelado)',
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

comment on function fn_botsailor_reminder_webhook(jsonb) is
  'Requiere accion=confirmado|cancelado. Sin accion no modifica citas (evita auto-confirm al enviar recordatorio).';
