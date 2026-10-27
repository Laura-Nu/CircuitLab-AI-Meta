import secrets
import time
from collections import defaultdict, deque
from threading import Lock
from contextlib import asynccontextmanager
from fastapi import (
    Depends,
    FastAPI,
    File,
    Form,
    HTTPException,
    Response,
    UploadFile,
    WebSocket,
    Request,
    Query,
)
from fastapi.exceptions import RequestValidationError
from starlette.exceptions import HTTPException as StarletteHTTPException
from typing import Literal
import logging
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from sqlalchemy import delete, or_, select, text
from sqlalchemy.orm import Session as DBSession
from app import schemas as s
from app.config import settings
from app.db import (
    Command,
    Device,
    Evidence,
    Event,
    Hypothesis,
    Intervention,
    Job,
    Measurement,
    Member,
    ModelRun,
    Pairing,
    Session,
    SessionLocal,
    Storyboard,
    Token,
    User,
    Verification,
    get_db,
    uid,
)
from app.domain import authorized, commit, enqueue, record, serialize, transition
from app.security import current_user, digest, issue_tokens, verify_password
from app.storage import LocalStorage
from app.i18n import request_language, error_message
from app.reports import prepare_report, render_markdown
from app.accounts import router as accounts_router, public_user
from app import stories
from app.inference import image_limit


@asynccontextmanager
async def lifespan(app):
    if settings().app_env == "production":
        if settings().database_url.startswith("sqlite") or settings().ai_mode != "meta":
            raise RuntimeError("Producción requiere PostgreSQL y AI_MODE=meta")
    yield


app = FastAPI(title="CircuitLab AI", version="0.1.0", lifespan=lifespan)
app.include_router(accounts_router)
app.add_middleware(
    CORSMiddleware,
    allow_origins=[settings().app_origin],
    allow_methods=["GET", "POST", "PATCH"],
    allow_headers=["Authorization", "Content-Type", "Accept-Language"],
)
prefix = "/api/v1"
pairing_attempts = defaultdict(lambda: deque(maxlen=5))
pairing_lock = Lock()


@app.middleware("http")
async def language_headers(request: Request, call_next):
    response = await call_next(request)
    response.headers.setdefault("Content-Language", request_language(request))
    vary = response.headers.get("Vary", "")
    response.headers["Vary"] = ", ".join(filter(None, [vary, "Accept-Language"]))
    if request.url.path.startswith(("/api/v1/auth/", "/api/v1/admin/")):
        response.headers["Cache-Control"] = "no-store"
    return response


@app.exception_handler(StarletteHTTPException)
async def translated_http_error(request: Request, exc: StarletteHTTPException):
    code, message = error_message(exc.detail, request_language(request))
    return JSONResponse({"detail": message, "code": code}, status_code=exc.status_code, headers=exc.headers)


@app.exception_handler(RequestValidationError)
async def translated_validation_error(request: Request, exc: RequestValidationError):
    english = request_language(request) == "en"
    message = (
        "Check the data and measurement limits."
        if english
        else "Revisa los datos y los límites de la medición."
    )
    # Preserve machine-readable locations and types, without echoing user input or exception objects.
    errors = [{"type": e["type"], "loc": e["loc"], "msg": message} for e in exc.errors()]
    return JSONResponse({"detail": message, "code": "validation_error", "errors": errors}, status_code=422)


@app.exception_handler(Exception)
async def translated_internal_error(request: Request, exc: Exception):
    language = request_language(request)
    logging.getLogger("circuitlab.api").error("Unhandled request error: %s", type(exc).__name__)
    message = (
        "An unexpected error occurred. Please try again."
        if language == "en"
        else "Ocurrió un error inesperado. Inténtalo de nuevo."
    )
    return JSONResponse(
        {"detail": message, "code": "internal_error"},
        status_code=500,
        headers={"Content-Language": language, "Vary": "Accept-Language"},
    )


