from __future__ import annotations

import os
from dataclasses import dataclass
from dotenv import load_dotenv


load_dotenv("../.env.local")


def _as_bool(value: str | None, default: bool = False) -> bool:
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


@dataclass
class Settings:
    app_env: str = os.getenv("APP_ENV", "development")
    app_port: int = int(os.getenv("APP_PORT", "8080"))
    internal_api_key: str = os.getenv("INTERNAL_API_KEY", "")

    bs_base_url: str = os.getenv("BS_BASE_URL", "https://app.e-smart360.com")
    bs_api_token: str = os.getenv("BS_API_TOKEN", "")
    bs_phone_number_id_dr: str = os.getenv("BS_PHONE_NUMBER_ID_DR", "")
    bs_phone_number_id_dra: str = os.getenv("BS_PHONE_NUMBER_ID_DRA", "")

    calcom_api_key: str = os.getenv("CALCOM_API_KEY", "")
    calcom_webhook_secret_dr: str = os.getenv("CALCOM_WEBHOOK_SECRET_DR", "")
    calcom_webhook_secret_dra: str = os.getenv("CALCOM_WEBHOOK_SECRET_DRA", "")
    allow_insecure_calcom_webhooks: bool = _as_bool(
        os.getenv("ALLOW_INSECURE_CALCOM_WEBHOOKS"), default=True
    )

    database_url: str = os.getenv("DATABASE_URL", "")


settings = Settings()
