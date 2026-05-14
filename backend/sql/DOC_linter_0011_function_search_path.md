# Resolver `function_search_path_mutable` (Supabase linter **0011**)

## Qué significa el warning

PostgreSQL permite que el **`search_path`** de una sesión redirija nombres no calificados (`appointments`, `now()`, etc.) a objetos de otro esquema. En funciones **sin** `SET search_path` fijo, un atacante con permiso para crear objetos en un esquema que entre antes en el path podría intentar **confundir** la resolución de nombres (clase de issues que el Advisor agrupa como *mutable search path*).

**Remediación recomendada por Supabase:** fijar el search path en la definición de la función, p. ej. `SET search_path = public` (o `pg_catalog, public` si necesitas solo catálogo + público).

Documentación: [Database linter 0011](https://supabase.com/docs/guides/database/database-linter?lint=0011_function_search_path_mutable)

---

## Qué se hizo en este repositorio

Se añadió **`set search_path = public`** inmediatamente después de `language plpgsql` / `language sql` (y después de `immutable` cuando aplica) en las definiciones `CREATE OR REPLACE FUNCTION` de:

| Archivo | Funciones tocadas |
|---------|-------------------|
| `002_omnichannel_model.sql` | `set_updated_at`, `normalize_phone_*`, todos los `tg_sync_*`, `tg_*_phone`, `fn_find_window_conflict_appointment`, `tg_enforce_duplicate_policy`, `fn_get_active_appointments_for_contact`, `fn_cancel_*`, `fn_reschedule_*`, `fn_find_duplicate_active_appointment` |
| `003_booking_validation_api.sql` | Todas las `fn_*` en SQL |
| `004_patient_appointment_cache.sql` | `fn_recompute_*`, `tg_appointments_refresh_patient_cache` |
| `005_regularize_patient_appointment_cache.sql` | Igual que 004 |
| `007_fix_has_active_proxima_cita.sql` | Igual que 004 |
| `008_specialist_codes_fk.sql` | `tg_specialists_link_specialist_code` |
| `009_appointment_actor_fks_and_mock.sql` | `_009_add_fk_if_missing` |

`014_rls_policies_tenant_scoped.sql` ya definía `jwt_tenant_id()` con `set search_path = public`.

---

## Qué debes ejecutar en Supabase

### Opción C — Un solo script (bases ya desplegadas)

Ejecuta **`backend/sql/015_regularize_function_search_path.sql`** en el SQL Editor.

Recorre `pg_proc` en `public` para los nombres de función del proyecto y aplica **`ALTER FUNCTION … SET search_path = public`**. Si una función no existe, no hace nada para ese nombre. Es **idempotente**.

Si creaste funciones extra (otro `proname`), añade el nombre al **array** `v_names` dentro del bloque `DO`.

### Opción A — Reaplicar migraciones con `CREATE OR REPLACE`

Vuelve a aplicar los scripts del repo que definan esas funciones (al menos **`002`**, y los demás que uses: **`003`**, **`004`/`005`/`007`**, **`008`**, **`009`**), en el orden habitual de migraciones, para que el cuerpo de la función en disco y el `SET` queden alineados con el repo.

### Opción B — Parches manuales

Copiar solo bloques `CREATE OR REPLACE FUNCTION` desde los archivos del repo.

**Nota:** **015** solo cambia el atributo `search_path` de la función; **no** sustituye el cuerpo SQL/PLpgSQL. Para cambios de lógica sigue haciendo falta reaplicar el `CREATE OR REPLACE` del archivo de migración correspondiente.

---

## Trazabilidad

| Campo | Valor |
|-------|--------|
| **Lint** | `function_search_path_mutable` (WARN, categoría SECURITY) |
| **Criterio de éxito** | El Advisor deja de listar esas funciones en **0011** tras desplegar las definiciones con `set search_path = public`. |
| **Alternativa estricta** | `SET search_path = ''` y calificar todo como `public.tabla` (más verboso; no usado aquí). |

---

## Historial

- Alineación de funciones del esquema de citas / omnicanal con **`set search_path = public`** en los `.sql` del directorio `backend/sql` para cumplir el linter **0011** y reducir riesgo de *search_path hijacking*.
- Script agregado **`015_regularize_function_search_path.sql`**: regularización masiva vía `ALTER FUNCTION … SET search_path = public` sobre bases ya existentes sin re-ejecutar migraciones enteras.