@app.get(prefix + "/health/live")
def live():
    return {
        "status": "ok",
        "ai_mode": settings().ai_mode,
        "provider_configured": bool(settings().meta_api_key and settings().meta_reasoning_model),
    }


@app.get(prefix + "/tests/catalog")
def catalog(user=Depends(current_user), language=Depends(request_language)):
    from app.catalog import localized_voltage_test

    return [localized_voltage_test(language)]


@app.get(prefix + "/health/ready")
def ready(db: DBSession = Depends(get_db)):
    try:
        db.execute(text("SELECT 1 FROM users LIMIT 1"))
        return {"status": "ready"}
    except Exception:
        return JSONResponse({"status": "unavailable"}, status_code=503)


@app.post(prefix + "/auth/login")
def login(body: s.Login, db: DBSession = Depends(get_db)):
    user = db.scalar(select(User).where(User.email == body.email.lower()).with_for_update())
    if user and user.locked_until > time.time():
        raise HTTPException(429, "Demasiados intentos; espera 5 minutos")
    if not user or not user.active or not verify_password(body.password, user.password):
        if user:
            user.failed_attempts += 1
            if user.failed_attempts >= 5:
                user.locked_until = time.time() + 300
                user.failed_attempts = 0
            db.commit()
        raise HTTPException(401, "Correo o contraseña incorrectos")
    user.failed_attempts = 0
    result = issue_tokens(db, user.id)
    result["user"] = public_user(user)
    db.commit()
    return result


@app.post(prefix + "/auth/refresh")
def refresh(body: s.Refresh, db: DBSession = Depends(get_db)):
    token = db.get(Token, digest(body.refresh_token))
    if not token or token.kind != "refresh" or token.expires < time.time():
        raise HTTPException(401, "Renovación inválida")
    user_id = token.user_id
    user = db.scalar(select(User).where(User.id == user_id).with_for_update())
    consumed = db.scalar(
        delete(Token)
        .where(
            Token.digest == digest(body.refresh_token), Token.kind == "refresh", Token.expires > time.time()
        )
        .returning(Token.user_id)
    )
    if not user or not user.active or not consumed:
        raise HTTPException(401, "Renovación inválida")
    result = issue_tokens(db, user_id)
    result["user"] = public_user(user)
    db.commit()
    return result


@app.post(prefix + "/auth/logout", status_code=204)
def logout(user=Depends(current_user), db: DBSession = Depends(get_db)):
    for token in db.scalars(select(Token).where(Token.user_id == user.id)):
        db.delete(token)
    db.commit()
    return Response(status_code=204)


@app.post(prefix + "/sessions", status_code=201)
def create_session(
    body: s.SessionCreate,
    user=Depends(current_user),
    db: DBSession = Depends(get_db),
    language=Depends(request_language),
):
    session = Session(
        owner_id=user.id, language=body.language or language, **body.model_dump(exclude={"language"})
    )
    db.add(session)
    db.flush()
    record(db, session, "session_created", {"family": session.family})
    commit(db)
    return serialize(session)


@app.get(prefix + "/sessions")
def list_sessions(user=Depends(current_user), db: DBSession = Depends(get_db)):
    member_ids = select(Member.session_id).where(Member.user_id == user.id)
    return [
        serialize(row)
        for row in db.scalars(
            select(Session)
            .where(or_(Session.owner_id == user.id, Session.id.in_(member_ids)))
            .order_by(Session.created_at.desc())
            .limit(100)
        )
    ]


def details(db, session):
    result = serialize(session)
    for key, model in [
        ("evidence", Evidence),
        ("hypotheses", Hypothesis),
        ("measurements", Measurement),
        ("interventions", Intervention),
        ("verifications", Verification),
        ("jobs", Job),
    ]:
        rows = db.scalars(select(model).where(model.session_id == session.id).order_by(model.created_at))
        result[key] = [serialize(row) for row in rows]
    return result


