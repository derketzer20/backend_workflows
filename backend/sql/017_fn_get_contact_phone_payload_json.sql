-- =============================================================================
-- 017 — JSON de contacto por teléfono (Make / RPC / integraciones)
-- =============================================================================
-- Devuelve un objeto con la clave "contacto" y los campos canónicos guardados
-- en la tabla contacts (misma resolución que fn_resolve_contact_id_by_phone_digits).
--
-- Entrada: dígitos MX (10) u otros formatos que normalice normalize_phone_digits().
-- Si no hay fila: {"contacto": null}
--
-- PostgREST / Make RPC:
--   POST /rest/v1/rpc/fn_get_contact_phone_payload_json
--   Body: {"p_tenant_id": "...", "p_phone_digits": "8120971098"}
--
-- Permisos: otorgar EXECUTE solo a los roles que correspondan (p. ej. service_role).
-- =============================================================================

create or replace function fn_get_contact_phone_payload_json(
  p_tenant_id uuid,
  p_phone_digits text
)
returns jsonb
language sql
stable
set search_path = public
as $$
  select coalesce(
    (
      select jsonb_build_object(
        'contacto',
        jsonb_build_object(
          'id', c.id,
          'phone_digits', c.phone_digits,
          'phone_e164', c.phone_e164,
          'wa_id', c.wa_id,
          'channel_primary', c.channel_primary
        )
      )
      from contacts c
      where c.tenant_id = p_tenant_id
        and c.deleted_at is null
        and normalize_phone_digits(p_phone_digits) is not null
        and c.phone_digits = normalize_phone_digits(p_phone_digits)
      order by c.last_seen_at desc nulls last
      limit 1
    ),
    '{"contacto":null}'::jsonb
  );
$$;

comment on function fn_get_contact_phone_payload_json(uuid, text) is
  'Snapshot mínimo del contacto por tenant + phone_digits normalizado; Make/RPC.';
