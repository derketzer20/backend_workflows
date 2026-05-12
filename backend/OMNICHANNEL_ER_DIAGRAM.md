# Diagrama ER Omnicanal (PostgreSQL)

Este diagrama refleja lo que acabamos de implementar en `002_omnichannel_model.sql`, incluyendo:

- modelo entidad-relación principal,
- políticas de bloqueo de citas activas por ventana de tiempo,
- auditoría de eventos.

## 1) Modelo entidad-relación principal (con atributos y catálogos)

```mermaid
erDiagram
    TENANTS {
        uuid id PK
        text name
        timestamptz created_at
    }

    LOCATIONS {
        uuid id PK
        uuid tenant_id FK
        text code
        text display_name
        text timezone
        text country_code
        text state_code
        text city
        boolean active
        jsonb metadata
        timestamptz created_at
        timestamptz updated_at
        timestamptz deleted_at
    }

    SPECIALISTS {
        uuid id PK
        uuid tenant_id FK
        uuid location_id FK
        text specialist_code
        text specialist_key
        text display_name
        text timezone
        text email
        text phone_e164
        text calcom_event_type_id
        timestamptz created_at
        timestamptz updated_at
        timestamptz deleted_at
    }

    CONTACTS {
        uuid id PK
        uuid tenant_id FK
        text wa_id
        text chat_id
        text phone_e164
        text phone_digits
        text channel_primary
        jsonb metadata
        timestamptz first_seen_at
        timestamptz last_seen_at
        timestamptz deleted_at
    }

    PATIENTS {
        uuid id PK
        uuid tenant_id FK
        uuid contact_id FK
        text full_name
        date birth_date
        text gender
        text email
        text phone_e164
        text phone_digits
        jsonb metadata
        timestamptz created_at
        timestamptz updated_at
        timestamptz deleted_at
    }

    CONTACT_PATIENT_LINKS {
        uuid id PK
        uuid tenant_id FK
        uuid contact_id FK
        uuid patient_id FK
        smallint relationship_type_id FK
        text relationship_type
        boolean can_manage_appointments
        boolean is_primary
        text notes
        timestamptz created_at
        timestamptz updated_at
        timestamptz deleted_at
    }

    APPOINTMENTS {
        uuid id PK
        uuid tenant_id FK
        uuid specialist_id FK
        uuid patient_id FK
        uuid location_id FK
        smallint source_type_id FK
        smallint status_type_id FK
        smallint appointment_type_id FK
        text source
        text channel_ref
        text booking_uid
        timestamptz starts_at
        timestamptz ends_at
        text status
        text reason
        text cancel_reason
        text created_by
        boolean pending_titular
        jsonb metadata
        timestamptz created_at
        timestamptz updated_at
        timestamptz deleted_at
    }

    APPOINTMENT_EVENTS {
        uuid id PK
        uuid tenant_id FK
        uuid appointment_id FK
        smallint source_type_id FK
        smallint actor_type_id FK
        smallint event_type_id FK
        text source
        text event_type
        text external_ref
        text external_event_id
        text actor_type
        text actor_ref
        jsonb raw_payload
        timestamptz created_at
    }

    CHANNEL_MESSAGES {
        uuid id PK
        uuid tenant_id FK
        uuid contact_id FK
        uuid patient_id FK
        uuid appointment_id FK
        smallint source_type_id FK
        smallint direction_type_id FK
        text source
        text direction
        text external_message_id
        jsonb payload
        timestamptz created_at
    }

    SPECIALIST_DUPLICATE_POLICIES {
        uuid id PK
        uuid tenant_id FK
        uuid specialist_id FK
        smallint policy_scope_type_id FK
        smallint window_type_id FK
        text policy_scope
        text window_type
        int window_days
        text[] enforce_for_sources
        boolean active
        boolean allow_override_by_staff
        timestamptz created_at
        timestamptz updated_at
        timestamptz deleted_at
    }

    APPOINTMENT_SOURCE_TYPES {
        smallint id PK
        text code
        text display_name
    }

    APPOINTMENT_STATUS_TYPES {
        smallint id PK
        text code
        text display_name
        boolean is_active_status
    }

    APPOINTMENT_TYPES {
        smallint id PK
        text code
        text display_name
        boolean active
    }

    RELATIONSHIP_TYPES {
        smallint id PK
        text code
        text display_name
    }

    POLICY_SCOPE_TYPES {
        smallint id PK
        text code
        text display_name
    }

    POLICY_WINDOW_TYPES {
        smallint id PK
        text code
        text display_name
        boolean requires_days
    }

    MESSAGE_DIRECTION_TYPES {
        smallint id PK
        text code
        text display_name
    }

    ACTOR_TYPES {
        smallint id PK
        text code
        text display_name
    }

    APPOINTMENT_EVENT_TYPES {
        smallint id PK
        text code
        text display_name
    }

    TENANTS ||--o{ LOCATIONS : tiene
    TENANTS ||--o{ SPECIALISTS : tiene
    TENANTS ||--o{ CONTACTS : tiene
    TENANTS ||--o{ PATIENTS : tiene
    TENANTS ||--o{ APPOINTMENTS : tiene
    TENANTS ||--o{ APPOINTMENT_EVENTS : tiene
    TENANTS ||--o{ CHANNEL_MESSAGES : tiene
    TENANTS ||--o{ CONTACT_PATIENT_LINKS : tiene
    TENANTS ||--o{ SPECIALIST_DUPLICATE_POLICIES : configura

    LOCATIONS ||--o{ SPECIALISTS : asigna
    LOCATIONS ||--o{ APPOINTMENTS : aloja

    CONTACTS ||--o{ CONTACT_PATIENT_LINKS : vincula
    PATIENTS ||--o{ CONTACT_PATIENT_LINKS : vincula

    CONTACTS ||--o{ PATIENTS : contacto_principal

    PATIENTS ||--o{ APPOINTMENTS : agenda
    SPECIALISTS ||--o{ APPOINTMENTS : atiende

    APPOINTMENTS ||--o{ APPOINTMENT_EVENTS : registra
    APPOINTMENTS ||--o{ CHANNEL_MESSAGES : relacionado

    CONTACTS ||--o{ CHANNEL_MESSAGES : envia_recibe
    PATIENTS ||--o{ CHANNEL_MESSAGES : relacionado

    SPECIALISTS ||--o| SPECIALIST_DUPLICATE_POLICIES : politica_activa

    APPOINTMENT_SOURCE_TYPES ||--o{ APPOINTMENTS : source_type_id
    APPOINTMENT_STATUS_TYPES ||--o{ APPOINTMENTS : status_type_id
    APPOINTMENT_TYPES ||--o{ APPOINTMENTS : appointment_type_id
    RELATIONSHIP_TYPES ||--o{ CONTACT_PATIENT_LINKS : relationship_type_id
    POLICY_SCOPE_TYPES ||--o{ SPECIALIST_DUPLICATE_POLICIES : policy_scope_type_id
    POLICY_WINDOW_TYPES ||--o{ SPECIALIST_DUPLICATE_POLICIES : window_type_id
    APPOINTMENT_SOURCE_TYPES ||--o{ CHANNEL_MESSAGES : source_type_id
    MESSAGE_DIRECTION_TYPES ||--o{ CHANNEL_MESSAGES : direction_type_id
    APPOINTMENT_SOURCE_TYPES ||--o{ APPOINTMENT_EVENTS : source_type_id
    ACTOR_TYPES ||--o{ APPOINTMENT_EVENTS : actor_type_id
    APPOINTMENT_EVENT_TYPES ||--o{ APPOINTMENT_EVENTS : event_type_id
```