@app.get(prefix + "/sessions/{session_id}")
def get_session(session_id: str, user=Depends(current_user), db: DBSession = Depends(get_db)):
    session = authorized(db, session_id, user)
    result = details(db, session)
    result["agent_trace"] = stories.agent_trace(db, session.id)
    result["storyboards"] = stories.stories_for(db, session)
    result["storyboard_available"] = stories.configured()
    result["storyboard_mode"] = settings().storyboard_mode
    result["can_edit"] = result["owner_id"] == user.id
    return result


@app.post(prefix + "/sessions/{session_id}/storyboards", status_code=202)
def create_story(session_id: str, user=Depends(current_user), db: DBSession = Depends(get_db)):
    session = authorized(db, session_id, user, write=True)
    if session.state not in {"resolved", "inconclusive"} or not session.analysis_steps:
        raise HTTPException(409, "Completa el diagnóstico antes de crear la historia")
    if not stories.configured():
        raise HTTPException(503, "La creación de historias no está disponible")
    snapshot = stories.source_snapshot(db, session)
    fingerprint = stories.source_hash(snapshot)
    row = db.scalar(select(Storyboard).where(Storyboard.session_id == session_id,
                                             Storyboard.source_sha256 == fingerprint))
    if row:
        job = db.get(Job, row.job_id)
        if job.status == "failed":
            job.status, job.error, job.lease_token = "pending", None, None
            job.lease_until, job.attempts = time.time(), 0
            record(db, session, "story_requested", {"story_id": row.id, "retry": True})
            commit(db)
        return stories.public_story(db, row, fingerprint)
    active = db.scalar(select(Job).where(Job.session_id == session_id, Job.status.in_(["pending", "running"])))
    if active:
        raise HTTPException(409, "Ya existe un trabajo pendiente")
    job = Job(session_id=session_id, kind="storyboard", lease_until=time.time())
    db.add(job)
    db.flush()
    row = Storyboard(session_id=session_id, job_id=job.id, snapshot=snapshot,
                     source_sha256=fingerprint, source_version=session.version)
    db.add(row)
    db.flush()
    record(db, session, "story_requested", {"story_id": row.id})
    commit(db)
    return stories.public_story(db, row, fingerprint)


@app.patch(prefix + "/sessions/{session_id}/specification")
def specification(
    session_id: str, body: s.Specification, user=Depends(current_user), db: DBSession = Depends(get_db)
):
    session = authorized(db, session_id, user, write=True)
    if session.version != body.version:
        raise HTTPException(409, "Versión desactualizada; recarga la sesión")
    if (
        session.state not in {"draft", "ready", "awaiting_evidence", "awaiting_confirmation"}
        or session.analysis_steps
    ):
        raise HTTPException(409, "Los criterios quedan fijados al iniciar el diagnóstico")
    if any(p.max_v > session.supply_v for p in body.points):
        raise HTTPException(422, "El criterio supera la alimentación declarada")
    session.specification = body.model_dump(exclude={"version"})
    session.spec_version += 1
    record(
        db,
        session,
        "specification_confirmed",
        {"spec_version": session.spec_version, "specification": session.specification},
    )
    if session.state != "ready":
        transition(db, session, "ready", "human_confirmation")
    commit(db)
    return serialize(session)


