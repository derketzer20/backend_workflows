-- =============================================================================
-- 020 — Perfiles de paciente por contacto (relación, teléfono, datos, permisos)
-- =============================================================================
-- Una fila por cada paciente asociado a un contacto (vínculo explícito o
-- paciente cuyo contact_id canónico es ese contacto).
--
-- Make / PostgREST:
--   GET .../rest/v1/v_contacto_perfiles_relacion
--       ?tenant_id=eq.<uuid>&contacto_id=eq.<uuid>
--
-- Requiere: 001, 002 (contact_patient_links, relationship_types, gender en patients).
-- =============================================================================

create or replace view v_contacto_perfiles_relacion
with (security_invoker = true)
as
with linked_patients as (
  select cpl.tenant_id, cpl.contact_id, cpl.patient_id
  from contact_patient_links cpl
  where cpl.deleted_at is null
  union
  select p.tenant_id, p.contact_id, p.id as patient_id
  from patients p
  where p.deleted_at is null
    and p.contact_id is not null
)
select
  c.id as contacto_id,
  c.tenant_id,

  c.phone_digits as contacto_telefono_10_digitos,
  c.phone_e164 as contacto_telefono_e164,
  c.wa_id as contacto_whatsapp_id,
  c.channel_primary as contacto_canal_principal,

  p.id as paciente_id,
  trim(coalesce(p.full_name, '')) as paciente_nombre_completo,
  case
    when position(' ' in trim(coalesce(p.full_name, ''))) > 0 then
      trim(substring(trim(p.full_name) from 1 for position(' ' in trim(p.full_name)) - 1))
    else trim(coalesce(p.full_name, ''))
  end as paciente_nombre,
  case
    when position(' ' in trim(coalesce(p.full_name, ''))) > 0 then
      trim(substring(trim(p.full_name) from position(' ' in trim(p.full_name)) + 1))
    else null
  end as paciente_apellidos,
  p.birth_date as paciente_fecha_nacimiento,
  p.gender as paciente_genero_codigo,
  case p.gender
    when 'male' then 'Masculino'
    when 'female' then 'Femenino'
    when 'other' then 'Otro'
    when 'unknown' then 'Sin especificar'
    else coalesce(p.gender, 'Sin especificar')
  end as paciente_genero,

  coalesce(cpl.relationship_type, case when p.contact_id = c.id then 'titular' else 'otro' end)
    as relacion_tipo_codigo,
  coalesce(rt.display_name, cpl.relationship_type_code, cpl.relationship_type, 'Titular')
    as relacion_tipo_etiqueta,
  coalesce(cpl.relationship_type_id, rt.id, case when p.contact_id = c.id then 1::smallint else null end)
    as relacion_tipo_id,
  coalesce(cpl.is_primary, p.contact_id = c.id) as relacion_es_vinculo_primario,
  (coalesce(cpl.relationship_type, case when p.contact_id = c.id then 'titular' else 'otro' end) = 'titular')
    as relacion_es_titular,

  coalesce(cpl.can_manage_appointments, true) as puede_gestionar_citas,
  coalesce(cpl.can_manage_appointments, true) as puede_crear_citas,

  cpl.id as vinculo_id,
  cpl.notes as vinculo_notas,
  p.contact_id as paciente_contacto_canonico_id,
  (p.contact_id = c.id) as paciente_es_contacto_canonico

from linked_patients lp
join contacts c
  on c.id = lp.contact_id
 and c.tenant_id = lp.tenant_id
 and c.deleted_at is null
join patients p
  on p.id = lp.patient_id
 and p.tenant_id = lp.tenant_id
 and p.deleted_at is null
left join contact_patient_links cpl
  on cpl.tenant_id = lp.tenant_id
 and cpl.contact_id = lp.contact_id
 and cpl.patient_id = lp.patient_id
 and cpl.deleted_at is null
left join relationship_types rt
  on rt.id = coalesce(
    cpl.relationship_type_id,
    (
      select r.id
      from relationship_types r
      where r.code = lower(
        coalesce(
          cpl.relationship_type,
          case when p.contact_id = c.id then 'titular' else 'otro' end
        )
      )
      limit 1
    )
  );

comment on view v_contacto_perfiles_relacion is
  'Por contacto: teléfonos, tipo de relación (catálogo), datos del paciente y si puede gestionar/crear citas (can_manage_appointments).';

grant select on v_contacto_perfiles_relacion to authenticated, service_role;
