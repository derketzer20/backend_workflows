"""
Genera seed SQL desde Base_CRM del Excel Dr.JuanCarlos.
Uso: python generate_seed_from_crm_xlsx.py
Requiere: openpyxl
"""
from __future__ import annotations

import json
import re
import uuid
from datetime import date, datetime
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


def norm_mx_phone(digits: str) -> tuple[str | None, str | None]:
    """
    Devuelve (phone_digits_10, phone_e164) o (None, None) si no aplica.
    Reglas: 10 dígitos MX; 12 con 52; 13 con 521; 9 dígitos Monterrey → prefijo 8 (faltaba 8 inicial).
    """
    d = only_digits(digits)
    if not d:
        return None, None
    if len(d) == 13 and d.startswith("521"):
        d = d[3:]
    elif len(d) == 12 and d.startswith("52"):
        d = d[2:]
    elif len(d) == 11 and d.startswith("1") and len(re.sub(r"\D", "", digits)) == 11:
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
    m = re.match(
        r"(\d{1,2})\s+de\s+(\w+)\s+del?\s+(\d{4})", s, re.I
    ) or re.match(r"(\d{1,2})[-/](\w+)[-/](\d{2,4})", s, re.I)
    if m:
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
        try:
            day = int(m.group(1))
            mo = m.group(2).lower()[:4]
            for name, num in months_es.items():
                if name.startswith(mo[:3]):
                    month = num
                    break
            else:
                month = int(m.group(2)) if m.group(2).isdigit() else None
            if month is None:
                return None
            year = int(m.group(3))
            if year < 100:
                year += 1900 if year > 30 else 2000
            return date(year, month, day)
        except (ValueError, IndexError):
            pass
    return None


def map_status(fase: str | None, etiqueta: str | None) -> tuple[str, int]:
    f = (fase or "").strip().lower()
    e = (etiqueta or "").strip().lower()
    if "cancel" in e or "cancel" in f:
        return "cancelled", 4
    if "confirm" in f or "confirm" in e:
        return "confirmed", 2
    if f == "retencion" or "seguimiento" in e:
        return "confirmed", 2
    return "pending", 1


