# Backend Agenda Conversacional

Backend inicial para centralizar logica de agenda y reducir dependencia de workflows rigidos.

## Objetivo

- Mantener BotSailor como canal (entrada/salida WhatsApp).
- Mover decisiones de negocio (agenda, validaciones, contexto) al backend.
- Preparar base para dashboard y escalado multi-cliente.

## Endpoints iniciales

- `GET /health` estado del servicio
- `POST /chat/step` paso conversacional (entrada texto libre -> salida mensaje humano)
- `POST /webhooks/calcom/{specialist_key}` recepcion de eventos de Cal.com (dr/dra)

## Variables de entorno

Usa `../.env.local` con base en `../.env.example`.

Variables clave:

- `DATABASE_URL`
- `BS_API_TOKEN`
- `CALCOM_API_KEY`
- `CALCOM_WEBHOOK_SECRET_DR`
- `CALCOM_WEBHOOK_SECRET_DRA`
- `ALLOW_INSECURE_CALCOM_WEBHOOKS` (solo desarrollo; en produccion debe ser `false`)
- `INTERNAL_API_KEY`

## Ejecutar local

```bash
cd backend
pip install -r requirements.txt
python app/main.py
```

## Contrato de respuesta para BotSailor

La respuesta de `POST /chat/step` devuelve siempre JSON, pero el usuario final ve solo `data.message` en la caja de texto del workflow.

Ejemplo:

```json
{
  "ok": true,
  "version": 1,
  "data": {
    "message": "Para el viernes tenemos horarios disponibles...",
    "step": "choose_slot",
    "expected_input": "slot"
  },
  "error": null
}
```

## SQL inicial

Ver `sql/001_init_schema.sql`.
