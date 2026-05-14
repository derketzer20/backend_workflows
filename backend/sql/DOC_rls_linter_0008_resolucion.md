# Resolver `rls_enabled_no_policy` (Supabase linter 0008)

**Qué significa:** en esa tabla tienes `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` pero **no hay ninguna política** `CREATE POLICY`. Con RLS activo y cero políticas, los roles que no bypassan RLS **no ven ni modifican filas**; el Advisor avisa para que definas políticas explícitas (o desactives RLS, no recomendado).

**Nivel INFO:** no bloquea despliegue; es higiene de seguridad.

---

## Qué ejecutar (orden recomendado)

| Paso | Archivo | Cuándo usarlo |
|------|---------|----------------|
| 1 | `backend/sql/013_rls_policies_global_catalogs.sql` | Siempre que tengas las tablas de **catálogo** `*_types` / `actor_types` / `appointment_event_types` con RLS y sin políticas. |
| 2 | `backend/sql/014_rls_policies_tenant_scoped.sql` | Cuando tengas tablas con **`tenant_id`** y quieras que usuarios **authenticated** vean solo su tenant vía JWT. Requiere columna `tenant_id` (y que existan tablas como `specialist_codes` si incluye esas políticas — aplica después del script `008` si usas esa tabla). |

En **Supabase → SQL Editor**: pega y ejecuta **013** completo; luego **014** completo (o revisa primero los requisitos de JWT abajo).

**Service role / Make:** la clave `service_role` **bypassa RLS** en Supabase; tus automatizaciones con service key **no dependen** de estas políticas para seguir funcionando.

---

## Tabla: cada entidad del Advisor → script → qué se crea

| Tabla (entity) | Script | Qué hace la política |
|----------------|--------|----------------------|
| `actor_types` | **013** | `FOR SELECT TO anon, authenticated USING (true)` — lectura del catálogo. |
| `appointment_event_types` | **013** | Igual: solo lectura pública de referencia. |
| `appointment_source_types` | **013** | Igual. |
| `appointment_status_types` | **013** | Igual. |
| `appointment_types` | **013** | Igual. |
| `message_direction_types` | **013** | Igual. |
| `policy_scope_types` | **013** | Igual. |
| `policy_window_types` | **013** | Igual. |
| `relationship_types` | **013** | Igual. |
| `tenants` | **014** | `SELECT` solo si `tenants.id = jwt_tenant_id()` (una fila, “mi tenant”). |
| `specialists` | **014** | `SELECT/INSERT/UPDATE/DELETE` para `authenticated` con `tenant_id = jwt_tenant_id()`. |
| `contacts` | **014** | Igual, por `tenant_id`. |
| `patients` | **014** | Igual. |
| `appointments` | **014** | Igual. |
| `appointment_events` | **014** | Igual. |
| `channel_messages` | **014** | Igual. |
| `contact_patient_links` | **014** | Igual. |
| `locations` | **014** | Igual. |
| `specialist_codes` | **014** | Igual (tabla del script **008**). |
| `specialist_duplicate_policies` | **014** | Igual. |
| `bot_sessions` | **014** | Igual. |

---

## Requisito para **014** (JWT)

La función `public.jwt_tenant_id()` lee:

- `auth.jwt() -> 'app_metadata' ->> 'tenant_id'`, o si falta  
- `auth.jwt() -> 'user_metadata' ->> 'tenant_id'`

Debe ser un **UUID válido** en texto. Si no está en el JWT, `jwt_tenant_id()` es `NULL` y **no habrá filas** visibles para ese usuario en tablas tenant (comportamiento seguro).

Opciones para poblar el claim:

- **Custom Access Token Hook** (Supabase Auth), o  
- Al crear/registrar usuario, escribir `app_metadata.tenant_id` desde el panel o API de admin.

Si tu modelo **no** usa `tenant_id` en el JWT (por ejemplo solo `auth.uid()` y una tabla `memberships`), hay que **sustituir** las expresiones `tenant_id = public.jwt_tenant_id()` por la lógica que corresponda (join a `user_tenant` o similar); el archivo **014** entonces sirve como plantilla.

---

## Ajustes opcionales

| Necesidad | Qué cambiar |
|-----------|-------------|
| No quieres que `anon` lea catálogos | En **013**, en cada política quita `anon` y deja solo `authenticated`. |
| Cliente móvil solo lectura | En **014**, elimina políticas `INSERT`/`UPDATE`/`DELETE` de las tablas que no deban mutarse desde el cliente. |
| No existe `specialist_codes` aún | Comenta o borra el bloque `specialist_codes` en **014** hasta migrar **008**. |
| Desactivar RLS en catálogo (no recomendado) | `ALTER TABLE ... DISABLE ROW LEVEL SECURITY` — quita el INFO pero pierdes capa RLS en esa tabla. |

---

## Referencia

- [Supabase: Database linter 0008](https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy)
