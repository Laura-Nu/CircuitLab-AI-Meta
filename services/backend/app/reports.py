from datetime import UTC, datetime
from app.i18n import label, safe_text

LIMITATIONS = {
    "es": [
        "Solo familias y puntos confirmados; no acredita conexiones ocultas.",
        "Las lecturas manuales y simuladas conservan su origen.",
        "La verificación combina los criterios eléctricos declarados con la prueba funcional registrada por la persona.",
    ],
    "en": [
        "Only confirmed circuit families and points; hidden connections are not established.",
        "Manual and simulated readings retain their source labels.",
        "Verification combines the declared electrical criteria with the operator-recorded functional test.",
    ],
}
EVENTS = {
    "baseline_functional_check_recorded": ("Comprobación funcional sin reparación", "Functional check without repair"),
    "baseline_assessment_completed": ("Evaluación sin reparación finalizada", "Baseline assessment completed"),
    "investigation_closed": ("Investigación cerrada sin verificar", "Investigation closed without verification"),
    "functional_check_recorded": ("Prueba funcional registrada", "Functional test recorded"),
    "production_provider_probe": ("Prueba real del proveedor", "Real provider probe"),
    "story_requested": ("Historia solicitada", "Story requested"),
    "story_completed": ("Historia creada", "Story created"),
    "story_failed": ("Falló la historia", "Story failed"),
    "session_created": ("Sesión creada", "Session created"),
    "state_changed": ("Cambio de estado", "State changed"),
    "specification_confirmed": ("Esquema confirmado", "Schematic confirmed"),
    "evidence_added": ("Evidencia adjuntada", "Evidence attached"),
    "measurement_recorded": ("Medición registrada", "Measurement recorded"),
    "intervention_confirmed": ("Intervención confirmada", "Intervention confirmed"),
    "connection_confirmed": ("Conexión confirmada", "Connection confirmed"),
    "job_queued": ("Trabajo encolado", "Job queued"),
    "job_completed": ("Trabajo completado", "Job completed"),
    "job_error": ("Error de análisis", "Analysis error"),
    "diagnosis_updated": ("Diagnóstico actualizado", "Diagnosis updated"),
    "hardware_requested": ("Lectura solicitada", "Reading requested"),
    "hardware_result": ("Resultado del bridge", "Bridge result"),
    "hardware_failed": ("Error de lectura", "Reading error"),
    "verification_completed": ("Verificación completada", "Verification completed"),
}


def localized_text(data, field, language):
    return (data.get("translations") or {}).get(language, {}).get(field, data.get(field, ""))


def prepare_report(result, language):
    result["report_language"] = language
    result["limitations"] = LIMITATIONS[language]
    result["presentation"] = {
        "state": label(result["state"], language),
        "family": label(result["family"], language),
        "sources": {source: label(source, language) for source in ("manual", "instrumented", "simulated")},
        "original_content_notice": (
            "Los textos aportados por personas y los análisis históricos sin traducción conservan su idioma original."
            if language == "es"
            else "Human-entered text and historical analyses without translations retain their original language."
        ),
        "events": [
            {
                "sequence": e["sequence"],
                "label": EVENTS.get(e["kind"], (e["kind"], e["kind"]))[language == "en"],
            }
            for e in result["events"]
        ],
    }
    return result


