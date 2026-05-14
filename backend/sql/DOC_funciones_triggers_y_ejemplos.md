# Funciones y triggers en `backend/sql`

Documento para compartir: inventario de objetos PostgreSQL y ejemplos **antes / después** de filas cuando aplican triggers o funciones.

> **Nota:** En migraciones `004`, `005` y `007` se redefine la misma función/trigger de cache de paciente; la semántica descrita es la versión consolidada (próxima cita + `has_active_appointment`).

---

## 1. Momento de ejecución: ¿una vez, en bucle o con cron?

### 1.1. Idea clave

- **Los triggers no son un demonio ni un job periódico.** Vivieron en el catálogo de PostgreSQL **después de aplicar las migraciones**, pero **cada ejecución** ocurre solo cuando una sentencia SQL cumple el evento del trigger (`INSERT` / `UPDATE` / `DELETE` en la tabla y columnas indicadas). Corre **una vez por fila afectada** (`FOR EACH ROW`), **dentro de la misma transacción** que el cambio, de forma **síncrona**.
- **No hace falta un cron** para que la normalización de teléfono, la sincronía texto↔ID, el `updated_at` o el cache de paciente “se mantengan”: eso ya lo hace el trigger **en cada cambio** que dispare.
- **Las funciones “de negocio”** (`fn_precheck_new_appointment`, `fn_cancel_appointment_by_booking_uid`, consultas de `003`, etc.) **solo se ejecutan cuando algo las invoca** (API/Make, `SELECT`/`CALL` desde SQL, RPC de Supabase). No tienen calendario propio.
- **`fn_recompute_patient_appointment_cache`**:
  - Se llama **desde el trigger** `trg_appointments_refresh_patient_cache` **cada vez** que una cita insertada/actualizada/borrada afecta columnas vigiladas → **un recomputo por paciente tocado en esa operación** (no “una sola vez en la vida de la base”).
  - El **backfill** de los scripts `004`/`005`/`007` (bucle `DO` al final) corre **solo cuando ejecutas ese archivo SQL**.
- **Migración puntual:** `_009_add_fk_if_missing` se usa **solo al ejecutar** `009_...sql`; al terminar el script se hace `DROP` de esa función.

### 1.2. Tabla resumen: qué lo dispara y “cada cuánto”

| Objeto | ¿Cuándo corre? | Periodicidad |
|--------|----------------|--------------|
| Triggers `trg_*_sync_*`, teléfono, `set_updated_at` | En cada `INSERT`/`UPDATE` que cumpla la definición del trigger | **Por evento de escritura** (0 veces si nadie toca la tabla) |
| `trg_appointments_enforce_duplicate_policy` | Antes de insertar/actualizar citas en columnas vigiladas | **Por evento** que intente dejar la cita “activa” en conflicto con política |
| `trg_appointments_refresh_patient_cache` | Después de insert/update/delete en `appointments` en columnas vigiladas | **Por evento**; puede llamar `fn_recompute` 1 o 2 veces si cambia `patient_id` |
| `fn_find_window_conflict_appointment` / `fn_find_duplicate_active_appointment` | Cuando otra función o trigger las invoca, o un `SELECT` explícito | **Por llamada** |
| `fn_precheck_new_appointment`, funciones de `003` | Solo si el cliente/Make/backend las ejecuta | **Por llamada** |
| `fn_cancel_*` / `fn_reschedule_*` | Solo si se llaman explícitamente | **Por llamada** |
| Definiciones `CREATE OR REPLACE` en migraciones | Al aplicar el `.sql` | **Una vez por despliegue de ese script** |
| Backfill al final de `004`/`005`/`007` | Al ejecutar ese script | **Una vez por ejecución del script** |

### 1.3. ¿Hace falta cron?

**En operación normal, no** para sustituir a los triggers.

**Opcional (reconciliación / red de seguridad):** si hubo cargas masivas con triggers deshabilitados, restauración desde backup, bugs o escrituras fuera de la app, puedes **programar un job** que vuelva a ejecutar `fn_recompute_patient_appointment_cache` para todos los pacientes (o un subconjunto). Eso **no sustituye** al trigger; solo corrige posible desfase.

