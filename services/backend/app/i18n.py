"""HTTP language negotiation and human-facing messages. Protocol codes never change."""

import re
from fastapi import Request

ERRORS = {
    "La clave de Resend permite enviar, pero no consultar recibos": ("resend_read_permission_required", "This Resend key can send emails but cannot retrieve receipts; configure read permission"),
    "No hay un recibo de Resend disponible": ("email_receipt_unavailable", "No Resend receipt is available"),
    "No se pudo consultar el estado de Resend": ("email_status_unavailable", "Could not retrieve Resend delivery status"),
    "Recibo de correo inexistente": ("email_receipt_not_found", "Email delivery receipt not found"),
    "Se alcanzó el límite diario de análisis; inténtalo mañana": ("daily_quota_exceeded", "Daily analysis limit reached; try again tomorrow"),
    "Se alcanzó el límite de almacenamiento de tu cuenta": ("storage_quota_exceeded", "Your account storage limit has been reached"),
    "Registra el resultado de la prueba funcional antes de verificar": ("functional_check_required", "Record the functional test result before verification"),
    "La prueba funcional debe realizarse después de la intervención": ("functional_check_too_old", "The functional test must take place after the intervention"),
    "Origen no autorizado": ("origin_forbidden", "Request origin is not allowed"),
    "Demasiados registros; inténtalo en 15 minutos": ("registration_rate_limited", "Too many registrations; try again in 15 minutes"),
    "Máximo 8 imágenes con este proveedor": ("provider_image_limit", "This provider supports at most 8 images"),
    "Demasiadas imágenes para el proveedor seleccionado": ("provider_image_limit", "Too many images for the selected provider"),
    "Completa el diagnóstico antes de crear la historia": ("story_not_ready", "Complete the diagnosis before creating a story"),
    "La creación de historias no está disponible": ("story_unavailable", "Story generation is unavailable"),
    "Ya existe un trabajo pendiente": ("job_pending", "A job is already pending"),
    "Se requiere una cuenta administradora": ("admin_required", "An administrator account is required"),
    "Enlace inválido o vencido; solicita uno nuevo": (
        "invalid_reset_link",
        "Invalid or expired link; request a new one",
    ),
    "Ya existe una cuenta con ese correo": ("account_exists", "An account with that email already exists"),
    "No puedes desactivar tu cuenta ni quitarte la administración": (
        "self_admin_change",
        "You cannot deactivate your own account or remove your administrator role",
    ),
    "Cuenta inexistente": ("account_not_found", "Account not found"),
    "Demasiados intentos; espera 5 minutos": ("login_rate_limited", "Too many attempts; wait 5 minutes"),
    "Correo o contraseña incorrectos": ("invalid_credentials", "Incorrect email or password"),
    "Renovación inválida": ("invalid_refresh", "Invalid refresh token"),
    "Versión desactualizada; recarga la sesión": ("version_conflict", "Outdated version; reload the session"),
    "Los criterios quedan fijados al iniciar el diagnóstico": (
        "criteria_locked",
        "Criteria are fixed when diagnosis starts",
    ),
    "El criterio supera la alimentación declarada": (
        "criterion_exceeds_supply",
        "The criterion exceeds the declared supply voltage",
    ),
    "La sesión no admite evidencia en este estado": (
        "evidence_state_conflict",
        "The session cannot accept evidence in this state",
    ),
    "Máximo 12 imágenes por sesión": ("image_count_limit", "Maximum 12 images per session"),
    "Imagen demasiado grande": ("upload_too_large", "Image too large"),
    "Evidencia inexistente": ("evidence_not_found", "Evidence not found"),
    "Trabajo inexistente": ("job_not_found", "Job not found"),
    "Punto no autorizado por el esquema": ("point_not_authorized", "Point not authorized by the schematic"),
    "Fecha de captura inválida": ("invalid_capture_time", "Invalid capture time"),
    "La sesión no espera una medición": (
        "measurement_not_expected",
        "The session is not awaiting a measurement",
    ),
    "Registra el punto solicitado por la prueba": (
        "wrong_test_point",
        "Record the point requested by the test",
    ),
    "La sesión no espera una intervención": (
        "intervention_not_expected",
        "The session is not awaiting an intervention",
    ),
    "La sesión no espera una confirmación": (
        "confirmation_not_expected",
        "The session is not awaiting a confirmation",
    ),
    "Primero confirma la intervención humana": (
        "intervention_required",
        "Confirm the human intervention first",
    ),
    "Invitación inválida o vencida": ("invalid_invitation", "Invalid or expired invitation"),
    "Firmware v1 admite TP1, TP2, TP3": ("unsupported_firmware_point", "Firmware v1 supports TP1, TP2, TP3"),
    "Simulación deshabilitada en producción": ("simulation_disabled", "Simulation is disabled in production"),
    "Dispositivo no autorizado": ("device_not_authorized", "Device not authorized"),
    "Dispositivo o punto no autorizado": ("device_point_not_authorized", "Device or point not authorized"),
    "Bridge desconectado": ("bridge_disconnected", "Bridge disconnected"),
    "Ya existe un comando pendiente": ("command_pending", "A command is already pending"),
    "La verificación requiere lecturas posteriores a la intervención": (
        "post_intervention_required",
        "Verification requires readings taken after the intervention",
    ),
    "Demasiados intentos de invitación; espera 5 minutos": (
        "pairing_rate_limited",
        "Too many invitation attempts; wait 5 minutes",
    ),
    "Sesión inexistente": ("session_not_found", "Session not found"),
    "Sin permiso para esta sesión": ("session_forbidden", "No permission for this session"),
    "Confirma el esquema y los criterios funcionales antes del análisis": (
        "specification_required",
        "Confirm the schematic and functional criteria before analysis",
    ),
    "Registra la medición solicitada antes de continuar": (
        "measurement_required",
        "Record the requested measurement before continuing",
    ),
    "Confirma físicamente la conexión solicitada antes de continuar": (
        "confirmation_required",
        "Physically confirm the requested connection before continuing",
    ),
    "La sesión cambió; vuelve a cargarla": ("session_changed", "The session changed; reload it"),
    "Credencial inválida o vencida": ("token_invalid", "Invalid or expired credential"),
    "Imagen inválida; utiliza JPEG o PNG de hasta 20 MP": (
        "invalid_image",
        "Invalid image; use JPEG or PNG up to 20 MP",
    ),
    "Not Found": ("not_found", "Not found"),
    "Method Not Allowed": ("method_not_allowed", "Method not allowed"),
}


