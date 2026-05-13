# Modelo de Datos PostgreSQL Omnicanal

Este documento define el modelo objetivo para agendamiento por WhatsApp, voz (Dialora) y web (Cal.com).

## Migraciones

- Base: `backend/sql/001_init_schema.sql`
- Endurecimiento omnicanal: `backend/sql/002_omnichannel_model.sql`
- API de validación lectura (opcional): `backend/sql/003_booking_validation_api.sql`

## Entidades principales

- `tenants`: límite de clínica/cuenta (multi-tenant).
- `locations`: sede física/lógica por tenant con zona horaria.
- `specialists`: doctores vinculados al tenant (y opcionalmente a sede).
- `contacts`: identidad de canal (`wa_id`, normalización de teléfono).
- `patients`: persona que recibe la atención.
- `contact_patient_links`: relación titular-familia y permisos.
- `appointments`: ciclo de vida de citas por canal.
- `appointment_events`: bitácora inmutable de eventos.
- `channel_messages`: trazabilidad opcional de mensajes/interacciones.
- `specialist_duplicate_policies`: políticas por doctor para bloquear duplicados por ventana de tiempo.
- Catálogos por tipo (normalización por ID):
  - `appointment_source_types`
  - `appointment_status_types`
  - `appointment_types`
  - `relationship_types`
  - `policy_scope_types`
  - `policy_window_types`
  - `message_direction_types`
  - `actor_types`
  - `appointment_event_types`

## Modelo de relaciones

- `tenants` 1..N `locations`
- `tenants` 1..N `specialists`
- `tenants` 1..N `contacts`
- `contacts` N..N `patients` vía `contact_patient_links`
- `patients` 1..N `appointments`
- `specialists` 1..N `appointments`
- `locations` 1..N `appointments`
- `appointments` 1..N `appointment_events`
- Relaciones FK con catálogos:
  - `appointments.source_type_id` -> `appointment_source_types.id`
  - `appointments.status_type_id` -> `appointment_status_types.id`
  - `appointments.appointment_type_id` -> `appointment_types.id`
  - `contact_patient_links.relationship_type_id` -> `relationship_types.id`
  - `specialist_duplicate_policies.policy_scope_type_id` -> `policy_scope_types.id`
  - `specialist_duplicate_policies.window_type_id` -> `policy_window_types.id`
  - `channel_messages.source_type_id` -> `appointment_source_types.id`
  - `channel_messages.direction_type_id` -> `message_direction_types.id`
  - `appointment_events.source_type_id` -> `appointment_source_types.id`
  - `appointment_events.actor_type_id` -> `actor_types.id`
  - `appointment_events.event_type_id` -> `appointment_event_types.id`

## Reglas críticas de integridad

- Unicidad técnica de cita por `(tenant_id, booking_uid)` cuando `booking_uid` existe.
- Guardia de duplicado exacto para citas activas por `(tenant_id, patient_id, specialist_id, starts_at)` en estados:
  - `pending`
  - `confirmed`
  - `rescheduled`
- Guardia por política de ventana (`specialist_duplicate_policies`) para bloquear más de una cita activa en:
  - mismo slot exacto (`exact_slot`)
  - misma semana (`week`)
  - mismo mes (`month`)
  - mismo trimestre (`quarter`)
  - ventana móvil por días (`rolling_days` con `window_days`)
- `appointments` valida `starts_at < ends_at` cuando ambas fechas existen.
- Idempotencia de eventos con `(tenant_id, source, event_type, external_event_id)`.
- Se mantienen columnas de texto para compatibilidad temporal con flujos actuales de Make, pero ya hay FK por ID con backfill.

## Borrado lógico y auditoría

- Borrado lógico por `deleted_at` en:
  - `locations`, `specialists`, `contacts`, `patients`, `appointments`, `contact_patient_links`
- `appointment_events` es append-only y no debe borrarse en flujos de negocio.
- Cancelación y reagendado deben reflejarse en:
  - `appointments.status`
  - una fila en `appointment_events`

## Estandarización de teléfonos

La migración incluye:

- `normalize_phone_e164(raw_phone text)`
- `normalize_phone_digits(raw_phone text)`
- Triggers en `contacts` y `patients`

Comportamiento canónico:

- Guardar `phone_e164` en formato tipo E.164 (normalizando entradas `+52...`/`+521...`).
- Guardar `phone_digits` (10 dígitos) como llave de comparación para Make/BotSailor.

## Estandarización de fechas y zonas horarias

- Persistir en BD como `timestamptz`.
- Renderizar en interfaz según `locations.timezone`.
- Evitar offsets manuales (`-6`) en flujos; usar siempre conversiones timezone-aware.

## Interfaces SQL operativas para flujos

La migración `002` incluye:

- `v_active_appointments`
- `v_contact_active_appointments`
- `fn_get_active_appointments_for_contact(tenant_id, contact_id)`
- `fn_cancel_appointment_by_booking_uid(...)`
- `fn_reschedule_appointment_by_booking_uid(...)`
- `fn_find_duplicate_active_appointment(...)`
- `fn_find_window_conflict_appointment(...)`
- Trigger de enforcement: `trg_appointments_enforce_duplicate_policy`

