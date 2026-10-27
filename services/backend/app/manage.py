import argparse
import getpass
from sqlalchemy import select
from app.db import AccountEvent, SessionLocal, User
from app.security import hash_password


def main():
    parser = argparse.ArgumentParser(description="Administración local de CircuitLab")
    parser.add_argument("command", choices=["create-user", "promote-admin"])
    parser.add_argument("--email", required=True)
    parser.add_argument("--language", choices=["es", "en"], default="es")
    parser.add_argument("--admin", action="store_true", help="Create an administrator")
    args = parser.parse_args()
    english = args.language == "en"
    if args.command == "promote-admin":
        with SessionLocal() as db:
            user = db.scalar(select(User).where(User.email == args.email.strip().lower()).with_for_update())
            if not user or not user.active:
                parser.error("Active user not found" if english else "No se encontró una cuenta activa")
            user.role = "admin"
            db.add(AccountEvent(user_id=user.id, kind="admin_promoted_locally", data={}))
            db.commit()
        print("Administrator enabled." if english else "Administración habilitada.")
        return
    password = getpass.getpass(
        "Password (at least 12 characters): " if english else "Contraseña (mínimo 12 caracteres): "
    )
    if not 12 <= len(password) <= 200:
        parser.error(
            "The password must have between 12 and 200 characters"
            if english
            else "La contraseña debe tener entre 12 y 200 caracteres"
        )
    with SessionLocal() as db:
        if db.scalar(select(User).where(User.email == args.email.strip().lower())):
            parser.error("The user already exists" if english else "El usuario ya existe")
        from app.schemas import AccountCreate

        try:
            body = AccountCreate(
                email=args.email, password=password, role="admin" if args.admin else "member"
            )
        except ValueError:
            parser.error("Invalid email or password" if english else "Correo o contraseña inválidos")
        user = User(email=body.email, password=hash_password(password), role=body.role)
        db.add(user)
        db.flush()
        db.add(AccountEvent(user_id=user.id, kind="user_created_locally", data={"role": user.role}))
        db.commit()
    print("User created." if english else "Usuario creado.")


if __name__ == "__main__":
    main()
