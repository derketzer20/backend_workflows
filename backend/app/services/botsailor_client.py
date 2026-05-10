from __future__ import annotations

import requests

from ..config import settings


def send_text_message(phone_number_id: str, phone_number: str, message: str) -> dict:
    url = f"{settings.bs_base_url}/api/v1/whatsapp/send"
    payload = {
        "apiToken": settings.bs_api_token,
        "phone_number_id": phone_number_id,
        "phone_number": phone_number,
        "message": message,
    }
    response = requests.post(url, params=payload, timeout=20)
    return {
        "status_code": response.status_code,
        "ok": response.ok,
        "body": response.text,
    }


def trigger_bot_flow(phone_number_id: str, phone_number: str, bot_flow_unique_id: str) -> dict:
    url = f"{settings.bs_base_url}/api/v1/whatsapp/trigger-bot"
    payload = {
        "apiToken": settings.bs_api_token,
        "phone_number_id": phone_number_id,
        "phone_number": phone_number,
        "bot_flow_unique_id": bot_flow_unique_id,
    }
    response = requests.post(url, params=payload, timeout=20)
    return {
        "status_code": response.status_code,
        "ok": response.ok,
        "body": response.text,
    }
