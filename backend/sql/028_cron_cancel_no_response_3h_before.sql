-- =============================================================================
-- 028 — Cron: sin confirmación tras recordatorio 4h y faltan ~3h para la cita
-- =============================================================================
-- Condición (ventana ±15 min, cron cada 15 min):
--   - Recordatorio 4h ya enviado (appointment_reminder_dispatches)
--   - Sin confirmación en metadata
--   - starts_at entre now()+2h45m y now()+3h15m
-- Acción:
--   - status = cancelled, status_type_id = 4
--   - starts_at, ends_at, booking_uid = NULL
--   - metadata con trazabilidad
-- =============================================================================

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
        'reminder_4h_response', 'no_response'
      )
    );

    update appointments a
    set
      status = 'cancelled',
      status_type_id = 4,
      cancel_reason = 'Cancelada: sin confirmación (~3h antes de la cita)',
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
          'previous_ends_at', r.ends_at
        ),
      updated_at = now()
    where a.id = r.appointment_id;

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

comment on function fn_cancel_no_response_3h_before_appointment(int) is
  'Cancela citas sin confirmar 4h cuando faltan ~3h; limpia starts_at, ends_at, booking_uid.';

revoke all on function fn_cancel_no_response_3h_before_appointment(int)
  from public, anon, authenticated;

grant execute on function fn_cancel_no_response_3h_before_appointment(int) to service_role;

-- Cron cada 15 min (misma cadencia que recordatorios 4h/24h)
-- Quitar job anterior si existía (ignorar error si no está):
-- select cron.unschedule('appointment-reminder-4h-no-response');

select cron.schedule(
  'appointment-cancel-no-response-3h',
  '*/15 * * * *',
  $$ select fn_cancel_no_response_3h_before_appointment(15); $$
);

-- Prueba manual:
-- select fn_cancel_no_response_3h_before_appointment(15);

-- Ver próximas citas que entrarían en ventana 3h:
-- select a.booking_uid, a.starts_at, a.starts_at - now() as falta, a.status, a.metadata->>'reminder_4h_response'
-- from appointments a
-- where a.deleted_at is null and a.starts_at is not null
-- order by a.starts_at;
