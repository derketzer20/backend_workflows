# Guía de Endurecimiento Make + BotSailor (Null-safe)

Esta guía define contratos de datos y validaciones defensivas para los escenarios actuales.

## 1) Contrato canónico de entrada

Usa estas llaves canónicas antes de cualquier llamada a Cal.com o escritura en BD.

### Crear cita

Requerido:

- `tenant_id`
- `channel` (`whatsapp` | `voice_dialora` | `calcom_web` | `staff`)
- `especialista_codigo` (código canónico, no rutear por texto libre)
- `numero` (raw)
- `nombre_paciente`
- `fecha_nacimiento` (texto de fecha aceptado por el parser del flujo)
- `slot_iso` (`YYYY-MM-DDTHH:mm:ss.sss±hh:mm`)

Opcional:

- `correo`
- `motivo_consulta`
- `titular_nombre`
- `relationship_type` (`titular`, `familiar`, `dependiente`, `otro`)

### Reagendar cita

Requerido:

- `tenant_id`
- `booking_uid`
- `slot_iso`

Opcional:

- `razon_reagendado`

### Cancelar cita

Requerido:

- `tenant_id`
- `booking_uid`

Opcional:

- `cancel_reason`

### Consultar citas existentes

Requerido:

- `tenant_id`
- `numero`
- `especialista_codigo` (opcional si la consulta es cross-specialist)

IDs normalizados recomendados en escrituras a BD (cuando sea posible):

- `source_type_id`
- `status_type_id`
- `appointment_type_id`
- `relationship_type_id`
- `policy_scope_type_id`
- `window_type_id`
- `event_type_id`
- `actor_type_id`

## 2) Guardas null-safe (en todos los escenarios)

Antes de cualquier `substring(...)`, `formatDate(...)` o request a Cal.com:

1. Validar que los campos requeridos existan y no estén vacíos.
2. Normalizar teléfono una sola vez (`numero_digits` de 10 dígitos).
3. Convertir especialista a código canónico (`dr_juan`, `dra_ana`, etc.).
4. Si falta algún dato crítico, responder con estado explícito y detener nodos downstream.

Estados recomendados:

- `MISSING_PHONE`
- `MISSING_SPECIALIST`
- `MISSING_BOOKING_UID`
- `MISSING_SLOT`
- `NO_APPOINTMENTS`
- `INVALID_PHONE_FORMAT`
- `INVALID_SLOT_FORMAT`

## 3) Estrategia SQL-first (reemplazar búsqueda frágil en Sheets)

Para lecturas robustas desde nodo PostgreSQL en Make:

- Resolver contacto por `phone_digits`.
- Resolver pacientes vinculados por `contact_patient_links`.
- Leer citas activas desde `fn_get_active_appointments_for_contact`.

Evita depender de objetos JSON ambiguos donde todo puede venir en null.

## 4) Prevención de duplicados (cross-channel + ventanas de tiempo)

Antes de crear booking:

1. Si ya conoces `booking_uid`, hacer upsert por `booking_uid`.
2. Si no, revisar duplicado candidato por:
   - `tenant_id`
   - `patient_id`
   - `specialist_id`
   - `starts_at`
3. Evaluar además política de ventana del doctor (`semana`, `mes`, `trimestre`, `X días`).
4. Si hay conflicto, devolver `DUPLICATE_APPOINTMENT` y no insertar.

Funciones SQL de apoyo:

- `fn_find_duplicate_active_appointment(...)`
- `fn_find_window_conflict_appointment(...)`

Catálogos para joins estables por ID:

- `appointment_source_types`
- `appointment_status_types`
- `appointment_types`
- `relationship_types`
- `policy_scope_types`
- `policy_window_types`
- `message_direction_types`
- `actor_types`
- `appointment_event_types`

Tabla de política por doctor:

- `specialist_duplicate_policies`
  - `window_type`: `exact_slot`, `week`, `month`, `quarter`, `rolling_days`
  - `window_days`: obligatorio solo para `rolling_days`
  - `policy_scope`: `same_specialist` o `all_specialists`

Si se bloquea por política, devolver:

- `ACTIVE_APPOINTMENT_WINDOW_CONFLICT`

## 5) Ajustes por escenario

## `CONFIRMACION_CITA.blueprint.json`

- Reemplazar branches por texto (`Juan`, `Dra`, etc.) con `especialista_codigo` canónico.
- Validar `slot_iso` antes de crear booking en Cal.com.
- Proteger correo opcional:
  - si falta, inyectar correo fallback de tenant/sede,
  - guardar bandera en metadata: `email_autofilled=true`.

## `Consultar_Citas_Existentes.blueprint.json`

- No devolver objeto con nulls como default.
- Devolver arreglo vacío o estado explícito (`NO_APPOINTMENTS`).
- Normalizar `numero` antes de filtrar; evitar dependencia fija de `substring( ;3;13 )`.

## `Consultar_Pacientes_Existentes.blueprint.json`

- Aplicar la misma normalización de teléfono.
- Si falta especialista, usar consulta cross-specialist o devolver `MISSING_SPECIALIST`.

## `Cancelar_Cita.blueprint.json`

- Guarda dura: no llamar endpoint de Cal.com si `booking_uid` está vacío.
- Interpretar éxito por HTTP status + payload esperado, no por una sola llave anidada.
- Persistir cancelación en BD aunque exista retry remoto.

## `Reagendar_Cita.blueprint.json`

- Validar salida de fecha del paso IA con regex ISO estricta antes de Cal.com.
- Si es inválida, pedir aclaración y no continuar.
- Persistir siempre evento en BD con origen y razón.

## `Recordatorio_24hr.blueprint.json`, `DR.Recordatorio_4hr.blueprint.json`, `DRA.Recordatorio_4hr.blueprint.json`

- No rutear por texto frágil del summary.
- Usar referencias estructuradas (`booking_uid`, `patient_id`, `specialist_code`) desde BD.
- Si el usuario no confirma, marcar estado de negocio explícito antes de cancelar.

## 6) Envelope sugerido de respuesta para webhooks Make

Usar envelope JSON estable en todos los webhook responders:

```json
{
  "ok": true,
  "status": "SUCCESS",
  "code": "APPOINTMENT_FOUND",
  "message": "Human-readable summary",
  "data": [],
  "error": null
}
```

Ejemplo de error:

```json
{
  "ok": false,
  "status": "ERROR",
  "code": "MISSING_BOOKING_UID",
  "message": "booking_uid is required",
  "data": null,
  "error": {
    "field": "booking_uid"
  }
}
```

## 7) Reglas operativas de no-ruptura

- Nunca hacer hard-delete de citas en flujos operativos.
- Usar transiciones de `status` + `appointment_events`.
- Mantener registros de paciente/contacto para historial y próximas citas.
- Si webhook de Cal.com llega fuera de orden, deduplicar por `external_event_id`.
