-- =============================================================================
-- 026 — Tabla appointment_reminder_dispatches (si no existía en el proyecto)
-- =============================================================================
-- fn_dispatch_appointment_reminders (023) inserta aquí DESPUÉS de net.http_post.
-- Solo cuando encuentra al menos una cita en ventana (retorno >= 1).
-- =============================================================================

create table if not exists appointment_reminder_dispatches (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  appointment_id uuid not null references appointments(id) on delete cascade,
  reminder_kind text not null check (reminder_kind in ('24h', '4h')),
  sent_at timestamptz not null default now(),
  external_ref text,
  unique (appointment_id, reminder_kind)
);

create index if not exists idx_reminder_dispatches_sent_at
  on appointment_reminder_dispatches (sent_at);

create index if not exists idx_reminder_dispatches_appointment
  on appointment_reminder_dispatches (appointment_id, reminder_kind);

comment on table appointment_reminder_dispatches is
  'Un registro por cita y tipo (24h/4h) tras envío exitoso en fn_dispatch; evita duplicados.';

-- ---------- Validar que la función desplegada hace INSERT ----------
-- select prosrc like '%appointment_reminder_dispatches%' as tiene_insert
-- from pg_proc where proname = 'fn_dispatch_appointment_reminders';