## 2) Lógica de bloqueo por periodo (semana/mes/trimestre/X días)

```mermaid
flowchart TD
    CreateOrUpdate[Crear o actualizar cita] --> ActiveCheck{Estado activo y no eliminada}
    ActiveCheck -->|No| Allow[Permitir escritura]
    ActiveCheck -->|Si| PolicyLookup[Cargar specialist_duplicate_policies]
    PolicyLookup --> PolicyFound{Politica activa encontrada}
    PolicyFound -->|No| Allow
    PolicyFound -->|Si| WindowCalc[Calcular ventana segun politica]
    WindowCalc --> WindowType{window_type}
    WindowType -->|exact_slot| Exact[Coincidencia exacta de starts_at]
    WindowType -->|week| Week[date_trunc semana]
    WindowType -->|month| Month[date_trunc mes]
    WindowType -->|quarter| Quarter[date_trunc trimestre]
    WindowType -->|rolling_days| Rolling[starts_at hasta starts_at + window_days]
    Exact --> ConflictCheck[Buscar conflictos activos]
    Week --> ConflictCheck
    Month --> ConflictCheck
    Quarter --> ConflictCheck
    Rolling --> ConflictCheck
    ConflictCheck --> HasConflict{Existe conflicto}
    HasConflict -->|Si| Block[Lanzar ACTIVE_APPOINTMENT_WINDOW_CONFLICT]
    HasConflict -->|No| Allow
```

## 3) Reglas clave implementadas

- Unicidad técnica por `booking_uid` (cuando existe).
- Guard de duplicado exacto para citas activas.
- Política configurable por doctor:
  - `exact_slot`
  - `week`
  - `month`
  - `quarter`
  - `rolling_days`
- Alcance de política:
  - `same_specialist`
  - `all_specialists`
- Soft delete con `deleted_at`.
- Auditoría inmutable en `appointment_events`.


