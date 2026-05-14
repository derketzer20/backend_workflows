-- =============================================================================
-- 008 — Catálogo specialist_codes y FK desde specialists
-- =============================================================================
-- Objetivo:
--   - Tabla specialist_codes: códigos canónicos por tenant (relación explícita).
--   - specialists.specialist_code_id → specialist_codes(id).
--   - Mantiene specialists.specialist_code (texto) para compatibilidad con índices
--     y seeds existentes; un trigger alinea code ↔ id en INSERT/UPDATE.
--
-- Requiere: 001_init_schema.sql, 002_omnichannel_model.sql (columna specialist_code en specialists).
-- =============================================================================

-- ---------- Catálogo ----------
create table if not exists specialist_codes (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id) on delete cascade,
  code text not null,
  display_label text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (tenant_id, code)
);

create index if not exists idx_specialist_codes_tenant
  on specialist_codes (tenant_id);

comment on table specialist_codes is
  'Códigos de especialista por tenant; specialists.specialist_code_id referencia aquí. specialists.specialist_code (texto) se sincroniza vía trigger.';

comment on column specialist_codes.code is
  'Identificador estable del doctor en este tenant (ej. dr_juan_carlos); coincide con specialists.specialist_code.';

-- ---------- FK en specialists ----------
alter table specialists
  add column if not exists specialist_code_id uuid references specialist_codes(id);

-- ---------- Poblar catálogo desde datos existentes ----------
insert into specialist_codes (tenant_id, code, display_label)
select s.tenant_id, s.specialist_code, min(s.display_name)
from specialists s
where s.specialist_code is not null
  and length(trim(s.specialist_code)) > 0
group by s.tenant_id, s.specialist_code
on conflict (tenant_id, code) do update
  set display_label = coalesce(
    nullif(excluded.display_label, ''),
    specialist_codes.display_label
  );

update specialists s
set specialist_code_id = c.id
from specialist_codes c
where c.tenant_id = s.tenant_id
  and c.code = s.specialist_code
  and s.specialist_code_id is null;

-- Solo forzar NOT NULL si no quedan filas huérfanas
do $$
begin
  if not exists (
    select 1 from specialists
    where specialist_code_id is null
      and deleted_at is null
      and specialist_code is not null
  ) then
    alter table specialists
      alter column specialist_code_id set not null;
  end if;
end;
$$;

create index if not exists idx_specialists_specialist_code_id
  on specialists (specialist_code_id)
  where deleted_at is null;

comment on column specialists.specialist_code_id is
  'FK a specialist_codes; el texto specialist_code se mantiene alineado por trigger.';

-- ---------- Trigger: resolver id desde code o code desde id ----------
create or replace function tg_specialists_link_specialist_code()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_code text;
begin
  if tg_op = 'INSERT' or tg_op = 'UPDATE' then
    if new.specialist_code_id is not null
       and (
            tg_op = 'INSERT'
            or new.specialist_code_id is distinct from old.specialist_code_id
          ) then
      select c.code into v_code
      from specialist_codes c
      where c.id = new.specialist_code_id
        and c.tenant_id = new.tenant_id;
      if v_code is not null then
        new.specialist_code := v_code;
      end if;
    elsif new.specialist_code is not null
          and length(trim(new.specialist_code)) > 0
          and (
            new.specialist_code_id is null
            or (
              tg_op = 'UPDATE'
              and new.specialist_code is distinct from old.specialist_code
            )
          ) then
      insert into specialist_codes (tenant_id, code, display_label)
      values (new.tenant_id, new.specialist_code, nullif(trim(new.display_name), ''))
      on conflict (tenant_id, code) do update
        set display_label = coalesce(
          nullif(excluded.display_label, ''),
          specialist_codes.display_label
        );
      select c.id into new.specialist_code_id
      from specialist_codes c
      where c.tenant_id = new.tenant_id
        and c.code = new.specialist_code;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_specialists_link_specialist_code on specialists;
create trigger trg_specialists_link_specialist_code
before insert or update of specialist_code, specialist_code_id, tenant_id, display_name
on specialists
for each row execute function tg_specialists_link_specialist_code();

-- Reprocesar filas ya existentes (por si specialist_code_id quedó null antes del NOT NULL)
update specialists s
set specialist_code_id = c.id
from specialist_codes c
where c.tenant_id = s.tenant_id
  and c.code = s.specialist_code
  and s.specialist_code_id is null
  and s.specialist_code is not null;