@app.post(prefix + "/sessions/{session_id}/evidence", status_code=201)
async def upload(
    session_id: str,
    client_id: str = Form(min_length=8, max_length=80),
    file: UploadFile = File(),
    user=Depends(current_user),
    db: DBSession = Depends(get_db),
):
    session = authorized(db, session_id, user, write=True)
    existing = db.scalar(
        select(Evidence).where(Evidence.session_id == session_id, Evidence.client_id == client_id)
    )
    if existing:
        return serialize(existing)
    if session.state in {"resolved", "cancelled", "inconclusive", "analyzing"}:
        raise HTTPException(409, "La sesión no admite evidencia en este estado")
    limit = image_limit(settings()) if session.diagnosis_mode == "meta" else 12
    if len(list(db.scalars(select(Evidence.id).where(Evidence.session_id == session_id)))) >= limit:
        raise HTTPException(422, "Máximo 8 imágenes con este proveedor" if limit == 8 else "Máximo 12 imágenes por sesión")
    raw = await file.read(settings().max_upload_mb * 1024 * 1024 + 1)
    if len(raw) > settings().max_upload_mb * 1024 * 1024:
        raise HTTPException(413, "Imagen demasiado grande")
    storage = LocalStorage()
    key, sha, mime, size = storage.save(raw)
    evidence = Evidence(session_id=session_id, client_id=client_id, key=key, mime=mime, sha256=sha, size=size)
    try:
        db.add(evidence)
        db.flush()
        record(db, session, "evidence_added", {"evidence_id": evidence.id, "source": "human_upload"})
        commit(db)
    except Exception:
        db.rollback()
        storage.delete(key)
        raise
    return serialize(evidence)


@app.get(prefix + "/sessions/{session_id}/evidence/{evidence_id}")
def download(session_id: str, evidence_id: str, user=Depends(current_user), db: DBSession = Depends(get_db)):
    authorized(db, session_id, user)
    evidence = db.get(Evidence, evidence_id)
    if not evidence or evidence.session_id != session_id:
        raise HTTPException(404, "Evidencia inexistente")
    return Response(
        LocalStorage().get(evidence.key),
        media_type=evidence.mime,
        headers={"Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"},
    )


@app.post(prefix + "/sessions/{session_id}/analysis", status_code=202)
def analysis(
    session_id: str,
    user=Depends(current_user),
    db: DBSession = Depends(get_db),
    language=Depends(request_language),
):
    session = authorized(db, session_id, user, write=True)
    if session.state != "analyzing":
        session.language = language
    if session.diagnosis_mode == "meta":
        count = len(list(db.scalars(select(Evidence.id).where(Evidence.session_id == session_id))))
        if count > image_limit(settings()):
            raise HTTPException(422, "Demasiadas imágenes para el proveedor seleccionado")
    job = enqueue(db, session)
    commit(db)
    return {"job_id": job.id, "status": job.status}


@app.get(prefix + "/jobs/{job_id}")
def get_job(job_id: str, user=Depends(current_user), db: DBSession = Depends(get_db)):
    job = db.get(Job, job_id)
    if not job:
        raise HTTPException(404, "Trabajo inexistente")
    authorized(db, job.session_id, user)
    return serialize(job)


@app.get(prefix + "/sessions/{session_id}/events")
def events(session_id: str, after: int = 0, user=Depends(current_user), db: DBSession = Depends(get_db)):
    authorized(db, session_id, user)
    return [
        serialize(e)
        for e in db.scalars(
            select(Event)
            .where(Event.session_id == session_id, Event.sequence > after)
            .order_by(Event.sequence)
            .limit(500)
        )
    ]


def validate_measurement(session, point_id, measured_at):
    if point_id not in {p["id"] for p in session.specification.get("points", [])}:
        raise HTTPException(422, "Punto no autorizado por el esquema")
    if measured_at > time.time() + 30 or measured_at < session.created_at:
        raise HTTPException(422, "Fecha de captura inválida")
    if session.state not in {"awaiting_measurement", "verifying"}:
        raise HTTPException(409, "La sesión no espera una medición")
    if session.state == "awaiting_measurement" and point_id != (session.pending_test or {}).get("point_id"):
        raise HTTPException(422, "Registra el punto solicitado por la prueba")
    if session.state == "verifying":
        intervention = session.pending_test or {}
        if measured_at < intervention.get("after", time.time()):
            raise HTTPException(422, "La verificación requiere lecturas posteriores a la intervención")


def measurement_added(db, session, measurement):
    db.add(measurement)
    db.flush()
    record(
        db,
        session,
        "measurement_recorded",
        {"measurement_id": measurement.id, "point_id": measurement.point_id, "source": measurement.source},
    )
    if session.state == "awaiting_measurement":
        transition(db, session, "analyzing", "measurement_received")
        job = Job(session_id=session.id, kind="analysis")
        db.add(job)


