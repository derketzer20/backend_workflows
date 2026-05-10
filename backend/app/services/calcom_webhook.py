from __future__ import annotations

import hashlib
import hmac
from typing import Any


def verify_signature(raw_body: bytes, signature: str, secret: str) -> bool:
    """
    Verificacion simple HMAC SHA-256.
    Ajustar al formato exacto del header que use Cal.com en produccion.
    """
    if not signature or not secret:
        return False

    digest = hmac.new(secret.encode("utf-8"), raw_body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(digest, signature)


def normalize_calcom_event(event_type: str | None, payload: dict[str, Any]) -> dict[str, Any]:
    booking_uid = payload.get("bookingUid") or payload.get("uid") or payload.get("id")
    start_time = payload.get("startTime")
    end_time = payload.get("endTime")
    attendee_name = payload.get("attendee", {}).get("name")
    attendee_email = payload.get("attendee", {}).get("email")

    return {
        "event_type": event_type or "UNKNOWN",
        "booking_uid": booking_uid,
        "start_time": start_time,
        "end_time": end_time,
        "attendee_name": attendee_name,
        "attendee_email": attendee_email,
        "raw_payload": payload,
    }
