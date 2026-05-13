# Cache de agenda en `patients`: funciones, triggers y columnas

Este documento describe cómo se calculan y mantienen **`last_appointment_starts_at`**, **`next_appointment_starts_at`**, **`active_appointment_count`** y **`has_active_appointment`** en la tabla **`patients`**, en función de **`appointments`**.

- **Migración fuente:** `004_patient_appointment_cache.sql` (y `005_regularize_patient_appointment_cache.sql`).
- **Fix semántica `has_active` (próxima cita):** `007_fix_has_active_proxima_cita.sql` (o reaplicar `004`/`005` ya actualizados).
- **Normalización de datos:** `006_normalize_appointment_intervals.sql`.
- **Consultas de verificación:** `queries_verify_seed_dr_juan.sql`.

---

## 1. Columnas en `patients` (el “cache”)

| Columna | ¿Quién la escribe? | Tipo / restricción |
|--------|---------------------|---------------------|
| `last_appointment_starts_at` | `fn_recompute_patient_appointment_cache` | `timestamptz`, puede ser **NULL** |
| `next_appointment_starts_at` | Idem | `timestamptz`, puede ser **NULL** |
| `active_appointment_count` | Idem | `integer NOT NULL`, por defecto **0** |
| `has_active_appointment` | `fn_recompute_patient_appointment_cache` (mismo `UPDATE`) | `boolean NOT NULL`, default **false**; **no** es columna generada |

La **fuente de verdad** sigue siendo la tabla **`appointments`**. El cache es una **proyección** para lecturas rápidas (Make, dashboards).

**Diferencia clave:** `active_appointment_count` cuenta citas cuyo **intervalo** sigue vigente (`ends_at > now()` o equivalente). `has_active_appointment` refleja si hay **próxima cita** con inicio futuro (`next_appointment_starts_at IS NOT NULL` justo después del recomputo, equivalente a `v_next IS NOT NULL`). Sirve para “¿el titular o asociado tienen cita agendada a futuro?”.

---

## 2. Función `fn_recompute_patient_appointment_cache(p_patient_id uuid)`

### 2.1 Uso

- **Parámetro:** `p_patient_id` — UUID del paciente.
- **Retorno:** `void`.
- **Efecto:** un solo `UPDATE` sobre la fila de ese paciente en `patients`, recalculando **`last_appointment_starts_at`**, **`next_appointment_starts_at`**, **`active_appointment_count`** y **`has_active_appointment`**.

### 2.2 Momento en que se ejecuta

1. **Trigger** `trg_appointments_refresh_patient_cache` (ver sección 3) tras cambios en `appointments`.
2. **Backfill** al final de `004` / `005` / `006` / `007` (bucle `perform fn_recompute_patient_appointment_cache(r.id)`).
3. **Seed** `seed_dr_juan_monterrey_from_crm.sql` (bloque `do $$` al final).
4. **Manual:** `SELECT fn_recompute_patient_appointment_cache('uuid-del-paciente'::uuid);` o `PERFORM` dentro de un bloque PL/pgSQL.

### 2.3 Si `p_patient_id` es NULL

La función **sale de inmediato** (`return`) y **no** modifica ningún paciente.

### 2.4 Variable interna `v_now`

Al entrar se fija **`v_now := now()`** (una sola vez por llamada). Todos los `max` / `min` / `count` usan ese instante. Si dos citas “rozán” el tiempo real, el resultado es coherente dentro de esa ejecución.

### 2.5 Cálculo 1: `last_appointment_starts_at` → variable `v_last`

**Significado:** inicio de la **última cita ya comenzada** (o en curso respecto al inicio), **cualquier** `status`, siempre que la cita no esté borrada lógicamente.

**Depende de columnas en `appointments`:**

| Campo | Condición |
|-------|-----------|
| `patient_id` | `= p_patient_id` |
| `deleted_at` | `IS NULL` |
| `starts_at` | `IS NOT NULL` y **`starts_at <= v_now`** |

