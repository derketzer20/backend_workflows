-- =============================================================================
-- 023 — Webhook y body BotSailor para recordatorios (24h / 4h)
-- =============================================================================
-- Body BotSailor:
--   24h → numero, nombre, booking_id, fecha (DD/MM/YYYY), hora (HH24:MI)
--   4h  → numero (521 + 10 dígitos), hora (hh:mm AM, America/Monterrey)
--
-- Actualiza solo la URL 4h en integration_webhook_config si cambia el webhook.
-- =============================================================================

insert into integration_webhook_config (key, webhook_url)
values
  (
    'botsailor_reminder_24h',
    'https://app.e-smart360.com/webhook/whatsapp-workflow/264200.354365.347030.1775333094'
  ),
  (
    'botsailor_reminder_4h',
    'https://app.e-smart360.com/webhook/whatsapp-workflow/264200.354365.364780.1777503176'
  )
on conflict (key) do update set
  webhook_url = excluded.webhook_url,
  updated_at = now();

create or replace function fn_dispatch_appointment_reminders(
  p_reminder_kind text,
  p_window_minutes int default 15
)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_target interval;
  v_from timestamptz;
  v_window_to timestamptz;
  v_count int := 0;
  r record;
  v_body jsonb;
  v_botsailor_url text;
  v_config_key text;
  v_numero text;
  v_starts_local timestamp;
begin
  if p_reminder_kind = '24h' then
    v_target := interval '24 hours';
    v_config_key := 'botsailor_reminder_24h';
  elsif p_reminder_kind = '4h' then
    v_target := interval '4 hours';
    v_config_key := 'botsailor_reminder_4h';
  else
    raise exception 'reminder_kind debe ser 24h o 4h';
  end if;

  select webhook_url into v_botsailor_url
  from integration_webhook_config
  where key = v_config_key;

  if v_botsailor_url is null or btrim(v_botsailor_url) = '' then
    select webhook_url into v_botsailor_url
    from integration_webhook_config
    where key = 'botsailor_appointment_reminders';
  end if;

  if v_botsailor_url is null or btrim(v_botsailor_url) = '' then
    raise exception 'Falta webhook_url para % en integration_webhook_config', v_config_key;
  end if;

  v_from := now() + v_target - make_interval(mins => p_window_minutes);
  v_window_to := now() + v_target + make_interval(mins => p_window_minutes);

  for r in
    select
      a.id as appointment_id,
      a.tenant_id,
      a.booking_uid,
      a.starts_at,
      c.phone_e164,
      c.phone_digits,
      c.wa_id,
      coalesce(nullif(trim(p.full_name), ''), 'Paciente') as patient_name
    from appointments a
    join patients p on p.id = a.patient_id and p.tenant_id = a.tenant_id and p.deleted_at is null
    left join contacts c on c.id = p.contact_id and c.tenant_id = a.tenant_id and c.deleted_at is null
    where a.deleted_at is null
      and a.starts_at is not null
      and a.starts_at between v_from and v_window_to
      and a.status in ('pending', 'confirmed', 'rescheduled')
      and a.booking_uid is not null
      and not exists (
        select 1 from appointment_reminder_dispatches d
        where d.appointment_id = a.id and d.reminder_kind = p_reminder_kind
      )
      and coalesce(c.wa_id, c.phone_e164, c.phone_digits) is not null
  loop
    v_numero := normalize_wa_id_mx(coalesce(r.wa_id, r.phone_e164, r.phone_digits));
    if v_numero is null then
      continue;
    end if;

    v_starts_local := r.starts_at at time zone 'America/Monterrey';

    if p_reminder_kind = '4h' then
      v_body := jsonb_build_object(
        'numero', v_numero,
        'hora', trim(to_char(v_starts_local, 'HH12:MI AM'))
      );
    else
      v_body := jsonb_build_object(
        'numero', v_numero,
        'nombre', r.patient_name,
        'booking_id', r.booking_uid,
        'fecha', to_char(v_starts_local, 'DD/MM/YYYY'),
        'hora', to_char(v_starts_local, 'HH24:MI')
      );
    end if;

    perform net.http_post(
      url := v_botsailor_url,
      headers := jsonb_build_object('Content-Type', 'application/json'),
      body := v_body
    );

    insert into appointment_reminder_dispatches (tenant_id, appointment_id, reminder_kind)
    values (r.tenant_id, r.appointment_id, p_reminder_kind);

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

comment on function fn_dispatch_appointment_reminders(text, int) is
  '24h: numero,nombre,booking_id,fecha,hora. 4h: solo numero (521...) y hora (HH12:MI AM Monterrey).';

-- Ver URLs:
-- select key, webhook_url from integration_webhook_config where key like 'botsailor_reminder%';

-- Prueba 4h:
-- delete from appointment_reminder_dispatches where appointment_id = '<uuid>' and reminder_kind = '4h';
-- update appointments set starts_at = now() + interval '4 hours', ends_at = now() + interval '4 hours 30 minutes' where booking_uid = '...';
-- select fn_dispatch_appointment_reminders('4h', 15);
-- Body esperado: {"numero":"5215565062809","hora":"02:00 PM"}
