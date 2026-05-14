-- =============================================================================
-- 012 — Restringir RPC public.rls_auto_enable() (Supabase Advisor)
-- =============================================================================
-- Problema: SECURITY DEFINER + EXECUTE para rol `anon` expone la función en
--   PostgREST: POST /rest/v1/rpc/rls_auto_enable sin sesión.
-- Solución habitual: REVOKE a anon/authenticated/PUBLIC y dejar solo
--   service_role (o postgres) si aún la necesitas desde el dashboard o jobs.
--
-- Si la firma no es exactamente rls_auto_enable() sin argumentos, en SQL
-- Editor ejecuta antes:
--   select p.oid::regprocedure
--   from pg_proc p
--   join pg_namespace n on n.oid = p.pronamespace
--   where n.nspname = 'public' and p.proname = 'rls_auto_enable';
-- y sustituye el nombre que devuelva (ej. public.rls_auto_enable(uuid)).
-- =============================================================================

-- Quitar acceso público y de clientes JWT habituales
revoke execute on function public.rls_auto_enable() from public;
revoke execute on function public.rls_auto_enable() from anon;
revoke execute on function public.rls_auto_enable() from authenticated;

-- Opcional: solo el servicio backend / service_role puede invocarla
grant execute on function public.rls_auto_enable() to service_role;

-- Si NADIE debe llamarla por API (solo tú a mano como superuser en SQL Editor),
-- comenta la línea GRANT de arriba y deja solo los REVOKE.

-- ---------- Alternativas (elige según tu caso) ----------
--
-- A) Ya no la usas: en SQL Editor
--    drop function if exists public.rls_auto_enable();
--
-- B) Debe correr con permisos del llamador (sin elevar privilegios):
--    alter function public.rls_auto_enable() security invoker;
--    (Solo si el cuerpo de la función no requiere ser "dueño" para tocar RLS.)
--
-- C) Mover fuera de la API: crear esquema internal sin exponer en PostgREST
--    y recrear la función ahí (avanzado; requiere configuración de API schemas).
