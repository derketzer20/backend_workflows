"""
Genera seed SQL desde Base_CRM del Excel Dr.JuanCarlos.
Uso: python generate_seed_from_crm_xlsx.py
Requiere: openpyxl
"""
from __future__ import annotations

import json
import re
import uuid
from datetime import date, datetime, timedelta
from pathlib import Path

from openpyxl import load_workbook

NS = uuid.UUID("6ba7b810-9dad-11d1-80b4-00c04fd430c8")


def uid(key: str) -> str:
    return str(uuid.uuid5(NS, key))


def only_digits(v) -> str:
    if v is None:
        return ""
    s = str(v).strip()
    if s.endswith(".0"):
        s = s[:-2]
    return re.sub(r"\D", "", s)


def norm_mx_phone(raw) -> tuple[str | None, str | None]:
    """(phone_digits_10, phone_e164) o (None, None)."""
    d = only_digits(raw)
    if not d:
        return None, None
    if len(d) == 13 and d.startswith("521"):
        d = d[3:]
    elif len(d) == 12 and d.startswith("52"):
        d = d[2:]
    elif len(d) == 11 and d.startswith("1") and len(d) == 11:
        d = d[1:]
    if len(d) == 9:
        d = "8" + d
    if len(d) != 10:
        return None, None
    return d, "+52" + d


def parse_fecha_cita(v) -> datetime | None:
    if v is None or (isinstance(v, float) and str(v) == "nan"):
        return None
    if isinstance(v, datetime):
        return v
    s = str(v).strip()
    if not s or s.lower() == "none":
        return None
    s = s.replace("262026", "2026")
    fmts = [
        "%Y-%m-%d %I:%M %p",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%dT%H:%M:%S.%f",
        "%Y-%m-%d %H:%M:%S",
    ]
    for f in fmts:
        try:
            return datetime.strptime(s, f)
        except ValueError:
            continue
    return None


def parse_birth(v) -> date | None:
    if v is None or str(v).strip() == "":
        return None
    if isinstance(v, datetime):
        return v.date()
    if isinstance(v, date):
        return v
    s = str(v).strip()
    s = s.replace("262026", "2026")
    for fmt in (
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%d",
        "%d-%m-%Y",
        "%d/%m/%Y",
    ):
        try:
            return datetime.strptime(s[:19], fmt).date()
        except ValueError:
            pass
    months_es = {
        "enero": 1,
        "febrero": 2,
        "marzo": 3,
        "abril": 4,
        "mayo": 5,
        "junio": 6,
        "julio": 7,
        "agosto": 8,
        "septiembre": 9,
        "octubre": 10,
        "noviembre": 11,
        "diciembre": 12,
    }
    m = re.search(
        r"(\d{1,2})\s+de\s+(\w+)\s+del?\s+(\d{4})", s, re.I
    ) or re.search(r"(\d{1,2})[-/](\w+)[-/](\d{2,4})", s, re.I)
    if m:
        try:
            day = int(m.group(1))
            mo = m.group(2).lower()
            month = None
            for name, num in months_es.items():
                if name.startswith(mo[: min(len(mo), 4)]):
                    month = num
                    break
            if month is None and mo.isdigit():
                month = int(mo)
            if month is None:
                return None
            year = int(m.group(3))
            if year < 100:
                year += 1900 if year > 30 else 2000
            return date(year, month, day)
        except (ValueError, IndexError):
            pass
    m2 = re.match(r"(\d{1,2})\s+(\w+)\s+(\d{2,4})", s, re.I)
    if m2:
        return parse_birth(
            f"{m2.group(1)}-{m2.group(2)}-{m2.group(3)}"
        )
    return None


def parse_numero_citas(v) -> int | None:
    if v is None or str(v).strip() == "":
        return None
    try:
        n = int(float(v))
        return n if n >= 0 else None
    except (TypeError, ValueError):
        return None


def merge_rol_paciente(rows: list[dict]) -> tuple[str, int, str]:
    """
    Deriva vínculo contacto–paciente desde columna rol_paciente del CRM.
    Catálogo: 1 titular, 2 familiar, 3 dependiente, 4 otro.
    """
    codes: list[str] = []
    for rb in rows:
        r = (rb.get("rol_paciente") or "").strip().lower()
        if r:
            codes.append(r)
    if not codes:
        return "titular", 1, "titular"
    joined = " ".join(codes)
    if "depend" in joined:
        return "dependiente", 3, "dependiente"
    if "familiar" in joined or "familia" in joined:
        return "familiar", 2, "familiar"
    if "otro" in joined:
        return "otro", 4, "otro"
    if "titular" in joined:
        return "titular", 1, "titular"
    return "titular", 1, "titular"