**Valor escrito:** `max(starts_at)` de ese conjunto, o **NULL** si no hay ninguna fila que cumpla (p. ej. paciente sin citas, o todas sin `starts_at`, o todas borradas, o todas con inicio estrictamente en el futuro).

### 2.6 Cálculo 2: `next_appointment_starts_at` → variable `v_next`

**Significado:** inicio de la **próxima** cita **aún por comenzar** en el tiempo, solo en estados “operativos” de agenda.

**Depende de:**

| Campo | Condición |
|-------|-----------|
| `patient_id` | `= p_patient_id` |
| `deleted_at` | `IS NULL` |
| `starts_at` | `IS NOT NULL` y **`starts_at > v_now`** |
| `status` | **`IN ('pending', 'confirmed', 'rescheduled')`** |

**Valor escrito:** `min(starts_at)`, o **NULL** si no hay candidatas (p. ej. no hay citas futuras en esos estados).

**Si `starts_at` es NULL:** esa cita **no entra** en `v_next` (ni en `v_last`).

### 2.7 Cálculo 3: `active_appointment_count` → variable `v_active`

**Significado:** número de citas **aún vigentes en tiempo** (slot no terminado o futuro sin fin), en estados operativos.

**Depende de:**

| Campo | Condición |
|-------|-----------|
| `patient_id` | `= p_patient_id` |
| `deleted_at` | `IS NULL` |
| `status` | `IN ('pending', 'confirmed', 'rescheduled')` |
| Intervalo vigente | **`(ends_at IS NOT NULL AND ends_at > v_now) OR (ends_at IS NULL AND starts_at IS NOT NULL AND starts_at > v_now)`** |

**Valor escrito:** `count(*)`, o **0** si `v_active` queda NULL (`coalesce(v_active, 0)`).

**Casos sin valor o valores “raros”:**

- **`ends_at` NULL y `starts_at` en el pasado:** la segunda rama exige `starts_at > v_now`, así que **no cuenta** como activa. Conviene rellenar `ends_at` (p. ej. script **`006`**: `ends_at = starts_at + 30 minutes` cuando falta o es inválido).
- **`ends_at` NOT NULL pero `ends_at <= v_now`:** la cita **ya terminó** respecto al fin del slot → **no** suma al contador (aunque `status` siga `confirmed`).
- **`ends_at <= starts_at`:** intervalo inválido; suele hacer que **no** cumpla `ends_at > v_now` de forma útil → corregir con **`006`** o datos de origen (Cal.com / integración).

### 2.8 `has_active_appointment`

Se asigna en el mismo `UPDATE` que el resto del cache:

```text
has_active_appointment = (v_next IS NOT NULL)
```

Es decir: **true** si y solo si existe al menos una cita en `pending|confirmed|rescheduled` con **`starts_at > v_now`** (la misma lógica que alimenta `next_appointment_starts_at`). Tras cada recomputo, en base consistente se cumple:

```text
has_active_appointment  ⇔  (next_appointment_starts_at IS NOT NULL)
```

| Situación | `has_active_appointment` |
|-----------|---------------------------|
| Hay próxima cita futura en estados operativos | `true` |
| No hay ningún `starts_at` futuro en esos estados (solo pasadas, o sin citas, o todos `cancelled`/`completed`/…) | `false` |
| Solo cita “en curso” (inicio ≤ ahora) y ninguna otra futura | `false` (no hay “próxima” en el sentido `starts_at > now`) |

**Importante:** el valor queda fijado al instante `v_now` del recomputo. Si pasa el tiempo sin nuevos eventos en `appointments`, puede quedar obsoleto hasta el siguiente trigger o un job de refresco.

### 2.9 Otras columnas tocadas en el mismo `UPDATE`

- **`patients.updated_at`** se pone a **`now()`** en cada recomputo (si la columna existe en tu versión de `002`).

---

## 3. Trigger `trg_appointments_refresh_patient_cache`

### 3.1 Definición