**Opcional (solo pasa el tiempo):** el cache en `patients` usa `now()` **en el instante del recomputo**. Si una cita deja de estar “vigente” porque llegó su `ends_at` o porque el reloj superó `starts_at` pero **nadie modifica** filas en `appointments`, el trigger **no** se dispara: columnas como `active_appointment_count` o `next_appointment_starts_at` pueden quedar desactualizadas hasta el próximo cambio en citas. Si los dashboards exigen precisión al minuto sin escrituras, conviene un **cron de baja frecuencia** (p. ej. cada hora o cada noche) con el `DO` de la sección 1.4, o acotar a pacientes con citas “hoy”.

### 1.4. Ejemplo: recomputar cache de todos los pacientes (manual o desde cron)

Ejecutar en horario de baja carga; en bases grandes conviene paginar o filtrar por `tenant_id`.

```sql
-- Recomputo masivo (ejemplo; ajustar filtro si aplica)
DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT id FROM patients WHERE deleted_at IS NULL
  LOOP
    PERFORM fn_recompute_patient_appointment_cache(r.id);
  END LOOP;
END;
$$;
```

### 1.5. Supabase: `pg_cron` (si está habilitado)

En el panel: **Database → Extensions → pg_cron**. Luego en SQL (ejemplo **cada día a las 03:15** hora del servidor; revisar zona horaria del proyecto):

```sql
-- Requiere extensión pg_cron y permisos adecuados
select cron.schedule(
  'recompute-patient-appointment-cache-nightly',
  '15 3 * * *',
  $$
  do $body$
  declare r record;
  begin
    for r in select id from patients where deleted_at is null
    loop
      perform fn_recompute_patient_appointment_cache(r.id);
    end loop;
  end;
  $body$;
  $$
);
```

Para **quitar** el job: `select cron.unschedule('recompute-patient-appointment-cache-nightly');`

Sustituye la expresión cron si quieres otra periodicidad, por ejemplo **`0 * * * *`** = una vez por hora al minuto 0; **`*/15 * * * *`** = cada 15 minutos (más carga en bases grandes).

### 1.6. PostgreSQL propio / VPS: `crontab` + `psql`

Archivo `recompute_cache.sql` con el mismo `DO ...` de arriba. Crontab (ejemplo diario a las 3:15):

```cron
15 3 * * * psql "postgresql://USER:PASS@HOST:5432/DBNAME" -f /ruta/recompute_cache.sql >> /var/log/recompute_cache.log 2>&1
```

Usar secretos por variables de entorno o `.pgpass`, no credenciales en claro en producción.

---

## 2. Inventario por archivo

### `002_omnichannel_model.sql`

#### Funciones

| Nombre | Rol |
|--------|-----|
| `set_updated_at()` | Trigger: asigna `updated_at := now()` en `UPDATE`. |
| `normalize_phone_e164(raw_phone)` | Devuelve teléfono en estilo E.164 (heurística MX: +52, 521, etc.). |
| `normalize_phone_digits(raw_phone)` | Solo dígitos, reducidos a 10 dígitos “locales” MX. |
| `tg_sync_appointment_types()` | Sincroniza en `appointments`: `source` ↔ `source_type_id`, `status` ↔ `status_type_id`; default `appointment_type_id = 1`. |
| `tg_sync_contact_patient_link_types()` | Sincroniza vínculo contacto–paciente con catálogo `relationship_types`. |
| `tg_sync_specialist_policy_types()` | Sincroniza políticas de duplicados: scope y ventana con IDs. |
| `tg_sync_channel_message_types()` | Sincroniza `channel_messages`: fuente y dirección con IDs. |
| `tg_sync_appointment_event_types()` | Sincroniza eventos de cita con catálogos; default `event_type_id = 10` si falta. |
| `tg_sync_contacts_phone()` | Normaliza `phone_e164` y `phone_digits` en `contacts` (usa `wa_id` si falta E.164). |
| `tg_sync_patients_phone()` | Normaliza teléfono en `patients`. |
| `fn_find_window_conflict_appointment(...)` | Devuelve `id` de cita en conflicto según `specialist_duplicate_policies` (ventana, alcance, fuentes). |
| `tg_enforce_duplicate_policy()` | Antes de guardar cita activa: si hay conflicto de ventana, lanza excepción. |
| `fn_get_active_appointments_for_contact(...)` | Lista citas activas de todos los pacientes ligados al contacto. |
| `fn_cancel_appointment_by_booking_uid(...)` | Cancela por `booking_uid` e inserta evento `appointment.cancelled`. |
| `fn_reschedule_appointment_by_booking_uid(...)` | Reagenda por `booking_uid` e inserta evento `appointment.rescheduled`. |
| `fn_find_duplicate_active_appointment(...)` | Misma cita exacta (mismo `starts_at`, mismo paciente/especialista, activa). |

