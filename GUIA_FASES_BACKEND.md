# Guia fase por fase (agenda conversacional)

## Donde compartir claves de forma segura

No compartas claves en el chat.

1. Crea este archivo local en tu maquina:
   - `c:\workflowsBackendesmart360\.env.local`
2. Copia el contenido de `c:\workflowsBackendesmart360\.env.example`.
3. Reemplaza los valores `replace_me` con tus claves reales.
4. No subas ese archivo al repositorio (ya esta bloqueado en `.gitignore`).

## Fase 0 - Preparacion y seguridad (hoy)

Que haremos:
- Definir variables y llaves por entorno.
- Congelar inventario de endpoints actuales (Dr y Dra).
- Confirmar webhooks de Cal.com y eventos activos.

Resultado:
- Base segura para iniciar pruebas sin exponer credenciales.

## Fase 1 - Nucleo de datos (Postgres)

Que haremos:
- Crear tablas de `contacts`, `patients`, `appointments`, `appointment_events`, `bot_sessions`.
- Definir estados de cita: `pending`, `confirmed`, `rescheduled`, `cancelled`, `no_show`.
- Guardar `source` de entrada: `whatsapp`, `voice_dialora`, `calcom_web`.

Orden de migracion (ejecutar en la misma base, una sola vez por entorno):
1. `backend/sql/001_init_schema.sql` — nucleo multi-tenant, **tablas de catalogo** (semilla incluida) y columnas `*_type_id` en `appointments` / `appointment_events` enlazadas a esos catalogos.
2. `backend/sql/002_omnichannel_model.sql` — sedes, vinculos contacto-paciente, catálogos por ID, politicas de duplicados por ventana, normalizacion de telefono, vistas (`v_active_appointments`, `v_contact_active_appointments`), funciones (`fn_get_active_appointments_for_contact`, cancelar/reagendar por `booking_uid`, deteccion de duplicados) y trigger de enforcement.
3. `backend/sql/003_booking_validation_api.sql` — vista y funciones de solo lectura para validar paciente/contacto, doctor de la cita y pre-chequeo de duplicados antes de llamar a Cal.com.
4. `backend/sql/004_patient_appointment_cache.sql` — columnas en `patients` (ultima cita, siguiente cita, conteo citas activas, flag `has_active` alineado a proxima cita), trigger que recalcula desde `appointments`, vista `v_patients_with_contact_role` (titular/familiar con telefono). Documentacion: `backend/sql/DOC_cache_agenda_patients.md`.
5. `backend/sql/005_regularize_patient_appointment_cache.sql` — (opcional) asegura columnas y cache en entornos parciales; idempotente.
6. `backend/sql/006_normalize_appointment_intervals.sql` — (opcional) corrige `ends_at` faltantes o invalidos antes de confiar en `active_appointment_count`.
7. `backend/sql/007_fix_has_active_proxima_cita.sql` — **solo si la base ya tenia 004 antigua** con `has_active_appointment` **generada** como `(active_appointment_count > 0)`; aplica semantica nueva (has = proxima cita) + backfill.
8. `backend/sql/008_specialist_codes_fk.sql` — catálogo `specialist_codes` y FK `specialists.specialist_code_id` (trigger mantiene `specialist_code` texto alineado).

Resultado:
- Fuente de verdad unica (ya no Google Sheets como base principal).

## Fase 2 - Backend API base

Que haremos:
- Crear endpoint principal de conversacion: `POST /chat/step`.
- Crear endpoints de agenda: consultar, agendar, cancelar, reagendar.
- Estandarizar respuestas con `message` humano + `code` tecnico.

Resultado:
- BotSailor puede seguir usando HTTP API, pero la logica vive en backend.

## Fase 3 - Integracion Cal.com

Que haremos:
- Recibir eventos webhook de Dr y Dra.
- Aplicar idempotencia por `bookingUid` + tipo de evento.
- Sincronizar la cita en BD y disparar acciones de negocio.

Resultado:
- Las citas creadas por web de Cal.com quedan unificadas en el mismo sistema.

## Fase 4 - Integracion BotSailor (sin romper operacion)

Que haremos:
- Mantener BotSailor como capa de canal WhatsApp.
- Reducir workflows duros y pasar decisiones al backend.
- Mostrar respuestas conversacionales usando variable `message`.

Resultado:
- Menos dependencia de botones/listas dinamicas y mas conversacion natural.

## Fase 5 - IA para ambiguedad y validacion

Que haremos:
- Interpretar lenguaje natural (ej. "el proximo viernes por la tarde").
- Detectar fuera de contexto y redirigir con mensajes claros.
- Validar que la eleccion del usuario exista en slots reales.

Resultado:
- Conversaciones mas robustas, con menos errores por entradas ambiguas.

## Fase 6 - Dashboard operativo

Que haremos:
- Crear panel para doctor/recepcion:
  - Citas hoy
  - Reagendadas/canceladas/no-show
  - Pacientes por numero
  - Alertas de errores

Resultado:
- Visibilidad total de operacion y mejor servicio al cliente.

## Fase 7 - Escalado multi-clinica

Que haremos:
- Plantilla replicable por tenant/doctor.
- Variables por cliente sin duplicar logica.
- Trazabilidad y monitoreo por cuenta.

Resultado:
- Solucion lista para crecer con mas clientes sin romper arquitectura.
