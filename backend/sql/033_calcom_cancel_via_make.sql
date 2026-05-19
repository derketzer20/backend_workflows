-- =============================================================================
-- 033 — Cancelar booking en Cal.com vía Make (WhatsApp + cron 3h)
-- =============================================================================
-- 1) Webhook Make (escenario Calcom_Cancel_Booking) recibe booking_uid + motivo.
-- 2) Cron fn_cancel_no_response_3h_before_appointment avisa a Make ANTES de borrar booking_uid.
--
-- Tras importar el blueprint en Make, pegar la URL del webhook aquí:
--   update integration_webhook_config
--   set webhook_url = 'https://app.e-smart360.com/webhook/...', updated_at = now()
--   where key = 'calcom_cancel_via_make';
-- =============================================================================

insert into integration_webhook_config (key, webhook_url)
values (
  'calcom_cancel_via_make',
  'CAMBIAR_POR_URL_WEBHOOK_MAKE_Calcom_Cancel_Booking'
)
on conflict (key) do nothing;

-- ---------- Notificar a Make (pg_net) ----------

create or replace function fn_notify_calcom_cancel_via_make(
  p_booking_uid text,
  p_cancel_reason text,
  p_source text default 'system',
  p_tenant_id uuid default null,
  p_appointment_id uuid default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text;
begin
  if p_booking_uid is null or btrim(p_booking_uid) = '' then
    return false;
  end if;

  select c.webhook_url
  into v_url
  from integration_webhook_config c
  where c.key = 'calcom_cancel_via_make';

  if v_url is null or btrim(v_url) = '' or v_url like 'CAMBIAR_%' then
    raise warning 'calcom_cancel_via_make: falta webhook_url en integration_webhook_config';
    return false;
  end if;

  perform net.http_post(
    url := v_url,
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body := jsonb_strip_nulls(
      jsonb_build_object(
        'booking_uid', p_booking_uid,
        'cancel_reason', coalesce(nullif(btrim(p_cancel_reason), ''), 'Cancelación automática'),
        'source', coalesce(nullif(btrim(p_source), ''), 'system'),
        'tenant_id', p_tenant_id,
        'appointment_id', p_appointment_id
      )
    )
  );

  return true;
end;
$$;

comment on function fn_notify_calcom_cancel_via_make(text, text, text, uuid, uuid) is
  'POST a Make para POST Cal.com /v2/bookings/{uid}/cancel. No cancela en BD.';

revoke all on function fn_notify_calcom_cancel_via_make(text, text, text, uuid, uuid)
  from public, anon, authenticated;
grant execute on function fn_notify_calcom_cancel_via_make(text, text, text, uuid, uuid)
  to service_role;

-- ---------- Cron 3h: avisar Make antes de limpiar booking_uid ----------

create or replace function fn_cancel_no_response_3h_before_appointment(
  p_window_minutes int default 15
)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_from timestamptz;
  v_to timestamptz;
  v_count int := 0;
  v_cancel_reason text := 'Cancelada: sin confirmación (~3h antes de la cita)';
  r record;
begin
  v_from := now() + interval '3 hours' - make_interval(mins => p_window_minutes);
  v_to   := now() + interval '3 hours' + make_interval(mins => p_window_minutes);

  for r in
    select
      a.id as appointment_id,
      a.tenant_id,
      a.booking_uid,
      a.starts_at,
      a.ends_at,
      a.patient_id
    from appointments a
    where a.deleted_at is null
      and a.status in ('pending', 'confirmed', 'rescheduled')
      and a.starts_at is not null
      and a.starts_at between v_from and v_to
      and exists (
        select 1
        from appointment_reminder_dispatches d
        where d.appointment_id = a.id
          and d.reminder_kind = '4h'
      )
      and coalesce(a.metadata->>'reminder_4h_confirmed_at', '') = ''
      and coalesce(a.metadata->>'reminder_4h_response', '') not in ('confirmed', 'cancelled')
  loop
    if r.booking_uid is not null and btrim(r.booking_uid) <> '' then
      perform fn_notify_calcom_cancel_via_make(
        r.booking_uid,
        v_cancel_reason,
        'cron_3h_before',
        r.tenant_id,
        r.appointment_id
      );
    end if;

    insert into appointment_events (
      id,
      tenant_id,
      appointment_id,
      source,
      source_type_id,
      event_type,
      event_type_id,
      actor_type,
      actor_ref,
      external_ref,
      raw_payload
    ) values (
      gen_random_uuid(),
      r.tenant_id,
      r.appointment_id,
      'system',
      4,
      'appointment.cancelled',
      4,
      'system',
      'cron-no-response-3h',
      coalesce(r.booking_uid, r.appointment_id::text),
      jsonb_build_object(
        'reason', 'Sin confirmación: faltaban ~3h para la cita tras recordatorio 4h',
        'previous_booking_uid', r.booking_uid,
        'previous_starts_at', r.starts_at,
        'previous_ends_at', r.ends_at,
        'reminder_4h_response', 'no_response',
        'calcom_cancel_via_make', r.booking_uid is not null
      )
    );

    update appointments a
    set
      status = 'cancelled',
      status_type_id = 4,
      cancel_reason = v_cancel_reason,
      starts_at = null,
      ends_at = null,
      booking_uid = null,
      metadata = coalesce(a.metadata, '{}'::jsonb)
        || jsonb_build_object(
          'reminder_4h_response', 'no_response',
          'reminder_4h_cancelled_at', now(),
          'cancelled_by', 'cron_3h_before',
          'previous_booking_uid', r.booking_uid,
          'previous_starts_at', r.starts_at,
          'previous_ends_at', r.ends_at,
          'calcom_cancel_requested_at', now()
        ),
      updated_at = now()
    where a.id = r.appointment_id;

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

comment on function fn_cancel_no_response_3h_before_appointment(int) is
  'Cancela en BD sin confirmación ~3h antes; notifica Make/Cal.com antes de borrar booking_uid.';

-- Prueba manual notificación (sin cancelar BD):
-- select fn_notify_calcom_cancel_via_make('TU_BOOKING_UID', 'prueba manual', 'manual');