def render_markdown(report, language, *, technical_details=False):
    def text(es, en):
        return en if language == "en" else es

    def timestamp(value):
        return datetime.fromtimestamp(value, UTC).isoformat(timespec="seconds")

    yes, no = text("Sí", "Yes"), text("No", "No")
    lines = [
        f"# CircuitLab AI · {text('Reporte de sesión', 'Session report')}",
        "",
        f"{text('Sesión', 'Session')}: {safe_text(report['title'])} ({report['id']})",
        f"{text('Estado', 'State')}: {label(report['state'], language)}",
        f"{text('Familia', 'Family')}: {label(report['family'], language)}",
        f"{text('Modo', 'Mode')}: {'SIMULATION' if language == 'en' else 'SIMULACIÓN'}"
        if report["diagnosis_mode"] == "simulation"
        else text("Diagnóstico asistido", "Assisted diagnosis") if not technical_details else "Meta",
        f"{text('Alimentación', 'Supply')}: {report['supply_v']} V",
        "",
        report["presentation"]["original_content_notice"],
        "",
        f"## {text('Resultado esperado', 'Expected result')}",
        safe_text(report["expected"]),
        "",
        f"## {text('Síntomas', 'Symptoms')}",
        safe_text(report["symptoms"]),
        "",
        f"## {text('Especificación previa', 'Initial specification')} v{report['spec_version']}",
        safe_text(report["specification"].get("functional_description", "")),
    ]
    for connection in report["specification"].get("connections", []):
        lines.append("- " + safe_text(connection))
    for point in report["specification"].get("points", []):
        lines.append(f"- {point['id']} · {safe_text(point['label'])}: {point['min_v']}–{point['max_v']} V")
    lines += ["", f"## {text('Evidencia', 'Evidence')}"]
    for item in report["evidence"]:
        lines.append(f"- {item['id']} · {item['mime']} · SHA-256: {item['sha256']}")
    lines += ["", f"## {text('Observaciones e hipótesis', 'Observations and hypotheses')}"]
    for run in report["model_runs"]:
        for observation in localized_text(run["data"].get("output", {}), "observations", language) or []:
            lines.append("- " + safe_text(observation))
    for item in report["hypotheses"]:
        data = item["data"]
        lines.append(
            f"- {safe_text(localized_text(data, 'cause', language))} · {label(data['status'], language)}"
        )
        lines.append("  " + safe_text(localized_text(data, "explanation", language)))
        lines.append(f"  {text('Referencias', 'References')}: {', '.join(data.get('evidence_ids', []))}")
    if technical_details:
        lines += ["", f"## {text('Ejecuciones del modelo', 'Model executions')}"]
        for run in report["model_runs"]:
            data = run["data"]
            lines.append(f"- {run['id']} · {safe_text(data.get('provider', ''))} · {safe_text(data.get('model', ''))}")
            if data.get("response_model"):
                lines.append(f"  {text('Modelo reportado', 'Reported model')}: {safe_text(data['response_model'])}")
            if data.get("request_id"):
                lines.append(f"  {text('Solicitud al proveedor', 'Provider request')}: {safe_text(data['request_id'])}")
            for prediction in data.get("output", {}).get("test_predictions", []):
                outcome = prediction["expected_outcome"][language]
                lines.append(f"  H{prediction['hypothesis_index'] + 1}: {safe_text(outcome)}")
    else:
        lines += ["", f"## {text('Comprobaciones propuestas', 'Proposed checks')}"]
        for run in report["model_runs"]:
            output = run["data"].get("output", {})
            for field in ("instruction", "rationale"):
                value = localized_text(output, field, language)
                if value:
                    lines.append("- " + safe_text(value))
            for prediction in output.get("test_predictions", []):
                outcome = prediction["expected_outcome"][language]
                lines.append(f"  H{prediction['hypothesis_index'] + 1}: {safe_text(outcome)}")
    lines += ["", f"## {text('Mediciones', 'Measurements')}"]
    for item in report["measurements"]:
        phase = (
            text("Posterior a intervención", "After intervention")
            if item["phase"] == "verification"
            else text("Diagnóstico", "Diagnosis")
        )
        lines.append(
            f"- {item['point_id']}: {item['value']:.3f} V · {label(item['source'], language)} · {phase} · {timestamp(item['measured_at'])} · {item['id']}"
        )
    lines += ["", f"## {text('Intervenciones', 'Interventions')}"]
    for item in report["interventions"]:
        lines.append(f"- {timestamp(item['created_at'])}: {safe_text(item['description'])}")
    for event in report["events"]:
        if event["kind"] == "investigation_closed":
            lines += ["", text("## Cierre sin verificación", "## Closed without verification"),
                      safe_text(event["data"]["reason"])]
    lines += ["", f"## {text('Verificación', 'Verification')}"]
    for item in report["verifications"]:
        data = item["data"]
        if data.get("assessment_kind") == "baseline":
            lines.append(text("Evaluación sin intervención: no se observó una falla en las condiciones comprobadas; no acredita una reparación.", "Assessment without intervention: no fault observed under the checked conditions; no repair is established."))
        lines.append(f"- {text('Criterios cumplidos', 'Criteria met')}: {yes if data['passed'] else no}")
        lines.append(
            f"- {text('Verificación física acreditada', 'Physical verification established')}: {yes if data['physical_verification'] and data.get('functional_check') else no}"
        )
        functional = data.get("functional_check")
        if not functional:
            lines.append(text("Verificación histórica de voltaje: no incluye una prueba funcional registrada.", "Historical voltage verification: no recorded functional test is included."))
        if functional:
            lines.append(f"- {text('Prueba funcional observada', 'Observed functional test')}: {safe_text(functional['observations'])}")
            lines.append(f"- {text('Resultado funcional', 'Functional result')}: {yes if functional['passed'] else no}")
            lines.append(f"- {text('Condición comprobada', 'Checked condition')}: {safe_text(functional['criteria'])}")
        lines.append(f"- {text('Origen de las lecturas', 'Reading source')}: {safe_text(data.get('verification_basis', 'legacy'))}")
        for check in data["checks"]:
            lines.append(
                f"  - {check['point_id']}: {check['value']} V / {check['min_v']}–{check['max_v']} V · {label(check['source'], language)}"
            )
    for story in report.get("storyboards", []):
        if not story.get("data"):
            continue
        data = story["data"]
        lines += ["", "## Circuit Story", safe_text(data["title"][language]), "", safe_text(data["notice"][language])]
        if data["simulation"] or data["diagnosis_mode"] == "simulation":
            lines.append(text("Contiene simulación; no demuestra una reparación física.", "Contains simulation; not a physical repair demonstration."))
        for frame in data["frames"]:
            lines += ["", "### " + safe_text(frame["headline"][language]), safe_text(frame["caption"][language]),
                      f"{text('Fuentes', 'Sources')}: " + ", ".join(frame["source_ids"])]
        lines.append("SHA-256: " + data["source_sha256"])
    lines += ["", f"## {text('Cronología', 'Timeline')}"]
    for event, presentation in zip(report["events"], report["presentation"]["events"], strict=True):
        detail = event["data"]
        suffix = label(
            detail.get("to", detail.get("source", detail.get("code", detail.get("status", "")))), language
        )
        lines.append(
            f"- #{event['sequence']} · {timestamp(event['created_at'])} · {presentation['label']}"
            + (f" · {suffix}" if suffix else "")
        )
    lines += [
        "",
        f"## {text('Limitaciones', 'Limitations')}",
        *("- " + item for item in report["limitations"]),
    ]
    return "\n".join(lines) + "\n"
