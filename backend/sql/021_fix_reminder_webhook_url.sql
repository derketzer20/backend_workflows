-- =============================================================================
-- 021 — URL webhook BotSailor + fn_dispatch sin token (arregla url NULL en pg_net)
-- =============================================================================

create table if not exists integration_webhook_config (
  key text primary key,
  webhook_url text not null,
  updated_at timestamptz not null default now()
);

alter table integration_webhook_config enable row level security;
revoke all on integration_webhook_config from anon, authenticated;

insert into integration_webhook_config (key, webhook_url)
values (
  'botsailor_appointment_reminders',
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
  v_wa_to text;
begin
  if p_reminder_kind = '24h' then
    v_target := interval '24 hours';
  elsif p_reminder_kind = '4h' then
    v_target := interval '4 hours';
  else
    raise exception 'reminder_kind debe ser 24h o 4h';
  end if;

  select webhook_url into v_botsailor_url
  from integration_webhook_config
  where key = 'botsailor_appointment_reminders';

  if v_botsailor_url is null or btrim(v_botsailor_url) = '' then
    raise exception 'Falta webhook_url en integration_webhook_config (key=botsailor_appointment_reminders)';
  end if;

  v_from := now() + v_target - make_interval(mins => p_window_minutes);
  v_window_to := now() + v_target + make_interval(mins => p_window_minutes);

  for r in
    select
      a.id as appointment_id,
      a.tenant_id,
      a.booking_uid,
      a.starts_at,
      a.ends_at,
      a.status,
      c.phone_e164,
      c.phone_digits,
      c.wa_id,
      p.full_name as patient_name,
      s.display_name as specialist_name
    from appointments a
    join patients p on p.id = a.patient_id and p.tenant_id = a.tenant_id and p.deleted_at is null
    left join contacts c on c.id = p.contact_id and c.tenant_id = a.tenant_id and c.deleted_at is null
    left join specialists s on s.id = a.specialist_id and s.tenant_id = a.tenant_id
    where a.deleted_at is null
      and a.starts_at between v_from and v_window_to
      and a.status in ('pending', 'confirmed', 'rescheduled')
      and not exists (
        select 1 from appointment_reminder_dispatches d
        where d.appointment_id = a.id and d.reminder_kind = p_reminder_kind
      )
      and coalesce(c.phone_e164, c.wa_id, c.phone_digits) is not null
  loop
    -- Meta WhatsApp Cloud API (MX): "to" = 521 + 10 dígitos locales (ej. 5215565062809)
    v_wa_to := regexp_replace(coalesce(r.wa_id, r.phone_e164, r.phone_digits, ''), '[^0-9]', '', 'g');
    if length(v_wa_to) > 10 then
      v_wa_to := right(v_wa_to, 10);
    end if;
    if length(v_wa_to) = 10 then
      v_wa_to := '521' || v_wa_to;
    end if;
    if length(v_wa_to) <> 13 or v_wa_to not like '521%' then
      continue;
    end if;

    v_body := jsonb_build_object(
      'to', v_wa_to,
      'reminder_kind', p_reminder_kind,
      'tenant_id', r.tenant_id,
      'appointment_id', r.appointment_id,
      'booking_uid', r.booking_uid,
      'starts_at', r.starts_at,
      'phone_e164', r.phone_e164,
      'phone_digits', r.phone_digits,
      'wa_id', v_wa_to,
      'patient_name', r.patient_name,
      'specialist_name', r.specialist_name
    );

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

-- Verificar URL cargada:
-- select key, webhook_url from integration_webhook_config;
