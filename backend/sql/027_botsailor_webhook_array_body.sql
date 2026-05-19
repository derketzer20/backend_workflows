-- =============================================================================
-- 027 — Webhook BotSailor: body tipo array [{ numero, confirmacion_hora, ... }]
-- =============================================================================
-- BotSailor NO envía booking_uid.
-- confirmacion_hora con valor  → confirmar cita
-- confirmacion_hora vacío    → cancelar cita (usuario no confirmó / rechazó)
-- Sin respuesta (timeout)    → BotSailor no llama; usa cron más abajo
--
-- PostgREST exige un nombre de parámetro (no puede ser solo el array suelto):
-- POST .../rest/v1/rpc/fn_botsailor_reminder_webhook
-- Body:
-- {"p_payload":[{"numero":"5215548649518","confirmacion_hora":"02:30 PM","tenant_id":"...","specialist_code":"dr_juan"}]}
--
-- Si BotSailor solo puede pegar el array, envuelve en un paso previo o usa Edge Function.
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
  v_tenant_id uuid;
  v_specialist_code text;
  v_specialist_id uuid;
  v_action text;
  v_appointment_id uuid;
  v_booking_uid text;
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

  v_action := case when v_confirm_hora is not null then 'confirmed' else 'cancelled' end;

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
      'action', v_action
    );
  end if;

  if v_action = 'confirmed' then
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
        'via', 'botsailor_array_webhook'
      )
    );
    return jsonb_build_object(
      'ok', v_appointment_id is not null,
      'action', 'confirmed',
      'appointment_id', v_appointment_id,
      'booking_uid', v_booking_uid,
      'numero', v_numero,
      'confirmacion_hora', v_confirm_hora
    );
  end if;

  v_appointment_id := fn_cancel_appointment_by_booking_uid(
    v_tenant_id,
    v_booking_uid,
    'Cancelada: recordatorio 4h sin confirmación (confirmacion_hora vacía)',
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
  'BotSailor array: numero + confirmacion_hora (vacío=cancelar, con valor=confirmar). Opcional tenant_id, specialist_code.';

revoke all on function fn_botsailor_reminder_webhook(jsonb) from public, anon, authenticated;
grant execute on function fn_botsailor_reminder_webhook(jsonb) to service_role;

-- ---------- Sin respuesta: BotSailor no envía → cron cancela ----------
-- Citas con recordatorio 4h enviado hace >2h, sin confirmación en metadata.

create or replace function fn_cancel_unconfirmed_4h_reminders(
  p_hours_since_reminder numeric default 2
)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count int := 0;
  r record;
begin
  for r in
    select
      a.id as appointment_id,
      a.tenant_id,
      a.booking_uid
    from appointments a
    join appointment_reminder_dispatches d
      on d.appointment_id = a.id
     and d.reminder_kind = '4h'
    where a.deleted_at is null
      and a.status in ('pending', 'confirmed', 'rescheduled')
      and d.sent_at < now() - make_interval(hours => p_hours_since_reminder::integer)
      and coalesce(a.metadata->>'reminder_4h_confirmed_at', '') = ''
      and coalesce(a.metadata->>'reminder_4h_response', '') = ''
  loop
    perform fn_cancel_appointment_by_booking_uid(
      r.tenant_id,
      r.booking_uid,
      'Cancelada: sin respuesta tras recordatorio 4h (timeout)',
      'system',
      'system',
      'cron-no-response-4h',
      null
    );
    update appointments a
    set metadata = coalesce(a.metadata, '{}'::jsonb)
      || jsonb_build_object(
        'reminder_4h_response', 'no_response',
        'reminder_4h_cancelled_at', now()
      )
    where a.id = r.appointment_id;
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

grant execute on function fn_cancel_unconfirmed_4h_reminders(numeric) to service_role;

-- Cron cada 30 min (ajusta si quieres otro intervalo):
-- select cron.schedule(
--   'appointment-reminder-4h-no-response',
--   '*/30 * * * *',
--   $$ select fn_cancel_unconfirmed_4h_reminders(2); $$
-- );
