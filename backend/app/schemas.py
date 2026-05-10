from typing import Any, Literal
from pydantic import BaseModel, Field


class ErrorPayload(BaseModel):
    code: str
    message: str


class ChatDataPayload(BaseModel):
    message: str
    step: str = "ask_day"
    expected_input: str = "date_text"
    metadata: dict[str, Any] = Field(default_factory=dict)


class ApiResponse(BaseModel):
    ok: bool
    version: int = 1
    data: ChatDataPayload | dict[str, Any]
    error: ErrorPayload | None = None


class ChatStepRequest(BaseModel):
    tenant_id: str = "default"
    specialist_key: Literal["dr", "dra"] = "dr"
    session_id: str
    wa_id: str
    chat_id: str | None = None
    user_message: str
    current_step: str | None = None
    channel: Literal["whatsapp", "voice_dialora", "calcom_web"] = "whatsapp"


class CalcomWebhookRequest(BaseModel):
    triggerEvent: str | None = None
    payload: dict[str, Any] = Field(default_factory=dict)


class BotSailorSendTextRequest(BaseModel):
    specialist_key: Literal["dr", "dra"] = "dr"
    phone_number: str
    message: str


class BotSailorTriggerFlowRequest(BaseModel):
    specialist_key: Literal["dr", "dra"] = "dr"
    phone_number: str
    bot_flow_unique_id: str