def negotiate_language(header: str | None) -> str:
    choices = []
    for index, item in enumerate((header or "").split(",")):
        parts = item.strip().lower().split(";")
        language = parts[0].split("-")[0]
        try:
            quality = next((float(p.strip()[2:]) for p in parts[1:] if p.strip().startswith("q=")), 1.0)
        except ValueError:
            continue
        if language in {"en", "es"} and 0 < quality <= 1:
            choices.append((quality, -index, language))
    return max(choices)[2] if choices else "es"


def request_language(request: Request) -> str:
    return negotiate_language(request.headers.get("accept-language"))


def error_message(detail, language):
    if isinstance(detail, str) and detail in ERRORS:
        code, english = ERRORS[detail]
        spanish = {"Not Found": "No encontrado", "Method Not Allowed": "Método no permitido"}.get(
            detail, detail
        )
        return code, english if language == "en" else spanish
    if isinstance(detail, str) and detail.startswith("Faltan medidas posteriores para: "):
        points = detail.split(": ", 1)[1]
        return "verification_measurements_missing", (
            f"Missing post-intervention measurements for: {points}" if language == "en" else detail
        )
    if isinstance(detail, str) and detail.startswith("Transición inválida: "):
        states = detail.split(": ", 1)[1]
        return "invalid_transition", (f"Invalid transition: {states}" if language == "en" else detail)
    return (
        "request_failed",
        "The request could not be completed" if language == "en" else "No se pudo completar la solicitud",
    )


LABELS = {
    "draft": ("Borrador", "Draft"),
    "ready": ("Listo para analizar", "Ready to analyze"),
    "analyzing": ("Analizando", "Analyzing"),
    "awaiting_evidence": ("Falta evidencia", "Evidence needed"),
    "awaiting_confirmation": ("Confirma una conexión", "Confirm a connection"),
    "awaiting_measurement": ("Medición pendiente", "Measurement pending"),
    "awaiting_intervention": ("Intervención humana", "Human intervention"),
    "verifying": ("Verificando", "Verifying"),
    "resolved": ("Criterio cumplido", "Criteria met"),
    "inconclusive": ("Inconcluso", "Inconclusive"),
    "cancelled": ("Cancelado", "Cancelled"),
    "manual": ("Manual", "Manual"),
    "instrumented": ("Instrumentada", "Instrumented"),
    "simulated": ("Simulada", "Simulated"),
    "led_resistor": ("LED + resistencia", "LED + resistor"),
    "voltage_divider": ("Divisor resistivo", "Voltage divider"),
    "analog_sensor": ("Sensor analógico", "Analog sensor"),
    "proposed": ("Propuesta", "Proposed"),
    "compatible": ("Compatible", "Compatible"),
    "contradicted": ("Contradicha", "Contradicted"),
    "discarded": ("Descartada", "Discarded"),
    "supported_by_test": ("Respaldada por prueba", "Supported by test"),
    "provider_unavailable": ("Proveedor no disponible", "Provider unavailable"),
    "analysis_failed": ("Falló el análisis", "Analysis failed"),
    "timeout": ("Tiempo de espera agotado", "Timed out"),
    "out_of_range": ("Fuera de rango", "Out of range"),
    "disconnected": ("Desconectado", "Disconnected"),
    "precondition_failed": ("Condición previa incumplida", "Precondition not met"),
}


def label(code, language):
    return LABELS.get(code, (code, code))[language == "en"]


def safe_text(value):
    """Plain Markdown text: prevent user evidence from creating report markup or links."""
    return re.sub(r"([\\`*_{}\[\]<>#!|])", r"\\\1", str(value)).replace("\r", "").replace("\n", " ")