@app.post(prefix + "/sessions/{session_id}/measurements", status_code=201)
def manual(
    session_id: str,
    body: s.ManualMeasurement,
    user=Depends(current_user),
    db: DBSession = Depends(get_db),
    language=Depends(request_language),
):
    session = authorized(db, session_id, user, write=True)
    existing = db.scalar(
        select(Measurement).where(
            Measurement.session_id == session_id, Measurement.client_id == body.client_id
        )
    )
    if existing:
        return serialize(existing)
    validate_measurement(session, body.point_id, body.measured_at)
    session.language = language
    value = body.value / 1000 if body.unit == "mV" else body.value
    measurement = Measurement(
        session_id=session_id,
        client_id=body.client_id,
        point_id=body.point_id,
        value=value,
        unit="V",
        source="manual",
        measured_at=body.measured_at,
        phase="verification" if session.state == "verifying" else "diagnosis",
    )
    measurement_added(db, session, measurement)
    commit(db)
    return serialize(measurement)


@app.post(prefix + "/sessions/{session_id}/interventions", status_code=201)
def intervention(
    session_id: str, body: s.InterventionCreate, user=Depends(current_user), db: DBSession = Depends(get_db)
):
    session = authorized(db, session_id, user, write=True)
    if session.state != "awaiting_intervention":
        raise HTTPException(409, "La sesión no espera una intervención")
    row = Intervention(session_id=session_id, description=body.description, confirmed_by=user.id)
    db.add(row)
    db.flush()
    session.pending_test = {
        "after": row.created_at,
        "instruction": session.specification["functional_description"],
    }
    record(db, session, "intervention_confirmed", {"intervention_id": row.id, "description": row.description})
    transition(db, session, "verifying", "human_intervention_confirmed")
    commit(db)
    return serialize(row)


@app.post(prefix + "/sessions/{session_id}/confirmation")
def confirm_connection(
    session_id: str,
    body: s.ConnectionConfirmation,
    user=Depends(current_user),
    db: DBSession = Depends(get_db),
):
    session = authorized(db, session_id, user, write=True)
    if session.state != "awaiting_confirmation":
        raise HTTPException(409, "La sesión no espera una confirmación")
    record(db, session, "connection_confirmed", {"description": body.description, "confirmed_by": user.id})
    transition(db, session, "ready", "human_connection_confirmation")
    commit(db)
    return serialize(session)


@app.post(prefix + "/sessions/{session_id}/verification", status_code=202)
def verify(session_id: str, user=Depends(current_user), db: DBSession = Depends(get_db)):
    session = authorized(db, session_id, user, write=True)
    if session.state != "verifying":
        raise HTTPException(409, "Primero confirma la intervención humana")
    measurements = list(
        db.scalars(
            select(Measurement).where(
                Measurement.session_id == session_id, Measurement.phase == "verification"
            )
        )
    )
    missing = {p["id"] for p in session.specification["points"]} - {m.point_id for m in measurements}
    if missing:
        raise HTTPException(409, f"Faltan medidas posteriores para: {', '.join(sorted(missing))}")
    job = enqueue(db, session, "verification")
    commit(db)
    return {"job_id": job.id, "status": job.status}


@app.get(prefix + "/sessions/{session_id}/report")
def report(
    session_id: str,
    user=Depends(current_user),
    db: DBSession = Depends(get_db),
    language=Depends(request_language),
    format: Literal["json", "markdown"] = Query(default="json"),
):
    session = authorized(db, session_id, user)
    result = details(db, session)
    result["events"] = [
        serialize(e)
        for e in db.scalars(select(Event).where(Event.session_id == session_id).order_by(Event.sequence))
    ]
    result["model_runs"] = [
        serialize(r) for r in db.scalars(select(ModelRun).where(ModelRun.session_id == session_id))
    ]
    result = prepare_report(result, language)
    result["storyboards"] = stories.stories_for(db, session)
    if format == "markdown":
        return Response(
            render_markdown(result, language),
            media_type="text/markdown",
            headers={"Content-Language": language},
        )
    return result


