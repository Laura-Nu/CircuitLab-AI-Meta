import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "services/backend"))
from sqlalchemy import select  # noqa: E402
from app.db import SessionLocal, User  # noqa: E402
from app.config import settings  # noqa: E402
from app.security import hash_password  # noqa: E402

if settings().app_env != "development" or settings().ai_mode != "simulation":
    raise SystemExit("Solo se admite esta cuenta en desarrollo con simulación")
email = "demo@circuitlab.local"
password = os.environ.get("DEMO_PASSWORD", "CircuitLab-demo-2026")
with SessionLocal() as db:
    user = db.scalar(select(User).where(User.email == email))
    if not user:
        user = User(email=email, password=hash_password(password))
        db.add(user)
    user.role = "admin"
    db.commit()
print("Cuenta local disponible: " + email)
