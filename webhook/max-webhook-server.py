#!/usr/bin/env python3
"""
MAX Messenger Webhook Server
Принимает Alertmanager webhook и отправляет в MAX API.
Токен и chat_id — только из /etc/default/max-webhook-server (не в коде!).
"""

import os
import logging
from datetime import datetime, timezone
from flask import Flask, request, jsonify
import requests

# ============ CONFIG (только env) ============
MAX_BOT_TOKEN = os.environ.get("MAX_BOT_TOKEN", "")
MAX_API_URL = os.environ.get("MAX_API_URL", "https://platform-api.max.ru/messages")
MAX_CHAT_ID = os.environ.get("MAX_CHAT_ID", "")
WEBHOOK_PORT = int(os.environ.get("WEBHOOK_PORT", "5000"))
LOG_FILE = os.environ.get("LOG_FILE", "/var/log/max-webhook-server.log")

# ============ LOGGING ============
os.makedirs(os.path.dirname(LOG_FILE) or "/tmp", exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.FileHandler(LOG_FILE), logging.StreamHandler()]
)
logger = logging.getLogger("max-webhook")

app = Flask(__name__)

SEVERITY_EMOJI = {
    "critical": "☠️", "disaster": "☠️", "high": "⚠️",
    "warning": "⚡", "info": "ℹ️", "": "ℹ️"
}
STATUS_EMOJI = {"firing": "🔥", "resolved": "✅"}


def format_alert(alert, status):
    labels = alert.get("labels", {})
    annotations = alert.get("annotations", {})

    server = labels.get("instance", "Unknown")
    if ":" in server:
        server = server.split(":")[0]

    severity = labels.get("severity", "warning")
    alertname = labels.get("alertname", "Unknown")
    description = annotations.get("description", annotations.get("summary", "Нет описания"))

    sev_emoji = SEVERITY_EMOJI.get(severity.lower(), "⚠️")
    status_emoji = STATUS_EMOJI.get(status.lower(), "🔔")

    lines = [
        f"### {status_emoji} {sev_emoji} **{alertname}**",
        "",
        f"**🖥️ Сервер:** `{server}`",
        f"**📊 Статус:** {status_emoji} `{status.upper()}`",
        f"**⚡ Критичность:** {sev_emoji} `{severity.upper()}`",
        "",
        f"**📝 Описание:**",
        f"> {description}",
        "",
        "---"
    ]
    return "\n".join(lines)


def send_to_max(text):
    if not MAX_BOT_TOKEN:
        logger.error("MAX_BOT_TOKEN not configured")
        return False, "No token"

    payload = {"text": text, "format": "markdown"}
    headers = {
        "Authorization": MAX_BOT_TOKEN,
        "Content-Type": "application/json"
    }
    params = {}
    if MAX_CHAT_ID:
        params["chat_id"] = MAX_CHAT_ID

    try:
        resp = requests.post(MAX_API_URL, json=payload, headers=headers,
                             params=params, timeout=15)
        if resp.status_code == 200:
            logger.info("Message sent to MAX")
            return True, "OK"
        else:
            logger.error(f"MAX API error: {resp.status_code} {resp.text[:200]}")
            return False, f"HTTP {resp.status_code}"
    except Exception as e:
        logger.error(f"MAX request failed: {e}")
        return False, str(e)


@app.route("/", methods=["GET"])
def health():
    return jsonify({"status": "ok", "service": "max-webhook-server",
                    "max_configured": bool(MAX_BOT_TOKEN)})


@app.route("/webhook", methods=["POST"])
def webhook():
    if not request.is_json:
        return jsonify({"error": "JSON required"}), 400

    data = request.get_json()
    status = data.get("status", "firing")
    alerts = data.get("alerts", [])

    if not alerts:
        return jsonify({"status": "no alerts"}), 200

    results = []
    for alert in alerts:
        try:
            msg = format_alert(alert, status)
            ok, detail = send_to_max(msg)
            results.append({
                "alert": alert.get("labels", {}).get("alertname", "?"),
                "success": ok,
                "detail": detail
            })
        except Exception as e:
            logger.error(f"Alert processing error: {e}")
            results.append({"success": False, "detail": str(e)})

    sent = sum(1 for r in results if r["success"])
    return jsonify({"status": "processed", "total": len(results),
                    "sent": sent, "failed": len(results) - sent})


@app.route("/test", methods=["GET"])
def test_alert():
    test_data = {
        "status": "firing",
        "alerts": [{
            "status": "firing",
            "labels": {
                "alertname": "TestAlert",
                "instance": "test-server.local:9100",
                "severity": "warning"
            },
            "annotations": {
                "description": "Тестовое оповещение из webhook сервера"
            },
            "startsAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        }]
    }
    msg = format_alert(test_data["alerts"][0], "firing")
    ok, detail = send_to_max(msg)
    return jsonify({"success": ok, "detail": detail, "message": msg})


if __name__ == "__main__":
    if not MAX_BOT_TOKEN:
        logger.warning("MAX_BOT_TOKEN not set!")
    logger.info(f"Starting webhook server on :{WEBHOOK_PORT}")
    app.run(host="0.0.0.0", port=WEBHOOK_PORT, debug=False)