@app.post(prefix + "/sessions/{session_id}/pairing", status_code=201)
def pair(session_id: str, user=Depends(current_user), db: DBSession = Depends(get_db)):
    authorized(db, session_id, user, write=True)
    code = secrets.token_urlsafe(24)
    db.add(Pairing(digest=digest(code), session_id=session_id, expires=time.time() + 300))
    db.commit()
    return {"code": code, "expires_in": 300, "role": "reader"}


@app.post(prefix + "/pairing/redeem")
def redeem(body: dict[str, str], user=Depends(current_user), db: DBSession = Depends(get_db)):
    # Single API process MVP. High-entropy codes remain the primary protection;
    # the sliding window also limits authenticated guessing attempts.
    with pairing_lock:
        attempts = pairing_attempts[user.id]
        while attempts and attempts[0] < time.monotonic() - 300:
            attempts.popleft()
        if len(attempts) >= 5:
            raise HTTPException(429, "Demasiados intentos de invitación; espera 5 minutos")
        attempts.append(time.monotonic())
    pairing = db.scalar(
        select(Pairing).where(Pairing.digest == digest(body.get("code", ""))).with_for_update()
    )
    if not pairing or pairing.used or pairing.expires < time.time():
        raise HTTPException(422, "Invitación inválida o vencida")
    pairing.used = 1
    if not db.get(Member, (pairing.session_id, user.id)):
        db.add(Member(session_id=pairing.session_id, user_id=user.id, role="reader"))
    db.commit()
    with pairing_lock:
        pairing_attempts.pop(user.id, None)
    return {"session_id": pairing.session_id}


@app.post(prefix + "/devices/enroll", status_code=201)
def enroll(body: s.Enroll, user=Depends(current_user), db: DBSession = Depends(get_db)):
    if not set(body.points).issubset({"TP1", "TP2", "TP3"}):
        raise HTTPException(422, "Firmware v1 admite TP1, TP2, TP3")
    if body.simulated and settings().app_env == "production":
        raise HTTPException(422, "Simulación deshabilitada en producción")
    token = secrets.token_urlsafe(48)
    device = Device(
        owner_id=user.id,
        name=body.name,
        points=body.points,
        calibration_id=body.calibration_id,
        simulated=int(body.simulated),
        token_digest=digest(token),
    )
    db.add(device)
    db.commit()
    return {"device_id": device.id, "device_token": token}


@app.get(prefix + "/devices")
def devices(user=Depends(current_user), db: DBSession = Depends(get_db)):
    return [
        {k: v for k, v in serialize(d).items() if k != "token_digest"}
        for d in db.scalars(select(Device).where(Device.owner_id == user.id))
    ]


@app.post(prefix + "/devices/{device_id}/revoke", status_code=204)
def revoke(device_id: str, user=Depends(current_user), db: DBSession = Depends(get_db)):
    device = db.get(Device, device_id)
    if not device or device.owner_id != user.id:
        raise HTTPException(403, "Dispositivo no autorizado")
    device.token_digest = digest(secrets.token_urlsafe(48))
    db.commit()
    return Response(status_code=204)