- **Tabla:** `appointments`
- **Momento:** `AFTER`
- **Eventos:** `INSERT`, `DELETE`, `UPDATE`
- **Columnas relevantes en `UPDATE`:** solo dispara el trigger si cambian **`patient_id`**, **`starts_at`**, **`ends_at`**, **`status`** o **`deleted_at`** (lista explícita `UPDATE OF ...`).

### 3.2 Función del trigger: `tg_appointments_refresh_patient_cache()`

Es la que decide **qué** `patient_id` recalcula.

| Operación | Qué hace |
|-----------|----------|
| **DELETE** | Si `old.patient_id` **no es NULL** → `perform fn_recompute_patient_appointment_cache(old.patient_id)`. Si `patient_id` era NULL, **no** llama a la función (no hay paciente asociado al borrado). |
| **INSERT** | Si `new.patient_id` **no es NULL** → `perform fn_recompute_patient_appointment_cache(new.patient_id)`. Si la cita se inserta **sin** paciente, el cache de ningún paciente se actualiza por este camino. |
| **UPDATE** | Si cambió el paciente: recalcula **el paciente viejo** (si `old.patient_id` no es NULL) **y** **el paciente nuevo** (si `new.patient_id` no es NULL). Así no queda huérfano el cache del paciente que “perdió” la cita. |

**Valores esperados en `appointments`:**

- **`patient_id`:** idealmente siempre UUID de `patients`. NULL es válido en modelo pero **no** dispara recálculo en INSERT; en DELETE/UPDATE se evita llamar con NULL.
- **`starts_at` / `ends_at`:** `timestamptz` coherentes con la zona del negocio; el contador de activas depende fuertemente de **`ends_at`**.

**Si no hay trigger instalado** (migración 004 no aplicada): las columnas de cache en `patients` **no** se actualizan solas al cambiar citas.

### 3.3 Otros triggers en `appointments` (002)

No calculan el cache de `patients`, pero conviene conocerlos:

- **`trg_appointments_updated_at`:** `BEFORE UPDATE` — suele poner `appointments.updated_at`.
- **`trg_appointments_enforce_duplicate_policy`:** valida duplicados según política del especialista.
- **`trg_sync_appointment_types`:** sincroniza tipos por ID desde texto.

El orden respecto al cache: el recálculo es **`AFTER`**, así que ve el estado **ya confirmado** de la fila de `appointments` (salvo que otro trigger `AFTER` modifique la misma fila en la misma sentencia, lo cual no es el caso habitual).

---

## 4. Vista `v_patients_with_contact_role`

- **Solo lectura** — no tiene triggers.
- **Une** `patients` + `contacts` + `contact_patient_links` y expone las columnas de cache tal cual están en `patients`.
- Si el paciente no tiene contacto válido (`deleted_at` en contacto, etc.), puede **no** aparecer según el `JOIN` de la vista.

---

## 5. Ejemplos con datos del seed Dr. Juan (CorpOS Monterrey)

**Tenant:** `9e4860a5-d163-548d-8cb2-886f4d9e71f2`

Los valores de cache **dependen de `now()`** en el momento del `fn_recompute`. Los ejemplos siguientes asumen que **ya pasaron** las citas de abril y mayo de 2026 (como en una prueba ejecutada “después” de esas fechas en el reloj del servidor).

### 5.1 Madeleine (una cita el 2026-05-12 en Monterrey)

- **`patients.id`:** `74ae82ae-2ba2-5a78-b65c-a281239d458b`
- **`full_name`:** Madeleine
- **`contacts.phone_digits`:** 8110068282 (vía `contact_id` `1a5a6edc-9e98-5e10-8ec3-f61672685447`)
- **Cita en seed:** `appointments` id `74de2520-f2ad-54a1-b7c7-46557f46f84d`, `status = confirmed`, inicio local `2026-05-12 11:00` MTY, fin `11:30` MTY.

**Cuando `now()` es posterior al fin de la cita:**

