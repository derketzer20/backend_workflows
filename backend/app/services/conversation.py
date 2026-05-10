from __future__ import annotations

from datetime import datetime, timedelta
from dateutil import parser


def _normalize_text(text: str) -> str:
    return " ".join(text.lower().strip().split())


def detect_intent(user_message: str) -> str:
    msg = _normalize_text(user_message)

    if any(k in msg for k in ["cancel", "cancelar", "anular"]):
        return "cancel"
    if any(k in msg for k in ["reagenda", "reagendar", "cambiar cita"]):
        return "reschedule"
    if any(k in msg for k in ["que citas", "qué citas", "mis citas"]):
        return "list_appointments"
    if any(k in msg for k in ["ubicacion", "ubicación", "donde estan", "dónde están"]):
        return "location"
    if any(k in msg for k in ["agendar", "cita", "horario", "disponible"]):
        return "book"
    return "fallback"


def parse_date_text(user_message: str) -> tuple[datetime | None, str | None]:
    msg = _normalize_text(user_message)
    now = datetime.now()

    if "hoy" in msg:
        return now, None
    if "mañana" in msg or "manana" in msg:
        return now + timedelta(days=1), None
    if "pasado mañana" in msg or "pasado manana" in msg:
        return now + timedelta(days=2), None

    try:
        dt = parser.parse(user_message, dayfirst=True, fuzzy=True)
        return dt, None
    except (ValueError, TypeError):
        return None, "No pude interpretar la fecha."


def build_human_slot_message(date_iso: str, specialist_label: str) -> str:
    return (
        f"Perfecto, para {specialist_label} el dia {date_iso} tenemos estos horarios:\\n"
        "1) 09:00\\n"
        "2) 10:30\\n"
        "3) 12:00\\n\\n"
        "Responde con el numero o escribe la hora exacta. "
        "Si prefieres otro dia, dimelo en una sola frase."
    )