@app.post(prefix + "/sessions/{session_id}/hardware", status_code=202)
def request_hardware(
    session_id: str,
    body: s.HardwareRequest,
    user=Depends(current_user),
    db: DBSession = Depends(get_db),
    language=Depends(request_language),
):
    session = authorized(db, session_id, user, write=True)
    validate_measurement(session, body.point_id, time.time())
    session.language = language
    device = db.get(Device, body.device_id)
    if not device or device.owner_id != user.id or body.point_id not in device.points:
        raise HTTPException(403, "Dispositivo o punto no autorizado")
    if not device.last_seen or device.last_seen < time.time() - 15:
        raise HTTPException(409, "Bridge desconectado")
    active = db.scalar(
        select(Command).where(Command.session_id == session_id, Command.status.in_(["pending", "sent"]))
    )
    if active:
        raise HTTPException(409, "Ya existe un comando pendiente")
    command_id = uid()
    payload = s.HardwareCommand(
        command_id=command_id, session_id=session_id, device_id=device.id, point_id=body.point_id
    ).model_dump()
    command = Command(
        id=command_id,
        session_id=session_id,
        device_id=device.id,
        payload=payload,
        deadline=time.time() + settings().hardware_command_timeout_seconds,
    )
    db.add(command)
    record(db, session, "hardware_requested", payload)
    commit(db)
    return {"command_id": command_id}


def accept_result(db, device, result):
    command = db.scalar(select(Command).where(Command.id == result.command_id).with_for_update())
    if not command or command.device_id != device.id or command.status not in {"pending", "sent"}:
        return
    session = db.scalar(select(Session).where(Session.id == command.session_id).with_for_update())
    if command.deadline < time.time():
        command.status = "timeout"
        record(db, session, "hardware_failed", {"command_id": command.id, "status": "timeout"})
        return
    if (
        result.point_id != command.payload["point_id"]
        or result.calibration_id != device.calibration_id
        or (result.source == "simulated") != bool(device.simulated)
        or (result.status == "ok" and result.sample_count != command.payload["sample_count"])
        or result.measured_at < command.created_at - 1
        or result.measured_at > time.time() + 30
    ):
        raise ValueError("Resultado incompatible con el comando o calibración")
    if result.status == "ok":
        validate_measurement(session, result.point_id, result.measured_at)
        measurement_added(
            db,
            session,
            Measurement(
                session_id=session.id,
                client_id=command.id,
                point_id=result.point_id,
                value=result.value,
                unit="V",
                source=result.source,
                measured_at=result.measured_at,
                calibration_id=result.calibration_id,
                phase="verification" if session.state == "verifying" else "diagnosis",
            ),
        )
    command.status = result.status
    command.result = result.model_dump()
    record(db, session, "hardware_result", result.model_dump())


@app.websocket(prefix + "/devices/connect")
async def connect(websocket: WebSocket):
    import asyncio
    from fastapi import WebSocketDisconnect

    auth = websocket.headers.get("authorization", "")
    credential = digest(auth.removeprefix("Bearer "))
    with SessionLocal() as db:
        device = db.scalar(select(Device).where(Device.token_digest == credential))
        if not device:
            await websocket.close(code=4401)
            return
        device_id = device.id
    await websocket.accept()
    try:
        while True:
            outgoing = []
            with SessionLocal() as db:
                device = db.get(Device, device_id)
                if device.token_digest != credential:
                    await websocket.close(code=4401)
                    return
                device.last_seen = time.time()
                for command in db.scalars(
                    select(Command)
                    .where(Command.device_id == device_id, Command.status.in_(["pending", "sent"]))
                    .with_for_update()
                ):
                    if command.deadline < time.time():
                        command.status = "timeout"
                        session = db.scalar(
                            select(Session).where(Session.id == command.session_id).with_for_update()
                        )
                        record(
                            db, session, "hardware_failed", {"command_id": command.id, "status": "timeout"}
                        )
                    elif command.status == "pending":
                        command.status = "sent"
                        outgoing.append(command.payload)
                db.commit()
            for payload in outgoing:
                await websocket.send_json(payload)
            try:
                incoming = await asyncio.wait_for(websocket.receive_json(), timeout=2)
            except TimeoutError:
                continue
            try:
                result = s.HardwareResult.model_validate(incoming)
                with SessionLocal() as db:
                    device = db.get(Device, device_id)
                    accept_result(db, device, result)
                    db.commit()
                await websocket.send_json({"ack": result.command_id})
            except (ValueError, HTTPException):
                await websocket.send_json({"error": "invalid_result"})
    except WebSocketDisconnect:
        pass
