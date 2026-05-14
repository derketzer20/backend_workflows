# Ejemplos en tabla: registros, momento, trigger o función y resultado

Complemento de `DOC_funciones_triggers_y_ejemplos.md`. Aquí cada fila es un **escenario** con datos de ejemplo, **cuándo** ocurre en el flujo SQL y **qué objeto** de PostgreSQL actúa.

**Leyenda rápida**

- **Momento:** el punto en el tiempo del motor de base de datos (no un cron), salvo donde se indique “job programado”.
- **Síncrono:** el trigger corre **dentro de la misma transacción** que el `INSERT`/`UPDATE`/`DELETE` que lo disparó.

---

## Tabla 1 — Escenarios principales (registro → momento → objeto → qué pasa)

| # | Escenario | Ejemplo de registro / entrada | Momento (evento) | Función o trigger | Qué sucede |
|---|-----------|------------------------------|------------------|---------------------|------------|
| 1 | Alta de contacto con WhatsApp | `contacts`: `tenant_id=T1`, `wa_id='5218112345678'`, `phone_e164` NULL | `INSERT INTO contacts ...` | **Trigger** `trg_contacts_sync_phone` → `tg_sync_contacts_phone()` | Antes de persistir la fila: rellena `phone_e164` (E.164) y `phone_digits` (10 dígitos MX). |
| 2 | Alta de paciente con teléfono | `patients`: `phone_e164` con formato sucio | `INSERT` o `UPDATE` de `phone_e164` | **Trigger** `trg_patients_sync_phone` → `tg_sync_patients_phone()` | Normaliza `phone_e164` y `phone_digits` en la fila que se guarda. |
| 3 | Nueva cita solo con texto de tipo | `appointments`: `source='whatsapp'`, `status='confirmed'`, `source_type_id` NULL | `INSERT INTO appointments ...` | **Trigger** `trg_sync_appointment_types` → `tg_sync_appointment_types()` | Rellena `source_type_id`, `status_type_id` desde catálogos; si falta tipo de cita, asigna default `appointment_type_id = 1`. |
| 4 | Cita nueva que debe actualizar cache del paciente | `appointments`: `patient_id=P1`, `starts_at` futuro, `status='confirmed'`, `deleted_at` NULL | `INSERT INTO appointments ...` (después de commit de la fila cita) | **Trigger** `trg_appointments_refresh_patient_cache` → `tg_appointments_refresh_patient_cache()` → llama **`fn_recompute_patient_appointment_cache(P1)`** | **AFTER** insert: recalcula columnas de agenda en `patients` para `P1` (`last_*`, `next_*`, `active_appointment_count`, `has_active_appointment`). |
| 5 | Cambio de horario o estado de la cita | Misma cita: `UPDATE appointments SET status='cancelled' ...` donde antes estaba activa | `UPDATE` en columnas vigiladas (`status`, `starts_at`, `ends_at`, `patient_id`, `deleted_at`) | Mismo **trigger** de fila 4 + **antes** puede actuar `trg_sync_appointment_types` si tocas `source`/`status` textuales | Cache de `patients` se recalcula otra vez para el paciente afectado. |
| 6 | Reasignar cita a otro paciente | `UPDATE appointments SET patient_id=P2 WHERE id=...` (antes `P1`) | `UPDATE` de `patient_id` | **Trigger** cache (mismo #4) | Se ejecuta **`fn_recompute`** para **P1** (viejo) y **P2** (nuevo): dos recomputos en esa operación. |
| 7 | Intento de segunda cita en conflicto con política | Segunda fila `appointments` misma ventana / mismo slot según `specialist_duplicate_policies` | `INSERT` o `UPDATE` que deja la cita en estado activo (`pending`/`confirmed`/`rescheduled`) | **Trigger** `trg_appointments_enforce_duplicate_policy` → `tg_enforce_duplicate_policy()` → usa **`fn_find_window_conflict_appointment(...)`** | **BEFORE:** si hay conflicto, la transacción **falla** con excepción; **no** se inserta/actualiza la fila conflictiva. |
| 8 | Alta de especialista con código texto | `specialists`: `specialist_code='dr_juan'`, `specialist_code_id` NULL | `INSERT INTO specialists ...` | **Trigger** `trg_specialists_link_specialist_code` → `tg_specialists_link_specialist_code()` | Upsert en `specialist_codes` si hace falta y asigna `specialist_code_id` antes del `INSERT` final. |
| 9 | Vínculo contacto–paciente con tipo en texto | `contact_patient_links`: `relationship_type='familiar'` | `INSERT` / `UPDATE` de columnas de relación | **Trigger** `trg_sync_contact_patient_link_types` | Alinea `relationship_type_id` y códigos con catálogo. |
| 10 | Mensaje omnicanal | `channel_messages`: `source`, `direction` en texto | `INSERT` / `UPDATE` relevante | **Trigger** `trg_sync_channel_message_types` | Sincroniza `source_type_id` y `direction_type_id`. |
| 11 | Evento de auditoría de cita | `appointment_events`: `source`, `actor_type`, `event_type` | `INSERT` / `UPDATE` relevante | **Trigger** `trg_sync_appointment_event_types` | Sincroniza IDs de catálogo; default de `event_type_id` si aplica. |
| 12 | Política de duplicados por especialista | `specialist_duplicate_policies`: `policy_scope`, `window_type` en texto | `INSERT` / `UPDATE` | **Trigger** `trg_sync_specialist_policy_types` | Sincroniza `policy_scope_type_id`, `window_type_id`. |
| 13 | Cualquier `UPDATE` en tablas con `updated_at` | Ej.: `UPDATE locations SET display_name=...` | `UPDATE` en la tabla | **Triggers** `trg_*_updated_at` → **`set_updated_at()`** | Pone `updated_at = now()` en la fila que se actualiza. |
| 14 | Validación previa sin insertar (Make / API) | Parámetros: `tenant_id`, `patient_id`, `specialist_id`, `starts_at` | `SELECT * FROM fn_precheck_new_appointment(...)` | **Función** `fn_precheck_new_appointment` (invoca internamente `fn_find_duplicate_active_appointment` y `fn_find_window_conflict_appointment`) | **No hay trigger:** solo lectura/cálculo; devuelve `duplicate_exact_id`, `window_conflict_id`, `can_insert`. |
| 15 | Cancelar cita por UID de reserva | `booking_uid='BK-001'`, motivo, tenant | `SELECT fn_cancel_appointment_by_booking_uid(...)` | **Función** `fn_cancel_appointment_by_booking_uid` | **No es trigger:** hace `UPDATE` de la cita a `cancelled` e inserta fila en `appointment_events`; el **trigger de cache** (#4) se disparará por ese `UPDATE` si aplica columnas. |
| 16 | Reagendar por UID | `booking_uid`, nuevas fechas, razón | `SELECT fn_reschedule_appointment_by_booking_uid(...)` | **Función** `fn_reschedule_appointment_by_booking_uid` | Actualiza horarios y estado; inserta evento; el **cache** puede actualizarse vía trigger #4. |
| 17 | Resolver contacto por teléfono | `p_phone_digits='8112345678'` | `SELECT fn_resolve_contact_id_by_phone_digits(tenant, digits)` | **Función** `fn_resolve_contact_id_by_phone_digits` | Devuelve un `uuid` o NULL; no modifica tablas. |
| 18 | Lectura de snapshot de reserva | `booking_uid` | `SELECT * FROM fn_get_booking_snapshot(...)` | **Función** `fn_get_booking_snapshot` | Devuelve fila(s) de vista lógica; no modifica tablas. |
| 19 | Aplicar script de migración SQL | Contenido del archivo `002_...sql`, `004_...sql`, etc. | Una vez al ejecutar `psql` / editor SQL contra la base | `CREATE OR REPLACE FUNCTION` / `CREATE TRIGGER` | Define o sustituye objetos en el catálogo; algunos scripts incluyen **backfill** (`DO $$ ... fn_recompute ...`) **solo en esa ejecución**. |
| 20 | Job nocturno opcional (reconciliación o reloj) | N/A (no es una fila nueva) | Según cron: p. ej. `0 3 * * *` | **Función** `fn_recompute_patient_appointment_cache` llamada en bucle (SQL del doc principal) | **No es trigger automático:** recorre pacientes y refresca cache; útil si no hubo escrituras y el tiempo “dejó obsoleto” el cache o tras cargas masivas. |

---

## Tabla 2 — Misma operación: orden típico en una **sola** inserción de cita

Ejemplo: `INSERT INTO appointments (...) VALUES (...)` con fila válida (sin error de política).

| Orden | Momento dentro de la transacción | Objeto | Efecto |
|-------|-----------------------------------|--------|--------|
| 1 | BEFORE INSERT en `appointments` | `trg_sync_appointment_types` | Ajusta IDs/texto de tipo en `NEW`. |
| 2 | BEFORE INSERT en `appointments` | `trg_appointments_enforce_duplicate_policy` | Llama a `fn_find_window_conflict_appointment`; si OK, continúa. |
| 3 | Row se escribe en `appointments` | *(motor)* | Fila persistida. |
| 4 | AFTER INSERT en `appointments` | `trg_appointments_refresh_patient_cache` | `PERFORM fn_recompute_patient_appointment_cache(patient_id)`. |

*(Si existieran otros BEFORE en la misma tabla, el orden real depende del orden de creación de los triggers en PostgreSQL; lo anterior refleja la intención lógica de validación vs. sync.)*

---

## Tabla 3 — Ejemplo concreto de **filas** (contacto): antes vs después en memoria de `NEW`

Operación: un solo `INSERT`. El “antes” es lo que envía la app; el “después” es lo que **queda guardado** tras los triggers BEFORE.

| Campo | Antes (`NEW` lógico) | Después (persistido) |
|-------|----------------------|----------------------|
| `wa_id` | `5218112345678` | `5218112345678` |
| `phone_e164` | `NULL` | `+5218112345678` |
| `phone_digits` | `NULL` | `8112345678` |

**Disparador:** `trg_contacts_sync_phone` en el momento del `INSERT INTO contacts`.

---

## Tabla 4 — Ejemplo concreto de **filas** (cita + paciente): dos tablas enlazadas

**Paso A — Paciente `P1` antes de la cita**

| Tabla | `id` | `next_appointment_starts_at` | `has_active_appointment` |
|-------|------|-------------------------------|----------------------------|
| `patients` | `P1` | `NULL` | `false` |

**Paso B — Momento:** `INSERT` en `appointments` con `patient_id = P1`, cita futura activa.

**Paso C — Paciente `P1` después del trigger AFTER**

| Tabla | `id` | `next_appointment_starts_at` | `has_active_appointment` |
|-------|------|-------------------------------|----------------------------|
| `patients` | `P1` | `2026-06-01 09:00:00+00` (ejemplo) | `true` |

**Disparador:** `trg_appointments_refresh_patient_cache` → **`fn_recompute_patient_appointment_cache('P1')`**.

---

## Tabla 5 — Ejemplo de **bloqueo** (no hay fila nueva)

| Paso | Tabla | Acción | Objeto | Resultado |
|------|--------|--------|--------|-----------|
| 1 | `appointments` | `INSERT` segunda cita en conflicto con política | `trg_appointments_enforce_duplicate_policy` | Excepción; **rollback** de esa sentencia (o de la transacción completa según manejo del cliente). |
| 2 | `appointments` | — | — | **No** aparece una segunda fila; la primera sigue igual. |

---

## Referencia rápida: función **sin** trigger propio

| Función | ¿Se ejecuta sola en el tiempo? | Cómo se ejecuta |
|---------|-------------------------------|-----------------|
| `fn_precheck_new_appointment` | No | Solo con `SELECT` / RPC explícita. |
| `fn_get_booking_snapshot`, funciones de `003` | No | Igual: llamada explícita. |
| `fn_cancel_appointment_by_booking_uid`, `fn_reschedule_...` | No | Llamada explícita; pueden disparar triggers de las tablas que modifiquen. |
| `fn_recompute_patient_appointment_cache` | No (salvo cron/bucle que ustedes programen) | Trigger de citas **o** SQL manual / job. |

---

*Archivo: `backend/sql/DOC_ejemplos_tabla_triggers_y_funciones.md`. Alinear fechas y UUIDs con datos de prueba reales de tu entorno.*
