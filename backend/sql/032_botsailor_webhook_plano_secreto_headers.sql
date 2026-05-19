-- =============================================================================
-- 032 — Misma lógica que 031, body PLANO para BotSailor + secreto en body
-- =============================================================================
-- El error "No API key found in request" NO es el secreto del webhook: faltan
-- headers de Supabase (apikey + Authorization). Ver abajo.
--
-- Secreto (una vez en BD):
--   insert into integration_webhook_config (key, webhook_url)
--   values ('botsailor_inbound_secret', 'TU_SECRETO_LARGO')
--   on conflict (key) do update set webhook_url = excluded.webhook_url, updated_at = now();
--
-- POST https://<PROJECT>.supabase.co/rest/v1/rpc/fn_botsailor_appointment_response
-- Headers (obligatorios):
--   Content-Type: application/json
--   apikey: <SUPABASE_SERVICE_ROLE_KEY>
--   Authorization: Bearer <SUPABASE_SERVICE_ROLE_KEY>
--
-- Body plano (confirmar):
-- {
--   "p_webhook_secret": "TU_SECRETO_LARGO",
--   "p_numero": "5215548649518",
--   "p_tenant_id": "9e4860a5-d163-548d-8cb2-886f4d9e71f2",
--   "p_specialist_code": "dr_juan",
--   "p_status": "confirmado"
-- }
--
-- Body plano (cancelar): mismo con "p_status": "cancelado"
-- =============================================================================

insert into integration_webhook_config (key, webhook_url)
values ('botsailor_inbound_secret', 'CAMBIAR_POR_SECRETO_LARGO_ALEATORIO')
on conflict (key) do nothing;

create or replace function fn_botsailor_appointment_response(
  p_webhook_secret text,
  p_numero text,
  p_tenant_id uuid,
  p_specialist_code text,
  p_status text,
  p_specialist_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_expected_secret text;
  v_item jsonb;
begin
  select c.webhook_url
  into v_expected_secret
  from integration_webhook_config c
  where c.key = 'botsailor_inbound_secret';

  if v_expected_secret is null
     or btrim(coalesce(p_webhook_secret, '')) = ''
     or p_webhook_secret <> v_expected_secret then
    return jsonb_build_object('ok', false, 'error', 'webhook_secret_invalid');
  end if;

  v_item := jsonb_strip_nulls(
    jsonb_build_object(
      'numero', p_numero,
      'tenant_id', p_tenant_id,
      'specialist_code', nullif(btrim(p_specialist_code), ''),
      'specialist_id', p_specialist_id,
      'status', p_status
    )
  );

  return fn_botsailor_appointment_response(jsonb_build_array(v_item));
end;
$$;

comment on function fn_botsailor_appointment_response(text, text, uuid, text, text, uuid) is
  'BotSailor: body plano + p_webhook_secret. Requiere headers apikey y Authorization (service_role).';

revoke all on function fn_botsailor_appointment_response(text, text, uuid, text, text, uuid)
  from public, anon, authenticated;
grant execute on function fn_botsailor_appointment_response(text, text, uuid, text, text, uuid)
  to service_role;