#### Triggers

| Trigger | Tabla | Función |
|---------|--------|---------|
| `trg_sync_appointment_types` | `appointments` | `tg_sync_appointment_types` |
| `trg_sync_contact_patient_link_types` | `contact_patient_links` | `tg_sync_contact_patient_link_types` |
| `trg_sync_specialist_policy_types` | `specialist_duplicate_policies` | `tg_sync_specialist_policy_types` |
| `trg_sync_channel_message_types` | `channel_messages` | `tg_sync_channel_message_types` |
| `trg_sync_appointment_event_types` | `appointment_events` | `tg_sync_appointment_event_types` |
| `trg_contacts_sync_phone` | `contacts` | `tg_sync_contacts_phone` |
| `trg_patients_sync_phone` | `patients` | `tg_sync_patients_phone` |
| `trg_locations_updated_at` | `locations` | `set_updated_at` |
| `trg_specialists_updated_at` | `specialists` | `set_updated_at` |
| `trg_patients_updated_at` | `patients` | `set_updated_at` |
| `trg_appointments_updated_at` | `appointments` | `set_updated_at` |
| `trg_contact_patient_links_updated_at` | `contact_patient_links` | `set_updated_at` |
| `trg_specialist_duplicate_policies_updated_at` | `specialist_duplicate_policies` | `set_updated_at` |
| `trg_appointments_enforce_duplicate_policy` | `appointments` | `tg_enforce_duplicate_policy` |

---

### `003_booking_validation_api.sql` (solo funciones)

| Nombre | Rol |
|--------|-----|
| `fn_resolve_contact_id_by_phone_digits` | Resuelve `contact_id` por tenant + dígitos normalizados. |
| `fn_contact_has_linked_patients` | ¿Hay pacientes vinculados al contacto? |
| `fn_patient_belongs_to_contact` | ¿El paciente pertenece a ese contacto? |
| `fn_get_booking_snapshot` | Fila de lectura de cita por `booking_uid` + datos de especialista. |
| `fn_booking_matches_specialist_code` | ¿La cita con ese `booking_uid` es de ese `specialist_code`? |
| `fn_precheck_new_appointment` | Sin insertar: duplicado exacto + conflicto de ventana + `can_insert`. |

---

### `004` / `005` / `007` — cache en `patients`

| Objeto | Rol |
|--------|-----|
| `fn_recompute_patient_appointment_cache(p_patient_id)` | Recalcula `last_appointment_starts_at`, `next_appointment_starts_at`, `active_appointment_count`, `has_active_appointment`. |
| `tg_appointments_refresh_patient_cache()` | Tras cambios en citas, llama al recomputo del/los paciente(s). |
| `trg_appointments_refresh_patient_cache` | `AFTER` en `appointments` (columnas: `patient_id`, `starts_at`, `ends_at`, `status`, `deleted_at`). |

---

### `008_specialist_codes_fk.sql`

| Objeto | Rol |
|--------|-----|
| `tg_specialists_link_specialist_code()` | Alinea `specialist_code` (texto) con `specialist_code_id` y catálogo `specialist_codes`. |
| `trg_specialists_link_specialist_code` | `BEFORE INSERT OR UPDATE` en `specialists`. |

---

### `009_appointment_actor_fks_and_mock.sql`

| Nombre | Rol |
|--------|-----|
| `_009_add_fk_if_missing(...)` | Utilidad **solo migración**: añade FK con nombre si falta; al final del script se hace `DROP` de la función. |

---

## 3. Ejemplos antes / después (filas)

Los triggers **BEFORE** transforman la fila **antes de guardarla**; el “después” es lo que queda persistido. Los **AFTER** pueden actualizar **otras** tablas (p. ej. `patients`).

---

### 3.1. Contacto: normalización de teléfono (`trg_contacts_sync_phone`)

**Operación:** `INSERT` en `contacts` con `wa_id` y sin `phone_e164`.

| Momento | `wa_id` | `phone_e164` | `phone_digits` |
|---------|---------|--------------|----------------|
| **Antes** (payload) | `5218112345678` | `NULL` | `NULL` |
| **Después** (guardado) | `5218112345678` | `+5218112345678` | `8112345678` |

