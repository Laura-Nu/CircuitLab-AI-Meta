import hashlib
import io
from pathlib import Path
from typing import Protocol
from PIL import Image, UnidentifiedImageError
from fastapi import HTTPException
from app.config import settings
from app.db import uid


class Storage(Protocol):
    def save(self, data: bytes) -> tuple[str, str, str, int]: ...
    def get(self, key: str) -> bytes: ...
    def delete(self, key: str) -> None: ...


class LocalStorage:
    def __init__(self):
        self.root = Path(settings().storage_root).resolve()
        self.root.mkdir(parents=True, exist_ok=True)

    def path(self, key):
        if len(key) != 36 or any(c not in "0123456789abcdef-" for c in key):
            raise ValueError("Invalid storage key")
        return self.root / key

    def save(self, data):
        try:
            with Image.open(io.BytesIO(data)) as image:
                if image.format not in {"JPEG", "PNG"} or image.width * image.height > 20_000_000:
                    raise ValueError("Solo JPEG/PNG de hasta 20 megapíxeles")
                image.load()
                output = io.BytesIO()
                image.convert("RGB").save(output, format="JPEG", quality=90)
                clean = output.getvalue()
        except (UnidentifiedImageError, OSError, ValueError, Image.DecompressionBombError):
            raise HTTPException(422, "Imagen inválida; utiliza JPEG o PNG de hasta 20 MP")
        key = uid()
        self.path(key).write_bytes(clean)
        return key, hashlib.sha256(clean).hexdigest(), "image/jpeg", len(clean)

    def get(self, key):
        return self.path(key).read_bytes()

    def delete(self, key):
        self.path(key).unlink(missing_ok=True)
