from __future__ import annotations

from flask import Flask, jsonify, request

from .config import settings
from .services.botsailor_client import send_text_message, trigger_bot_flow
from .services.calcom_webhook import normalize_calcom_event, verify_signature
from .services.conversation import build_human_slot_message, detect_intent, parse_date_text

app = Flask(__name__)


def _unauthorized():
    return jsonify({"ok": False, "version": 1, "data": {}, "error": {"code": "UNAUTHORIZED", "message": "Unauthorized"}}), 401


def _require_internal_key() -> tuple[bool, tuple | None]:
    incoming = request.headers.get("x-internal-api-key", "")
    if settings.internal_api_key and incoming != settings.internal_api_key:
        return False, _unauthorized()
    return True, None


def _ok(data: dict) -> tuple:
    return jsonify({"ok": True, "version": 1, "data": data, "error": None}), 200


def _fail(code: str, message: str, data: dict | None = None, status: int = 400) -> tuple:
    return jsonify({"ok": False, "version": 1, "data": data or {}, "error": {"code": code, "message": message}}), status


def _resolve_phone_number_id(specialist_key: str) -> str:
    return settings.bs_phone_number_id_dra if specialist_key == "dra" else settings.bs_phone_number_id_dr


@app.get("/health")
def health():
    return jsonify({"status": "ok", "env": settings.app_env}), 200


@app.post("/chat/step")
def chat_step():
    allowed, response = _require_internal_key()
    if not allowed:
        return response

    payload = request.get_json(silent=True) or {}
    user_message = str(payload.get("user_message", "")).strip()
    specialist_key = str(payload.get("specialist_key", "dr")).strip().lower()
    specialist_label = "Dra" if specialist_key == "dra" else "Dr"

    intent = detect_intent(user_message)

    if intent == "location":
        return _ok(
            {
                "message": "Claro. Te comparto la ubicacion del consultorio. Si gustas, tambien puedo enviarte una referencia de llegada.",
                "step": "location",
                "expected_input": "none",
                "metadata": {"action": "trigger_flow", "flow_key": "ubicacion"},
            }
        )

    if intent == "list_appointments":
        return _ok(
            {
                "message": "Estoy consultando tus citas activas. Enseguida te confirmo fecha, hora y especialista.",
                "step": "list_appointments",
                "expected_input": "none",
                "metadata": {},
            }
        )

    if intent in {"book", "reschedule"}:
        dt, date_error = parse_date_text(user_message)
        if date_error:
            return _fail(
                code="INVALID_DATE_TEXT",
                message=date_error,
                data={
                    "message": "No pude entender la fecha. Escribe algo como: manana, viernes, o 15/05/2026.",
                    "step": "ask_day",
                    "expected_input": "date_text",
                    "metadata": {},
                },
                status=200,
            )

        date_iso = dt.strftime("%Y-%m-%d")
        return _ok(
            {
                "message": build_human_slot_message(date_iso=date_iso, specialist_label=specialist_label),
                "step": "choose_slot",
                "expected_input": "slot_choice",
                "metadata": {"resolved_date": date_iso, "intent": intent},
            }
        )

    if intent == "cancel":
        return _ok(
            {
                "message": "Entendido. Para cancelar, comparte el horario o fecha de la cita que deseas anular y lo valido contigo.",
                "step": "cancel_lookup",
                "expected_input": "date_or_time",
                "metadata": {},
            }
        )

    return _fail(
        code="OUT_OF_SCOPE",
        message="No intent recognized",
        data={
            "message": "Te ayudo con agenda, reagenda, cancelacion, citas activas o ubicacion. Dime que necesitas y lo resolvemos paso a paso.",
            "step": "fallback",
            "expected_input": "intent",
            "metadata": {},
        },
        status=200,
    )


@app.post("/webhooks/calcom/<specialist_key>")
def calcom_webhook(specialist_key: str):
    if specialist_key not in {"dr", "dra"}:
        return _fail("INVALID_SPECIALIST", "Invalid specialist key", status=400)

    payload = request.get_json(silent=True) or {}
    trigger_event = payload.get("triggerEvent")
    event_payload = payload.get("payload", {}) or {}

    signature = request.headers.get("x-cal-signature-256", "")
    secret = settings.calcom_webhook_secret_dra if specialist_key == "dra" else settings.calcom_webhook_secret_dr
    raw_body = request.get_data() or b""

    if secret and not verify_signature(raw_body, signature, secret):
        return _fail("INVALID_SIGNATURE", "Invalid signature", status=401)
    if not secret and not settings.allow_insecure_calcom_webhooks:
        return _fail("MISSING_WEBHOOK_SECRET", "Webhook secret is required in this environment", status=401)

    event = normalize_calcom_event(trigger_event, event_payload)
    return _ok(
        {
            "message": "Evento Cal.com recibido",
            "specialist_key": specialist_key,
            "event_type": event["event_type"],
            "booking_uid": event["booking_uid"],
        }
    )


@app.post("/integrations/botsailor/send-text")
def botsailor_send_text():
    allowed, response = _require_internal_key()
    if not allowed:
        return response

    payload = request.get_json(silent=True) or {}
    specialist_key = str(payload.get("specialist_key", "dr")).strip().lower()
    phone_number = str(payload.get("phone_number", "")).strip()
    message = str(payload.get("message", "")).strip()

    if specialist_key not in {"dr", "dra"}:
        return _fail("INVALID_SPECIALIST", "specialist_key must be dr or dra", status=400)
    if not phone_number:
        return _fail("MISSING_PHONE", "phone_number is required", status=400)
    if not message:
        return _fail("MISSING_MESSAGE", "message is required", status=400)

    phone_number_id = _resolve_phone_number_id(specialist_key)
    if not phone_number_id:
        return _fail("MISSING_PHONE_NUMBER_ID", "Missing phone_number_id for specialist", status=400)
    if not settings.bs_api_token:
        return _fail("MISSING_BS_API_TOKEN", "Missing BS_API_TOKEN", status=400)

    result = send_text_message(phone_number_id=phone_number_id, phone_number=phone_number, message=message)
    return _ok(result)


@app.post("/integrations/botsailor/trigger-flow")
def botsailor_trigger_flow():
    allowed, response = _require_internal_key()
    if not allowed:
        return response

    payload = request.get_json(silent=True) or {}
    specialist_key = str(payload.get("specialist_key", "dr")).strip().lower()
    phone_number = str(payload.get("phone_number", "")).strip()
    bot_flow_unique_id = str(payload.get("bot_flow_unique_id", "")).strip()

    if specialist_key not in {"dr", "dra"}:
        return _fail("INVALID_SPECIALIST", "specialist_key must be dr or dra", status=400)
    if not phone_number:
        return _fail("MISSING_PHONE", "phone_number is required", status=400)
    if not bot_flow_unique_id:
        return _fail("MISSING_FLOW_ID", "bot_flow_unique_id is required", status=400)

    phone_number_id = _resolve_phone_number_id(specialist_key)
    if not phone_number_id:
        return _fail("MISSING_PHONE_NUMBER_ID", "Missing phone_number_id for specialist", status=400)
    if not settings.bs_api_token:
        return _fail("MISSING_BS_API_TOKEN", "Missing BS_API_TOKEN", status=400)

    result = trigger_bot_flow(
        phone_number_id=phone_number_id,
        phone_number=phone_number,
        bot_flow_unique_id=bot_flow_unique_id,
    )
    return _ok(result)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=settings.app_port, debug=(settings.app_env == "development"))
