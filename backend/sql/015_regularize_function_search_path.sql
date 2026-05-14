-- =============================================================================
-- 015 — Regularizar search_path en funciones públicas (Supabase lint 0011)
-- =============================================================================
-- Objetivo: en bases ya desplegadas, fijar SET search_path = public sin volver
--   a ejecutar enteros 002/003/004… (útil si solo quieres alinear el Advisor).
--
-- Cómo funciona: para cada función existente en schema public cuyo nombre está
--   en la lista, ejecuta ALTER FUNCTION ... SET search_path = public.
-- Si una función no existe, se omite (no está en pg_proc).
--
-- No incluye funciones que no estén en la lista (ej. utilidades sueltas creadas
--   a mano: añade el proname al ARRAY si aplica).
--
-- Idempotente: repetir el script es seguro.
-- =============================================================================

do $$
declare
  r record;
  n int := 0;
  v_names text[] := array[
    'set_updated_at',
    'normalize_phone_e164',
    'normalize_phone_digits',
    'tg_sync_appointment_types',
    'tg_sync_contact_patient_link_types',
    'tg_sync_specialist_policy_types',
    'tg_sync_channel_message_types',
    'tg_sync_appointment_event_types',
    'tg_sync_contacts_phone',
    'tg_sync_patients_phone',
    'fn_find_window_conflict_appointment',
    'tg_enforce_duplicate_policy',
    'fn_get_active_appointments_for_contact',
    'fn_cancel_appointment_by_booking_uid',
    'fn_reschedule_appointment_by_booking_uid',
    'fn_find_duplicate_active_appointment',
    'fn_resolve_contact_id_by_phone_digits',
    'fn_contact_has_linked_patients',
    'fn_patient_belongs_to_contact',
    'fn_get_booking_snapshot',
    'fn_booking_matches_specialist_code',
    'fn_precheck_new_appointment',
    'fn_recompute_patient_appointment_cache',
    'tg_appointments_refresh_patient_cache',
    'tg_specialists_link_specialist_code',
    'jwt_tenant_id',
    '_009_add_fk_if_missing'
  ];
begin
  for r in
    select p.oid::regprocedure as fn
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = any (v_names)
  loop
    execute format('alter function %s set search_path = public', r.fn);
    n := n + 1;
  end loop;
  raise notice '015_regularize_function_search_path: alteradas % función(es)', n;
end;
$$;