- `last_appointment_starts_at` ≈ instante UTC equivalente a ese **2026-05-12 11:00 MTY**.
- `next_appointment_starts_at` = **NULL** (no hay otra cita futura en `pending|confirmed|rescheduled`).
- `active_appointment_count` = **0** (porque `ends_at` ya no es mayor que `now()`).
- `has_active_appointment` = **false**.

### 5.2 Eugenio (una cita el 2026-05-12 tarde)

- **`patients.id`:** `cdb5fcf4-49e6-54ae-90ce-aee9c87b21d9`
- **`full_name`:** Eugenio
- **Teléfono:** 8140056133
- **Cita:** `9fc8a26d-b11f-55d2-907e-5013001f4ba1`, `confirmed`, `2026-05-12 18:30`–`19:00` MTY.

Misma lógica que Madeleine una vez pasada la hora de fin: cache con **0** activas y **has_active** false si no hay más citas.

### 5.3 Luis (cita abril con `booking_uid`)

- **`patients.id`:** `9dc700a0-e69e-5dd6-920b-8f90dd07a6c0`
- **Cita:** `6283d4be-8a69-57a3-b8a4-b7d61a46cbb3`, `confirmed`, abril 2026.

Tras la fecha: **activas 0**, **has_active** false; `last_appointment_starts_at` refleja el inicio de esa cita pasada.

### 5.4 Paciente sin filas en `appointments` (p. ej. Martha Yrenne en el seed)

- **`patients.id`:** `1b908ac6-029a-511b-9032-dca314b310c0`

Tras `fn_recompute`:

- `last_appointment_starts_at` = **NULL**
- `next_appointment_starts_at` = **NULL**
- `active_appointment_count` = **0**
- `has_active_appointment` = **false**

### 5.5 Hipotético: dos citas futuras (misma semántica)

Si el mismo paciente tuviera **dos** filas futuras en `pending|confirmed|rescheduled` con `starts_at > v_now`, entonces **`next_appointment_starts_at`** es el **mínimo** de esos inicios, **`has_active_appointment = true`**, y **`active_appointment_count`** puede ser **2** si ambas ventanas siguen vigentes por `ends_at` (o 1 si solo una cumple la regla de intervalo).

---

## 6. Resumen rápido para soporte

| Síntoma | Qué revisar |
|---------|-------------|
| `has_active` false pero hay cita futura en calendario | `starts_at` / zona horaria, `status` debe ser pending|confirmed|rescheduled; ejecutar `fn_recompute` o `007` si la columna seguía generada por `active_count` |
| `has_active` true sin cita “sentida” por negocio | Revisar si `next_appointment_starts_at` apunta a una cita que el CRM ya canceló (`status` o `deleted_at`) |
| `next_appointment_starts_at` NULL | No hay cita futura (`starts_at > now()`) en esos tres estados |
| `last_appointment_starts_at` NULL | No hay cita pasada/presente con `starts_at <= now()` no borrada |
| Cache desfasado tras migración | Ejecutar `005` o backfill de `perform fn_recompute_patient_appointment_cache` por paciente |
| `ends_at` mal o vacío | `006_normalize_appointment_intervals.sql` + volver a recomputar |

---

## 7. Referencias de archivos en el repo

| Archivo | Contenido |
|---------|-----------|
| `004_patient_appointment_cache.sql` | Columnas, función, trigger, vista, backfill |
| `005_regularize_patient_appointment_cache.sql` | Instalación / regularización idempotente del mismo mecanismo |
| `006_normalize_appointment_intervals.sql` | Corrige `ends_at` cuando falta o es inválido |
| `007_fix_has_active_proxima_cita.sql` | Migración puntual: columna `has_active` persistida + función alineada a próxima cita + backfill |
| `queries_verify_seed_dr_juan.sql` | Consultas 0.6, 0.7, 0.8, A, B para auditar reglas y cache |
| `seed_dr_juan_monterrey_from_crm.sql` | Datos de ejemplo y recomputo final |
