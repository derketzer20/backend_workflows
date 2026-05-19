-- =============================================================================
-- 024 — Respuesta BotSailor → Supabase (confirmar / cancelar tras recordatorio 4h)
-- =============================================================================
-- BotSailor/Make llama por HTTPS al RPC de PostgREST (no hace falta otro cron salvo
-- timeout opcional si el usuario no responde).
--
-- POST https://<PROJECT_REF>.supabase.co/rest/v1/rpc/fn_botsailor_reminder_response
-- Headers:
--   apikey: <SUPABASE_ANON_OR_SERVICE_KEY>
--   Authorization: Bearer <misma key o service_role>
--   Content-Type: application/json
-- Body ejemplo:
-- {
--   "p_webhook_secret": "<secreto en integration_webhook_config>",
--   "p_booking_uid": "TEST-REMINDER-24H-5565062809",
--   "p_action": "confirmed",
--   "p_tenant_id": "9e4860a5-d163-548d-8cb2-886f4d9e71f2",
--   "p_actor_ref": "5215565062809",
--   "p_payload": {}
-- }
-- p_action: confirmed | cancelled | no_response
--   confirmed    → status confirmed + evento reminder.confirmed
--   cancelled    → cancela cita (usuario dijo no)
--   no_response  → cancela cita (timeout BotSailor si no contestó)
-- =============================================================================

insert into integration_webhook_config (key, webhook_url)
values (
  'botsailor_inbound_secret',
  'CAMBIAR_POR_SECRETO_LARGO_ALEATORIO'
)
on conflict (key) do nothing;

-- ---------- Confirmar cita por booking_uid ----------

create or replace function fn_confirm_appointment_by_booking_uid(
  p_tenant_id uuid,
  p_booking_uid text,
  p_source text default 'whatsapp',
  p_actor_type text default 'patient',
  p_actor_ref text default null,
  p_external_event_id text default null,
  p_payload jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
set search_path = public
as $$
declare
  v_appointment_id uuid;
begin
  update appointments a
  set
    status = 'confirmed',
    status_type_id = 2,
    metadata = coalesce(a.metadata, '{}'::jsonb)
      || jsonb_build_object(
        'reminder_4h_confirmed_at', now(),
        'reminder_4h_response', 'confirmed'
      ),
    updated_at = now()
  where a.tenant_id = p_tenant_id
    and a.booking_uid = p_booking_uid
    and a.deleted_at is null
    and a.status in ('pending', 'confirmed', 'rescheduled')
  returning a.id into v_appointment_id;

  if v_appointment_id is null then
    return null;
  end if;

  insert into appointment_events (
    id, tenant_id, appointment_id, source, source_type_id,
    event_type, event_type_id, actor_type, actor_ref,
    external_ref, external_event_id, raw_payload
  ) values (
    gen_random_uuid(),
    p_tenant_id,
    v_appointment_id,
    p_source,
    1,
    'appointment.confirmed',
    2,
    p_actor_type,
    p_actor_ref,
    p_booking_uid,
    p_external_event_id,
    coalesce(p_payload, '{}'::jsonb)
      || jsonb_build_object('via', 'botsailor_reminder_4h')
  )
  on conflict do nothing;

  insert into appointment_events (
    id, tenant_id, appointment_id, source, source_type_id,
    event_type, event_type_id, actor_type, actor_ref,
    external_ref, raw_payload
  ) values (
    gen_random_uuid(),
    p_tenant_id,
    v_appointment_id,
    p_source,
    1,
    'reminder.confirmed',
    8,
    p_actor_type,
    p_actor_ref,
    'reminder-4h-confirmed:' || p_booking_uid,
    coalesce(p_payload, '{}'::jsonb)
  )
  on conflict do nothing;

  return v_appointment_id;
end;
$$;

-- ---------- Entrada única para BotSailor ----------

create or replace function fn_botsailor_reminder_response(
  p_webhook_secret text,
  p_booking_uid text,
  p_action text,
  p_tenant_id uuid default null,
  p_actor_ref text default null,
  p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_expected_secret text;
  v_tenant_id uuid;
  v_appointment_id uuid;
  v_action text;
begin
  select webhook_url into v_expected_secret
  from integration_webhook_config
  where key = 'botsailor_inbound_secret';

  if v_expected_secret is null
     or p_webhook_secret is null
     or p_webhook_secret <> v_expected_secret then
    raise exception 'webhook_secret invalid'
      using errcode = '28000';
  end if;

  v_action := lower(trim(coalesce(p_action, '')));
  if v_action not in ('confirmed', 'cancelled', 'no_response') then
    raise exception 'p_action debe ser confirmed, cancelled o no_response';
  end if;

  if p_tenant_id is not null then
    v_tenant_id := p_tenant_id;
  else
    select a.tenant_id into v_tenant_id
    from appointments a
    where a.booking_uid = p_booking_uid
      and a.deleted_at is null
    order by a.starts_at desc nulls last
    limit 1;
  end if;

  if v_tenant_id is null then
    return jsonb_build_object(
      'ok', false,
      'error', 'appointment_not_found',
      'booking_uid', p_booking_uid
    );
  end if;

  if v_action = 'confirmed' then
    v_appointment_id := fn_confirm_appointment_by_booking_uid(
      v_tenant_id,
      p_booking_uid,
      'whatsapp',
      'patient',
      p_actor_ref,
      null,
      p_payload
    );
    return jsonb_build_object(
      'ok', v_appointment_id is not null,
      'action', 'confirmed',
      'appointment_id', v_appointment_id,
      'booking_uid', p_booking_uid
    );
  end if;

  v_appointment_id := fn_cancel_appointment_by_booking_uid(
    v_tenant_id,
    p_booking_uid,
    case v_action
      when 'no_response' then 'Cancelada: sin confirmación recordatorio 4h'
      else 'Cancelada por paciente (recordatorio 4h)'
    end,
    'whatsapp',
    'patient',
    p_actor_ref,
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
    'booking_uid', p_booking_uid
  );
end;
$$;

comment on function fn_botsailor_reminder_response(text, text, text, uuid, text, jsonb) is
  'Webhook entrante BotSailor: confirmed | cancelled | no_response por booking_uid.';

revoke all on function fn_botsailor_reminder_response(text, text, text, uuid, text, jsonb)
  from public, anon, authenticated;

grant execute on function fn_botsailor_reminder_response(text, text, text, uuid, text, jsonb)
  to service_role;

-- Opcional: permitir anon si Make solo tiene anon key (menos seguro; preferir service_role):
-- grant execute on function fn_botsailor_reminder_response(...) to anon;

grant execute on function fn_confirm_appointment_by_booking_uid(uuid, text, text, text, text, text, jsonb)
  to service_role;