def map_status(fase: str | None, etiqueta: str | None) -> tuple[str, int]:
    e = (etiqueta or "").strip().lower()
    f = (fase or "").strip().lower()
    if "cancel" in e:
        return "cancelled", 4
    if "confirm" in f or "confirm" in e:
        return "confirmed", 2
    if f == "retencion" or "seguimiento" in e:
        return "confirmed", 2
    return "pending", 1


def esc_sql(s: str | None) -> str:
    if s is None:
        return "NULL"
    return "'" + str(s).replace("'", "''") + "'"


def main():
    xlsx = Path(r"c:\Users\Yareli\Downloads\Dr.JuanCarlos (1).xlsx")
    root = Path(__file__).resolve().parents[1]
    out_sql = root / "seed_dr_juan_monterrey_from_crm.sql"
    out_preview = root / "seed_dr_juan_monterrey_PREVIEW.json"

    wb = load_workbook(xlsx, data_only=True)
    ws = wb["Base_CRM"]
    rows = list(ws.iter_rows(values_only=True))
    hdr = list(rows[0])
    ix = {h: i for i, h in enumerate(hdr) if h}

    raw_rows = []
    for r in rows[1:]:
        if not r:
            continue
        tel = r[ix["telefono"]] if "telefono" in ix else None
        nom = r[ix["nombre_paciente"]] if "nombre_paciente" in ix else None
        if tel is None and nom is None:
            continue
        if str(tel).strip() == "" and str(nom).strip() == "":
            continue
        row = {k: r[i] for k, i in ix.items()}
        raw_rows.append(row)
    wb.close()

    tenant_id = uid("tenant|esmart360|monterrey")
    location_id = uid("location|monterrey|principal")
    specialist_id = uid("specialist|dr_juan_carlos")

    by_phone: dict[str, dict] = {}
    order_keys: list[str] = []

    for row in raw_rows:
        pd, pe = norm_mx_phone(row.get("telefono"))
        if pd is None:
            continue
        if pd not in by_phone:
            order_keys.append(pd)
            by_phone[pd] = {"phone_digits": pd, "phone_e164": pe, "names": [], "rows": []}
        nm = (row.get("nombre_paciente") or "").strip()
        full = (row.get("nombre_completo_titular") or "").strip()
        by_phone[pd]["names"].append(nm or full)
        by_phone[pd]["rows"].append(row)

    contacts_out = []
    patients_out = []
    appts_out = []

    for pd in order_keys:
        bucket = by_phone[pd]
        rows_b = bucket["rows"]
        best_name = max(
            [n for n in bucket["names"] if n],
            key=len,
            default=(rows_b[0].get("nombre_paciente") or "Sin nombre"),
        )
        email = None
        birth = None
        max_num_citas = None
        for rb in rows_b:
            if rb.get("correo_titular"):
                em = str(rb["correo_titular"]).strip()
                if em and "@" in em and "help@e-smart360.com" not in em.lower():
                    email = em
            bd = parse_birth(rb.get("fecha_nacimiento"))
            if bd:
                birth = bd
            nc = parse_numero_citas(rb.get("numero_citas"))
            if nc is not None:
                max_num_citas = nc if max_num_citas is None else max(max_num_citas, nc)

        rel_type, rel_type_id, rel_code = merge_rol_paciente(rows_b)

        pe = bucket["phone_e164"]
        wa = "521" + pd
        cid = uid("contact|" + pd)
        pid = uid("patient|" + pd)

        patient_meta: dict = {
            "import": "Dr.JuanCarlos Base_CRM",
            "crm_rol_paciente": rel_code,
        }
        if max_num_citas is not None:
            patient_meta["crm_numero_citas"] = max_num_citas
            patient_meta["crm_numero_citas_nota"] = (
                "Contador CRM/Sheets; no implica N filas en appointments. "
                "Historial detallado solo si el export trae fechas por cita. "
                "Cache 004: cita activa = pending|confirmed|rescheduled y slot no terminado "
                "(ends_at > ahora; si falta ends usar script 006 o ends = starts + 30 min)."
            )

        contacts_out.append(
            {
                "id": cid,
                "phone_digits": pd,
                "phone_e164": pe,
                "wa_id": wa,
                "metadata": {"import": "Dr.JuanCarlos Base_CRM"},
            }
        )
        patients_out.append(
            {
                "id": pid,
                "contact_id": cid,
                "full_name": best_name,
                "birth_date": str(birth) if birth else None,
                "email": email,
                "metadata": patient_meta,
                "relationship_type": rel_type,
                "relationship_type_id": rel_type_id,
                "relationship_type_code": rel_code,
            }
        )

        seen_booking: set[str] = set()
        for rb in rows_b:
            dt = parse_fecha_cita(rb.get("fecha_cita"))
            bu = rb.get("bookingUid")
            if isinstance(bu, float) and bu == int(bu):
                bu = str(int(bu))
            elif bu is not None:
                bu = str(bu).strip() or None
            if dt is None:
                continue
            if bu and bu in seen_booking:
                continue
            if bu:
                seen_booking.add(bu)
            status, stid = map_status(
                str(rb.get("fase_general") or ""),
                str(rb.get("etiqueta_subfase") or ""),
            )
            starts = dt
            ends = starts + timedelta(minutes=30)
            aid = uid("appt|" + pd + "|" + (bu or starts.strftime("%Y%m%d%H%M")))
            appts_out.append(
                {
                    "id": aid,
                    "patient_id": pid,
                    "starts_local": starts.strftime("%Y-%m-%d %H:%M:%S"),
                    "ends_local": ends.strftime("%Y-%m-%d %H:%M:%S"),
                    "booking_uid": bu,
                    "status": status,
                    "status_type_id": stid,
                    "reason": rb.get("motivo_contacto_directo"),
                }
            )

    preview = {
        "fuente": str(xlsx),
        "hoja": "Base_CRM",
        "filas_crm_con_datos": len(raw_rows),
        "notas_normalizacion": [
            "Teléfonos a 10 dígitos; wa_id WhatsApp MX típico 521 + dígitos.",
            "9 dígitos (613294675) → prefijo 8 → 8613294675 (revisa si era otro dígito/lada).",
            "Citas en tabla appointments: solo cuando fecha_cita es parseable (no se inventan fechas por visitas pasadas).",
            "numero_citas del CRM → patients.metadata.crm_numero_citas (máximo por teléfono); no crea citas pasadas sin fecha.",
            "rol_paciente (titular/familiar/…): se refleja en contact_patient_links + metadata.crm_rol_paciente.",
            "Cache 004: pending|confirmed|rescheduled y ends_at > ahora (o sin ends_at y starts_at futuro); normalizar ends con backend/sql/006_normalize_appointment_intervals.sql.",
            "Con migración 004: patients.last/next/active_appointment_count + vista v_patients_with_contact_role.",
            "Correo help@e-smart360.com omitido como email de paciente.",
            "starts_at/ends_at interpretados en America/Monterrey.",
        ],
        "tenants": [{"id": tenant_id, "name": "CorpOS Monterrey"}],
        "locations": [
            {
                "id": location_id,
                "code": "MTY-01",
                "display_name": "Monterrey — Consultorio principal",
                "timezone": "America/Monterrey",
            }
        ],
        "specialists": [
            {
                "id": specialist_id,
                "specialist_key": "dr",
                "specialist_code": "dr_juan_carlos",
                "display_name": "Dr. Juan Carlos",
            }
        ],
        "contacts": contacts_out,
        "patients": patients_out,
        "contact_patient_links": [
            {
                "contact_id": p["contact_id"],
                "patient_id": p["id"],
                "relationship_type": p["relationship_type"],
                "relationship_type_id": p["relationship_type_id"],
            }
            for p in patients_out
        ],
        "appointments": appts_out,
    }

    lines = [
        "-- Seed: Dr.JuanCarlos (1).xlsx → Base_CRM (solo filas con teléfono válido MX 10 dígitos)",
        "-- Ejecutar DESPUÉS de: 001_init_schema.sql, 002_omnichannel_model.sql, 004_patient_appointment_cache.sql",
        "-- (003 opcional). 004 mantiene last/next/active en patients vía trigger al insertar citas.",
        "",
        "begin;",
        "",
        f"insert into tenants (id, name) values ('{tenant_id}', 'CorpOS Monterrey') on conflict (id) do nothing;",
        "",
        f"insert into locations (id, tenant_id, code, display_name, timezone, city, country_code)",
        f"values ('{location_id}', '{tenant_id}', 'MTY-01', 'Monterrey — Consultorio principal', 'America/Monterrey', 'Monterrey', 'MX')",
        "on conflict (tenant_id, code) do nothing;",
        "",
        "insert into specialists (id, tenant_id, specialist_key, display_name, timezone, specialist_code, location_id)",
        f"values ('{specialist_id}', '{tenant_id}', 'dr', 'Dr. Juan Carlos', 'America/Monterrey', 'dr_juan_carlos', '{location_id}')",
        "on conflict (tenant_id, specialist_code) where deleted_at is null do update set",
        "  display_name = excluded.display_name,",
        "  specialist_code = excluded.specialist_code,",
        "  location_id = excluded.location_id,",
        "  updated_at = now();",
        "",
        "insert into specialist_duplicate_policies (tenant_id, specialist_id, policy_scope, window_type, active)",
        f"select '{tenant_id}', '{specialist_id}', 'same_specialist', 'exact_slot', true",
        "where not exists (",
        "  select 1 from specialist_duplicate_policies p",
        f"  where p.tenant_id = '{tenant_id}'::uuid and p.specialist_id = '{specialist_id}'::uuid",
        "    and p.deleted_at is null and p.active = true",
        ");",
        "",
    ]

    for c in contacts_out:
        meta = esc_sql(json.dumps(c["metadata"], ensure_ascii=False))
        lines.append(
            f"insert into contacts (id, tenant_id, wa_id, phone_e164, phone_digits, channel_primary, metadata) values ("
            f"'{c['id']}', '{tenant_id}', {esc_sql(c['wa_id'])}, {esc_sql(c['phone_e164'])}, "
            f"{esc_sql(c['phone_digits'])}, 'whatsapp', {meta}::jsonb) on conflict (id) do nothing;"
        )

    for p in patients_out:
        bd = f"{esc_sql(p['birth_date'])}::date" if p["birth_date"] else "NULL"
        em = esc_sql(p["email"]) if p["email"] else "NULL"
        pmeta = esc_sql(json.dumps(p["metadata"], ensure_ascii=False))
        lines.append(
            f"insert into patients (id, tenant_id, contact_id, full_name, birth_date, email, metadata) values ("
            f"'{p['id']}', '{tenant_id}', '{p['contact_id']}', {esc_sql(p['full_name'])}, {bd}, {em}, {pmeta}::jsonb) "
            f"on conflict (id) do nothing;"
        )

    for p in patients_out:
        rt = p["relationship_type"]
        rid = p["relationship_type_id"]
        rcode = p["relationship_type_code"]
        is_primary = "true" if rt == "titular" else "false"
        lines.append(
            "insert into contact_patient_links (tenant_id, contact_id, patient_id, relationship_type, is_primary, relationship_type_id, relationship_type_code) "
            f"select '{tenant_id}', '{p['contact_id']}', '{p['id']}', '{rt}', {is_primary}, {rid}, '{rcode}' "
            "where not exists (select 1 from contact_patient_links l "
            f"where l.contact_id = '{p['contact_id']}'::uuid and l.patient_id = '{p['id']}'::uuid and l.deleted_at is null);"
        )

    for a in appts_out:
        bu = esc_sql(a["booking_uid"]) if a["booking_uid"] else "NULL"
        sl = a["starts_local"].replace("'", "''")
        el = a["ends_local"].replace("'", "''")
        rs = esc_sql(a["reason"]) if a["reason"] else "NULL"
        lines.append(
            "insert into appointments (id, tenant_id, specialist_id, patient_id, location_id, "
            "source, source_type_id, status, status_type_id, appointment_type_id, booking_uid, starts_at, ends_at, reason, metadata) values ("
            f"'{a['id']}', '{tenant_id}', '{specialist_id}', '{a['patient_id']}', '{location_id}', "
            f"'whatsapp', 1, '{a['status']}', {a['status_type_id']}, 1, {bu}, "
            f"('{sl}'::timestamp AT TIME ZONE 'America/Monterrey'), "
            f"('{el}'::timestamp AT TIME ZONE 'America/Monterrey'), "
            f"{rs}, '{{\"import\":\"crm_xlsx\"}}'::jsonb) on conflict (id) do nothing;"
        )

    lines.extend(
        [
            "",
            "-- Refrescar cache de citas por paciente (idempotente; cubre pacientes sin citas)",
            "do $$",
            "declare",
            "  r record;",
            "begin",
            f"  for r in select id from patients where tenant_id = '{tenant_id}'::uuid and deleted_at is null",
            "  loop",
            "    perform fn_recompute_patient_appointment_cache(r.id);",
            "  end loop;",
            "end $$;",
            "",
            "commit;",
        ]
    )

    out_sql.write_text("\n".join(lines) + "\n", encoding="utf-8")
    out_preview.write_text(
        json.dumps(preview, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print("Wrote", out_sql)
    print("Wrote", out_preview, "| contacts", len(contacts_out), "appts", len(appts_out))


if __name__ == "__main__":
    main()
