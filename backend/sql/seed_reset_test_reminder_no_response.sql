-- =============================================================================
-- Reset cita TEST — fechas normalizadas en UTC (timestamptz)
-- =============================================================================
-- Postgres guarda timestamptz en UTC (se ve como 2026-05-18 10:34:00+00).
-- El +5 h se calcula desde tu hora local (America/Monterrey), no desde UTC del servidor.
--
-- Recordatorio 4h: starts_at en [now()+4h ± 15m]
-- Cancel sin respuesta (028): starts_at en [now()+3h ± 15m]
--
-- Con +5h UTC: recordatorio 4h ~en 1 h; cancel ~en 2 h si no confirman.
-- Para recordatorio en el próximo cron: cambia '5 hours' → '4 hours 5 minutes'.
-- =============================================================================

begin;

delete from appointment_reminder_dispatches d
using appointments a
where d.appointment_id = a.id
  and a.booking_uid = 'TEST-REMINDER-24H-5565062809';

update appointments a
set
  status = 'pending',
  status_type_id = 1,
  starts_at = (
    date_trunc(
      'minute',
      (timezone('America/Monterrey', now()) + interval '5 hours')
    ) at time zone 'America/Monterrey'
  ),
  ends_at = (
    date_trunc(
      'minute',
      (timezone('America/Monterrey', now()) + interval '5 hours 30 minutes')
    ) at time zone 'America/Monterrey'
  ),
  cancel_reason = null,
  metadata = coalesce(a.metadata, '{}'::jsonb)
    - 'reminder_4h_response'
    - 'reminder_4h_confirmed_at'
    - 'reminder_4h_cancelled_at'
    - 'botsailor_status'
    - 'cancelled_by'
    - 'previous_booking_uid'
    - 'previous_starts_at'
    - 'previous_ends_at',
  updated_at = (date_trunc('minute', timezone('America/Monterrey', now())) at time zone 'America/Monterrey')
where a.booking_uid = 'TEST-REMINDER-24H-5565062809'
  and a.deleted_at is null;

commit;

-- Verificación (columnas en UTC)
select
  a.booking_uid,
  a.status,
  a.status_type_id,
  a.starts_at,
  a.ends_at,
  a.starts_at as starts_at_utc_stored,
  a.ends_at as ends_at_utc_stored,
  a.starts_at at time zone 'America/Monterrey' as starts_at_hora_mx,
  a.ends_at at time zone 'America/Monterrey' as ends_at_hora_mx,
  a.starts_at - now() as falta_para_cita,
  a.metadata->>'reminder_4h_response' as reminder_4h_response,
  (select count(*) from appointment_reminder_dispatches d where d.appointment_id = a.id) as dispatches
from appointments a
where a.booking_uid = 'TEST-REMINDER-24H-5565062809';

-- select fn_dispatch_appointment_reminders('4h', 15);
-- select fn_cancel_no_response_3h_before_appointment(15);
