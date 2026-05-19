-- =============================================================================
-- 022 — wa_id canónico México: 521 + 10 dígitos (WhatsApp Cloud API / BotSailor)
-- =============================================================================
-- Extiende tg_sync_contacts_phone (no un trigger nuevo).
-- phone_digits sigue siendo solo 10 dígitos locales; wa_id = 521XXXXXXXXXX.
-- =============================================================================

create or replace function normalize_wa_id_mx(raw_phone text)
returns text
language plpgsql
immutable
set search_path = public
as $$
declare
  digits text;
begin
  digits := regexp_replace(coalesce(raw_phone, ''), '\D', '', 'g');
  if digits = '' then
    return null;
  end if;
  if length(digits) > 10 then
    digits := right(digits, 10);
  end if;
  if length(digits) = 10 then
    return '521' || digits;
  end if;
  return null;
end;
$$;

comment on function normalize_wa_id_mx(text) is
  'WhatsApp wa_id MX: 521 + 10 dígitos locales (ej. 5215565062809).';

-- phone_e164 móvil MX: +521 + 10 dígitos (alineado con wa_id)
create or replace function normalize_phone_e164(raw_phone text)
returns text
language plpgsql
immutable
set search_path = public
as $$
declare
  digits text;
  local10 text;
begin
  digits := regexp_replace(coalesce(raw_phone, ''), '\D', '', 'g');
  if digits = '' then
    return null;
  end if;

  if length(digits) > 10 then
    local10 := right(digits, 10);
  else
    local10 := digits;
  end if;

  if length(local10) = 10 then
    return '+521' || local10;
  end if;

  if left(coalesce(raw_phone, ''), 1) = '+' then
    return '+' || digits;
  end if;

  return '+' || digits;
end;
$$;

create or replace function tg_sync_contacts_phone()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.wa_id := normalize_wa_id_mx(coalesce(new.wa_id, new.phone_e164, new.phone_digits));

  if new.phone_e164 is null and new.wa_id is not null then
    new.phone_e164 := normalize_phone_e164(new.wa_id);
  else
    new.phone_e164 := normalize_phone_e164(new.phone_e164);
  end if;

  new.phone_digits := normalize_phone_digits(coalesce(new.phone_e164, new.wa_id));
  return new;
end;
$$;

drop trigger if exists trg_contacts_sync_phone on contacts;
create trigger trg_contacts_sync_phone
before insert or update of phone_e164, wa_id, phone_digits on contacts
for each row execute function tg_sync_contacts_phone();

-- Backfill existentes (ejecutar una vez)
update contacts c
set
  wa_id = normalize_wa_id_mx(coalesce(c.wa_id, c.phone_e164, c.phone_digits)),
  phone_e164 = normalize_phone_e164(coalesce(c.wa_id, c.phone_e164, c.phone_digits)),
  phone_digits = normalize_phone_digits(coalesce(c.wa_id, c.phone_e164, c.phone_digits))
where c.deleted_at is null
  and normalize_wa_id_mx(coalesce(c.wa_id, c.phone_e164, c.phone_digits)) is not null;

-- Verificación rápida:
-- select id, wa_id, phone_digits, phone_e164 from contacts where deleted_at is null limit 20;