Estas interfaces están diseñadas para ser consumidas por nodos PostgreSQL de Make y mantener la lógica uniforme entre canales.

## Valores semilla de catálogos (referencia inicial)

Usa estos valores como canónicos en integraciones y validaciones.

- `appointment_source_types`
  - `1`: `whatsapp` -> `WhatsApp`
  - `2`: `voice_dialora` -> `Dialora Voice`
  - `3`: `calcom_web` -> `Cal.com Web`
  - `4`: `staff` -> `Staff`

- `appointment_status_types`
  - `1`: `pending` -> `Pending` (`is_active_status=true`)
  - `2`: `confirmed` -> `Confirmed` (`is_active_status=true`)
  - `3`: `rescheduled` -> `Rescheduled` (`is_active_status=true`)
  - `4`: `cancelled` -> `Cancelled` (`is_active_status=false`)
  - `5`: `no_show` -> `No Show` (`is_active_status=false`)
  - `6`: `completed` -> `Completed` (`is_active_status=false`)

- `appointment_types`
  - `1`: `general_consultation` -> `General Consultation`
  - `2`: `first_time` -> `First Time Consultation`
  - `3`: `follow_up` -> `Follow-up Consultation`
  - `4`: `procedure` -> `Procedure`
  - `5`: `emergency` -> `Emergency`
  - `6`: `other` -> `Other`

- `relationship_types`
  - `1`: `titular` -> `Titular`
  - `2`: `familiar` -> `Familiar`
  - `3`: `dependiente` -> `Dependent`
  - `4`: `otro` -> `Other`

- `policy_scope_types`
  - `1`: `same_specialist` -> `Same Specialist`
  - `2`: `all_specialists` -> `All Specialists`

- `policy_window_types`
  - `1`: `none` -> `No Window Restriction` (`requires_days=false`)
  - `2`: `exact_slot` -> `Exact Slot` (`requires_days=false`)
  - `3`: `week` -> `Same Week` (`requires_days=false`)
  - `4`: `month` -> `Same Month` (`requires_days=false`)
  - `5`: `quarter` -> `Same Quarter` (`requires_days=false`)
  - `6`: `rolling_days` -> `Rolling Days` (`requires_days=true`)

- `message_direction_types`
  - `1`: `inbound` -> `Inbound`
  - `2`: `outbound` -> `Outbound`

- `actor_types`
  - `1`: `patient` -> `Patient`
  - `2`: `specialist` -> `Specialist`
  - `3`: `staff` -> `Staff`
  - `4`: `system` -> `System`

- `appointment_event_types`
  - `1`: `appointment.created` -> `Appointment Created`
  - `2`: `appointment.confirmed` -> `Appointment Confirmed`
  - `3`: `appointment.rescheduled` -> `Appointment Rescheduled`
  - `4`: `appointment.cancelled` -> `Appointment Cancelled`
  - `5`: `appointment.completed` -> `Appointment Completed`
  - `6`: `appointment.no_show` -> `Appointment No Show`
  - `7`: `reminder.sent` -> `Reminder Sent`
  - `8`: `reminder.confirmed` -> `Reminder Confirmed`
  - `9`: `webhook.received` -> `Webhook Received`
  - `10`: `other` -> `Other`

## Valores operativos por default (setup actual DR/DRA)

Usa estos defaults durante la transición de Sheets a PostgreSQL con Make.

- Defaults de tenant y sede:
  - `tenant_id`: un tenant fijo por instancia de clínica.
  - `location_id`: sede principal de Monterrey.
  - `locations.timezone`: `America/Monterrey`.

- Defaults de especialista:
  - `specialist_code`: `dr_juan` y `dra_ana` (o los códigos canónicos que definas).
  - `appointment_type_id`: `1` (`general_consultation`) cuando el flujo no envía tipo.

- Defaults de creación de cita:
  - `source_type_id` por canal:
    - WhatsApp -> `1`
    - Voz Dialora -> `2`
    - Cal.com web -> `3`
    - Staff/manual -> `4`
  - `status_type_id`: `1` (`pending`) al crear, y luego:
    - confirmar -> `2`
    - reagendar -> `3`
    - cancelar -> `4`

- Defaults de ventana por especialista:
  - Sin regla estricta inicial: `window_type_id=2` (`exact_slot`).
  - Una cita activa por semana: `window_type_id=3`.
  - Una cita activa por mes: `window_type_id=4`.
  - Ventana de X días: `window_type_id=6` + `window_days`.
  - Scope por default: `policy_scope_type_id=1` (`same_specialist`).

- Defaults de relación:
  - Titular (dueño del número): `relationship_type_id=1`.
  - Familiar: `relationship_type_id=2` (o `3` si es dependiente).

- Defaults de mensajería:
  - Mensaje entrante del usuario: `direction_type_id=1`.
  - Mensaje saliente (template/notificación): `direction_type_id=2`.