---

### 3.2. Cita: sincronizar texto ↔ IDs (`trg_sync_appointment_types`)

**Operación:** `INSERT` en `appointments` con `source` y `status` en texto; IDs en `NULL`.

| Momento | `source` | `source_type_id` | `status` | `status_type_id` | `appointment_type_id` |
|---------|----------|------------------|----------|-------------------|-------------------------|
| **Antes** | `whatsapp` | `NULL` | `confirmed` | `NULL` | `NULL` |
| **Después** | `whatsapp` | `1` | `confirmed` | `2` | `1` |

*(Los valores numéricos concretos dependen del seed del catálogo en tu base.)*

---

### 3.3. Paciente: cache al insertar cita (`trg_appointments_refresh_patient_cache`)

Paciente `P1` sin citas previas. Tras insertar una cita futura activa (`confirmed`, no borrada, con `ends_at` en el futuro):

#### Tabla `patients` — fila `P1`

| Momento | `next_appointment_starts_at` | `last_appointment_starts_at` | `active_appointment_count` | `has_active_appointment` |
|---------|------------------------------|------------------------------|----------------------------|--------------------------|
| **Antes** | `NULL` | `NULL` | `0` | `false` |
| **Después** | *(mínimo `starts_at` futuro en pending/confirmed/rescheduled)* | *(máx. `starts_at` ≤ ahora, cualquier status)* | *(conteo de citas “aún vigentes” por reglas del script)* | `true` si hay próxima cita futura en esos estados |

#### Tras cancelar esa cita (`status = cancelled`)

| Momento | `next_appointment_starts_at` | `active_appointment_count` | `has_active_appointment` |
|---------|------------------------------|----------------------------|--------------------------|
| **Antes** | *(tenía próxima)* | `≥ 1` según casos | `true` |
| **Después** | `NULL` (si no queda otra próxima) | `0` (si no queda intervalo vigente) | `false` |

---

### 3.4. Especialista: código y FK (`trg_specialists_link_specialist_code`)

**Operación:** `INSERT` en `specialists` con `specialist_code = 'dr_juan'`, `specialist_code_id = NULL`.

| Momento | `specialist_code` | `specialist_code_id` |
|---------|-------------------|----------------------|
| **Antes** | `dr_juan` | `NULL` |
| **Después** | `dr_juan` | *(UUID en `specialist_codes` para ese tenant y code)* |

---

### 3.5. Política de duplicados: bloqueo, no actualización (`trg_appointments_enforce_duplicate_policy`)

Política tipo **mismo slot exacto** (`exact_slot`): segunda cita activa igual paciente + mismo `starts_at` → **error**, no se inserta fila.

| Intento | Resultado |
|---------|-----------|
| **Antes** | Segundo `INSERT` con mismo `tenant_id`, paciente, especialista, `starts_at`, estado activo |
| **Después** | *Ninguna fila nueva*; la transacción falla con excepción definida en el trigger |

---

### 3.6. Función explícita: cancelar por booking (`fn_cancel_appointment_by_booking_uid`)

**Estado inicial** (cita `BK-001`):

| `booking_uid` | `status` | `cancel_reason` |
|---------------|----------|-----------------|
| `BK-001` | `confirmed` | `NULL` |

**Tras** `SELECT fn_cancel_appointment_by_booking_uid(..., 'BK-001', 'Pedido del paciente', ...);`

| `booking_uid` | `status` | `cancel_reason` |
|---------------|----------|-----------------|
| `BK-001` | `cancelled` | `Pedido del paciente` |

Además se inserta (si aplica) un registro en `appointment_events` con tipo `appointment.cancelled`.

---

## 4. Resumen de comportamiento

| Tipo | Qué comparar en “antes / después” |
|------|-----------------------------------|
| Triggers **BEFORE** | La fila de la tabla que se inserta/actualiza (valores transformados al persistir). |
| Triggers **AFTER** (cache) | La fila del **paciente** en `patients`, no solo la cita. |
| Funciones llamadas desde app / Make | Tablas que la función actualice o consulte según su definición en el `.sql`. |

---

*Generado a partir del esquema en `backend/sql` (002–009). Ajustar valores de catálogo (IDs) según los datos reales del entorno. La sección 1 describe cuándo corre cada tipo de objeto; el cron es opcional y orientado a reconciliación, no al flujo normal de triggers.*
