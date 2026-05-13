-- =============================================================================
-- 006 — Normalizar starts_at / ends_at en appointments (datos, no reglas)
-- =============================================================================
-- Objetivo: que cada cita tenga intervalo válido (starts < ends) y ends_at
-- definido cuando falta o es inconsistente. Duración por defecto: 30 minutos
-- (misma convención que el seed CRM / generate_seed_from_crm_xlsx.py).
--
-- Tras el UPDATE, el trigger en appointments recalcula el cache en patients.
--
-- Uso:
--   1) Ejecuta en queries_verify la auditoría 0.7 / 0.8 (ver starts_at, ends_at).
--   2) Ajusta el filtro opcional de tenant abajo si no quieres toda la BD.
--   3) Ejecuta este archivo una vez; es idempotente para filas ya correctas.
-- =============================================================================

-- Opcional: limitar a un tenant (descomenta y ajusta el UUID).
-- Se aplica en los tres pasos siguientes sustituyendo el comentario por AND.

-- -----------------------------------------------------------------------------
-- A) Vista previa: filas que se van a tocar (misma condición que el UPDATE)
-- -----------------------------------------------------------------------------
select
  a.id,
  a.tenant_id,
  a.patient_id,
  a.status,
  a.starts_at,
  a.ends_at,
  round(
    case
      when a.ends_at is not null and a.starts_at is not null
      then extract(epoch from (a.ends_at - a.starts_at)) / 60.0
    end,
    1
  ) as duracion_min_actual
from appointments a
where a.deleted_at is null
  and a.starts_at is not null
  and (
    a.ends_at is null
    or a.ends_at <= a.starts_at
  );
-- Filtro opcional (mismo WHERE): añade en la línea anterior, antes del `;`:
--   and a.tenant_id = '9e4860a5-d163-548d-8cb2-886f4d9e71f2'::uuid

-- -----------------------------------------------------------------------------
-- B) Normalizar: ends_at = starts_at + 30 min cuando falta o es inválido
-- -----------------------------------------------------------------------------
do $$
declare
  n int;
begin
  update appointments a
  set
    ends_at = a.starts_at + interval '30 minutes',
    updated_at = now()
  where a.deleted_at is null
    and a.starts_at is not null
    and (
      a.ends_at is null
      or a.ends_at <= a.starts_at
    );
  -- Opcional: misma condición + and a.tenant_id = '...'::uuid

  get diagnostics n = row_count;
  raise notice '006_normalize: appointments actualizados (ends_at corregido): %', n;
end;
$$;

-- -----------------------------------------------------------------------------
-- C) Recalcular cache de pacientes afectados (por si algún entorno no dispara trigger)
-- -----------------------------------------------------------------------------
do $$
declare
  r record;
  m int := 0;
begin
  for r in
    select distinct p.id
    from patients p
    join appointments a on a.patient_id = p.id and a.deleted_at is null
    where p.deleted_at is null
  loop
    perform fn_recompute_patient_appointment_cache(r.id);
    m := m + 1;
  end loop;
  raise notice '006_normalize: cache recalculado para % pacientes con citas', m;
end;
$$;