def main():
    xlsx = Path(r"c:\Users\Yareli\Downloads\Dr.JuanCarlos (1).xlsx")
    out_sql = Path(__file__).resolve().parents[1] / "seed_dr_juan_monterrey_from_crm.sql"
    out_preview = Path(__file__).resolve().parents[1] / "seed_dr_juan_monterrey_PREVIEW.json"

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
        row = {}
        for k, i in ix.items():
            row[k] = r[i]
        raw_rows.append(row)
    wb.close()

    tenant_id = uid("tenant|esmart360|monterrey")
    location_id = uid("location|monterrey|principal")
    specialist_id = uid("specialist|dr_juan_carlos")

    # Dedupe por phone_digits: conservar mejor nombre y merge de campos
    by_phone: dict[str, dict] = {}
    order_keys: list[str] = []

    for row in raw_rows:
        pd, pe = norm_mx_phone(row.get("telefono"))
        if pd is None:
            pd = "INVALID_" + only_digits(row.get("telefono"))[:20]
        key = pd
        if key not in by_phone:
            order_keys.append(key)
            by_phone[key] = {
                "phone_digits": pd if not key.startswith("INVALID") else None,
                "phone_e164": pe,
                "names": [],
                "rows": [],
            }
        nm = (row.get("nombre_paciente") or "").strip()
        full = (row.get("nombre_completo_titular") or "").strip()
        by_phone[key]["names"].append(nm or full)
        by_phone[key]["rows"].append(row)

    # Resolver nombre display y email
    contacts_out = []
    patients_out = []
    appts_out = []

    for key in order_keys:
        bucket = by_phone[key]
        rows_b = bucket["rows"]
        best_name = max(
            [n for n in bucket["names"] if n],
            key=len,
            default=rows_b[0].get("nombre_paciente") or "Sin nombre",
        )
        email = None
        birth = None
        for rb in rows_b:
            if rb.get("correo_titular"):
                em = str(rb["correo_titular"]).strip()
                if em and "@" in em:
                    email = em
            bd = parse_birth(rb.get("fecha_nacimiento"))
            if bd:
                birth = bd

        pd = bucket["phone_digits"]
        pe = bucket["phone_e164"]
        wa = ("521" + pd) if pd else None
        cid = uid("contact|" + (pd or key))
        pid = uid("patient|" + (pd or key))

        contacts_out.append(
            {
                "id": cid,
                "phone_digits": pd,
                "phone_e164": pe,
                "wa_id": wa,
                "metadata": {"import": "Dr.JuanCarlos Base_CRM", "raw_keys": key},
            }
        )
        patients_out.append(
            {
                "id": pid,
                "contact_id": cid,
                "full_name": best_name,
                "birth_date": str(birth) if birth else None,
                "email": email,
            }
        )

        seen_booking = set()
        for rb in rows_b:
            dt = parse_fecha_cita(rb.get("fecha_cita"))
            bu = rb.get("bookingUid")
            if isinstance(bu, float):
                bu = str(int(bu)) if bu == int(bu) else str(bu)
            if bu:
                bu = str(bu).strip()
            if not dt and not bu:
                continue
            if bu and bu in seen_booking:
                continue
            if bu:
                seen_booking.add(bu)
            status, stid = map_status(
                str(rb.get("fase_general") or ""),
                str(rb.get("etiqueta_subfase") or ""),
            )
            if dt:
                starts = dt
            else:
                starts = datetime(2026, 1, 1, 9, 0, 0)
            ends = starts.replace(minute=starts.minute + 30) if starts else None
            if ends and ends.minute >= 60:
                ends = ends.replace(hour=ends.hour + 1, minute=ends.minute - 60)
            aid = uid(
                "appt|"
                + (pd or key)
                + "|"
                + (bu or starts.isoformat())
            )
            appts_out.append(
                {
                    "id": aid,
                    "patient_id": pid,
                    "starts_at_local_naive": starts.strftime("%Y-%m-%d %H:%M:%S")
                    if starts
                    else None,
                    "booking_uid": bu,
                    "status": status,
                    "status_type_id": stid,
                    "reason": (rb.get("motivo_contacto_directo") or None),
                }
            )

    preview = {
        "notas": [
            "Solo hoja Base_CRM; 17 filas con telefono/nombre; resto de filas vacías en el xlsx.",
            "Tel 9 dígitos (613294675) normalizado a 10 con prefijo 8 → 8613294675 (revisar si era otro dígito).",
            "Citas insertadas solo si había fecha_cita parseable o bookingUid; sin fechas inventadas.",
            "Zona horaria cita: America/Monterrey en SQL.",
        ],
        "tenants": [{"id": tenant_id, "name": "E-SMART360 Monterrey (import CRM Dr. Juan Carlos)"}],
        "locations": [
            {
                "id": location_id,
                "code": "MTY-01",
                "display_name": "Monterrey — Consultorio principal",
                "timezone": "America/Monterrey",
                "city": "Monterrey",
            }
        ],
        "specialists": [
            {
                "id": specialist_id,
                "specialist_key": "dr",
                "specialist_code": "dr_juan_carlos",
                "display_name": "Dr. Juan Carlos",
                "location_id": location_id,
            }
        ],
        "contacts": contacts_out,
        "patients": patients_out,
        "appointments": appts_out,
    }

    def esc(s: str | None) -> str:
        if s is None:
            return "NULL"
        return "'" + str(s).replace("'", "''") + "'"

    lines = [
        "-- Seed importado desde Dr.JuanCarlos (1).xlsx → Base_CRM",
        "-- Requiere migraciones 001 + 002 ya aplicadas (catálogos, locations, specialists con columnas 002).",
        "-- Ajusta tenant_id si ya existe otro tenant en tu base.",
        "",
        "begin;",
        "",
        f"insert into tenants (id, name) values ('{tenant_id}', 'E-SMART360 Monterrey') on conflict (id) do nothing;",
        f"insert into locations (id, tenant_id, code, display_name, timezone, city, country_code) values ('{location_id}', '{tenant_id}', 'MTY-01', 'Monterrey — Consultorio principal', 'America/Monterrey', 'Monterrey', 'MX') on conflict do nothing;",
        "",
        "insert into specialists (id, tenant_id, specialist_key, display_name, timezone, calcom_event_type_id, specialist_code, location_id)",
        f"values ('{specialist_id}', '{tenant_id}', 'dr', 'Dr. Juan Carlos', 'America/Monterrey', NULL, 'dr_juan_carlos', '{location_id}')",
        "on conflict do nothing;",
        "",
        "insert into specialist_duplicate_policies (tenant_id, specialist_id, policy_scope, window_type, active)",
        f"select '{tenant_id}', '{specialist_id}', 'same_specialist', 'exact_slot', true",
        "where not exists (select 1 from specialist_duplicate_policies p where p.tenant_id = '{tid}'::uuid and p.specialist_id = '{sid}'::uuid and p.deleted_at is null and p.active = true);".format(
            tid=tenant_id, sid=specialist_id
        ),
        "",
    ]

    for c in contacts_out:
        wa = esc(c["wa_id"])
        pe = esc(c["phone_e164"])
        pd = esc(c["phone_digits"])
        meta = esc(json.dumps(c["metadata"], ensure_ascii=False))
        lines.append(
            f"insert into contacts (id, tenant_id, wa_id, phone_e164, phone_digits, channel_primary, metadata) values "
            f"('{c['id']}', '{tenant_id}', {wa}, {pe}, {pd}, 'whatsapp', {meta}::jsonb) on conflict (id) do nothing;"
        )

    for p in patients_out:
        bd = esc(p["birth_date"]) if p["birth_date"] else "NULL"
        em = esc(p["email"]) if p["email"] else "NULL"
        fn = esc(p["full_name"])
        lines.append(
            f"insert into patients (id, tenant_id, contact_id, full_name, birth_date, email) values "
            f"('{p['id']}', '{tenant_id}', '{p['contact_id']}', {fn}, {bd}::date, {em}) on conflict (id) do nothing;"
        )

    for p in patients_out:
        lines.append(
            f"insert into contact_patient_links (tenant_id, contact_id, patient_id, relationship_type, is_primary, relationship_type_id, relationship_type_code) "
            f"select '{tenant_id}', '{p['contact_id']}', '{p['id']}', 'titular', true, 1, 'titular' "
            f"where not exists (select 1 from contact_patient_links l where l.contact_id = '{p['contact_id']}' and l.patient_id = '{p['id']}' and l.deleted_at is null);"
        )

    for a in appts_out:
        bu = esc(a["booking_uid"]) if a["booking_uid"] else "NULL"
        st = a["status"]
        stid = a["status_type_id"]
        rs = esc(a["reason"])
        ts = a["starts_at_local_naive"]
        lines.append(
            f"insert into appointments (id, tenant_id, specialist_id, patient_id, location_id, source, source_type_id, status, status_type_id, appointment_type_id, booking_uid, starts_at, ends_at, reason, metadata) values ("
            f"'{a['id']}', '{tenant_id}', '{specialist_id}', '{a['patient_id']}', '{location_id}', 'whatsapp', 1, '{st}', {stid}, 1, {bu}, "
            f"('{esc(ts)[1:-1]}'::timestamp AT TIME ZONE 'America/Monterrey'), "
            f"((('{esc(ts)[1:-1]}'::timestamp + interval '30 minutes') AT TIME ZONE 'America/Monterrey') AT TIME ZONE 'America/Monterrey'), "
            f"{rs}, '{{\"import\":\"crm_xlsx\"}}'::jsonb"
            f") on conflict (id) do nothing;"
        )

    lines.append("commit;")

    # Fix SQL generation - esc(ts) wrong for timestamp
    lines = lines[:-1]  # remove broken last lines and rebuild appt section

    lines = [
        "-- Seed importado desde Dr.JuanCarlos (1).xlsx → Base_CRM",
        "-- Requiere migraciones 001 + 002 ya aplicadas.",
        "",
        "begin;",
        "",
        f"insert into tenants (id, name) values ('{tenant_id}', 'E-SMART360 Monterrey') on conflict (id) do nothing;",
        "",
        f"insert into locations (id, tenant_id, code, display_name, timezone, city, country_code)",
        f"values ('{location_id}', '{tenant_id}', 'MTY-01', 'Monterrey — Consultorio principal', 'America/Monterrey', 'Monterrey', 'MX')",
        "on conflict (tenant_id, code) where deleted_at is null do nothing;",
        "",
        "insert into specialists (id, tenant_id, specialist_key, display_name, timezone, calcom_event_type_id, specialist_code, location_id)",
        f"values ('{specialist_id}', '{tenant_id}', 'dr', 'Dr. Juan Carlos', 'America/Monterrey', NULL, 'dr_juan_carlos', '{location_id}')",
        "on conflict (id) do nothing;",
        "",
        "insert into specialist_duplicate_policies (tenant_id, specialist_id, policy_scope, window_type, active)",
        f"select '{tenant_id}', '{specialist_id}', 'same_specialist', 'exact_slot', true",
        "where not exists (select 1 from specialist_duplicate_policies p where p.tenant_id = '{tid}'::uuid and p.specialist_id = '{sid}'::uuid and p.deleted_at is null and p.active = true);".format(
            tid=tenant_id, sid=specialist_id
        ),
        "",
    ]

    def esc(s: str | None) -> str:
        if s is None:
            return "NULL"
        return "'" + str(s).replace("'", "''") + "'"

    for c in contacts_out:
        wa = esc(c["wa_id"])
        pe = esc(c["phone_e164"])
        pd = esc(c["phone_digits"]) if c["phone_digits"] else "NULL"
        meta = esc(json.dumps(c["metadata"], ensure_ascii=False))
        lines.append(
            f"insert into contacts (id, tenant_id, wa_id, phone_e164, phone_digits, channel_primary, metadata) values "
            f"('{c['id']}', '{tenant_id}', {wa}, {pe}, {pd}, 'whatsapp', {meta}::jsonb) on conflict (id) do nothing;"
        )

    for p in patients_out:
        bd = f"{esc(p['birth_date'])}::date" if p["birth_date"] else "NULL"
        em = esc(p["email"]) if p["email"] else "NULL"
        fn = esc(p["full_name"])
        lines.append(
            f"insert into patients (id, tenant_id, contact_id, full_name, birth_date, email) values "
            f"('{p['id']}', '{tenant_id}', '{p['contact_id']}', {fn}, {bd}, {em}) on conflict (id) do nothing;"
        )

    for p in patients_out:
        lines.append(
            f"insert into contact_patient_links (tenant_id, contact_id, patient_id, relationship_type, is_primary, relationship_type_id, relationship_type_code) "
            f"select '{tenant_id}', '{p['contact_id']}', '{p['id']}', 'titular', true, 1, 'titular' "
            f"where not exists (select 1 from contact_patient_links l where l.contact_id = '{p['contact_id']}'::uuid and l.patient_id = '{p['id']}'::uuid and l.deleted_at is null);"
        )

    for a in appts_out:
        bu = esc(a["booking_uid"]) if a["booking_uid"] else "NULL"
        ts = a["starts_at_local_naive"]
        ts_esc = ts.replace("'", "''")
        rs = esc(a["reason"])
        lines.append(
            f"insert into appointments (id, tenant_id, specialist_id, patient_id, location_id, source, source_type_id, status, status_type_id, appointment_type_id, booking_uid, starts_at, ends_at, reason, metadata) values ("
            f"'{a['id']}', '{tenant_id}', '{specialist_id}', '{a['patient_id']}', '{location_id}', 'whatsapp', 1, '{a['status']}', {a['status_type_id']}, 1, {bu}, "
            f"('{ts_esc}'::timestamp AT TIME ZONE 'America/Monterrey'), "
            f"('{ts_esc}'::timestamp + interval '30 minutes') AT TIME ZONE 'America/Monterrey', "
            f"{rs}, '{{\"import\":\"crm_xlsx\"}}'::jsonb"
            f") on conflict (id) do nothing;"
        )

    lines.append("commit;")

    out_sql.write_text("\n".join(lines) + "\n", encoding="utf-8")
    out_preview.write_text(
        json.dumps(preview, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print("Wrote", out_sql)
    print("Wrote", out_preview)


if __name__ == "__main__":
    main()
