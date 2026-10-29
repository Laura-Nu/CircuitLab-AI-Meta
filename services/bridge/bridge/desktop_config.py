"""Validate desktop enrollment without accepting arbitrary executable or file settings."""
import ctypes
from ctypes import wintypes
import hashlib
import json
import os
from pathlib import Path
from urllib.parse import urlsplit

VERSION = "0.1.0"
DEFAULT_URL = "wss://circuitlab.doc-ia.cloud/api/v1/devices/connect"


class ConfigurationError(ValueError):
    pass


def data_directory():
    return Path(os.environ.get("LOCALAPPDATA", Path.home())) / "CircuitLab" / "Bridge"


def connection_url(value):
    if not isinstance(value, str) or len(value) > 2048 or any(ord(c) < 32 for c in value):
        raise ConfigurationError("server")
    try:
        parsed = urlsplit(value)
        parsed.port
    except ValueError:
        raise ConfigurationError("server") from None
    local = parsed.hostname in {"localhost", "127.0.0.1", "::1"}
    if (parsed.scheme != "wss" and not (local and parsed.scheme == "ws")) or not parsed.hostname:
        raise ConfigurationError("server")
    if parsed.username or parsed.password or parsed.query or parsed.fragment or parsed.path != "/api/v1/devices/connect":
        raise ConfigurationError("server")
    return value


def enrollment(raw):
    try:
        data = json.loads(raw)
    except (ValueError, TypeError):
        raise ConfigurationError("credential") from None
    if not isinstance(data, dict):
        raise ConfigurationError("credential")
    for field in ["device_id", "device_token", "calibration_id"]:
        value = data.get(field)
        if not isinstance(value, str) or not value.strip() or len(value) > 256:
            raise ConfigurationError("credential")
    points = data.get("points")
    if (not isinstance(points, list) or not points or len(points) > 3
            or any(p not in ["TP1", "TP2", "TP3"] for p in points) or len(set(points)) != len(points)):
        raise ConfigurationError("credential")
    if data.get("simulate", False) is not False:
        raise ConfigurationError("simulation")
    # Deliberately ignore imported serial paths, journal paths, fixtures and other extra settings.
    return {**{field: data[field].strip() for field in ["device_id", "device_token", "calibration_id"]},
            "points": points, "url": connection_url(data.get("url", DEFAULT_URL)), "simulate": False,
            "language": "en" if data.get("language") == "en" else "es"}


def configuration(credential, port, server, language, directory):
    clean = enrollment(json.dumps(credential))
    if not isinstance(port, str) or not port.strip() or len(port) > 120:
        raise ConfigurationError("port")
    clean.update(serial_port=port.strip(), url=connection_url(server.strip()), language=language, baudrate=115200,
                 journal=str(Path(directory) / (hashlib.sha256(clean["device_id"].encode()).hexdigest()[:24]+".sqlite3")))
    return clean


class _Blob(ctypes.Structure):
    _fields_ = [("size", wintypes.DWORD), ("data", ctypes.POINTER(ctypes.c_ubyte))]


def _protect(value, decrypt=False):
    """Windows DPAPI, scoped to the current Windows user; never store plaintext credentials."""
    if os.name != "nt":
        raise OSError("Windows credential protection is required")
    buffer = ctypes.create_string_buffer(value)
    incoming = _Blob(len(value), ctypes.cast(buffer, ctypes.POINTER(ctypes.c_ubyte)))
    outgoing = _Blob()
    crypt = ctypes.WinDLL("crypt32", use_last_error=True)
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    protect = crypt.CryptUnprotectData if decrypt else crypt.CryptProtectData
    protect.argtypes = [ctypes.POINTER(_Blob), ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p,
                        ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(_Blob)]
    protect.restype = wintypes.BOOL
    kernel.LocalFree.argtypes = [ctypes.c_void_p]
    kernel.LocalFree.restype = ctypes.c_void_p
    if not protect(ctypes.byref(incoming), None, None, None, None, 1, ctypes.byref(outgoing)):
        raise OSError("Windows credential protection failed")
    try:
        return ctypes.string_at(outgoing.data, outgoing.size)
    finally:
        kernel.LocalFree(outgoing.data)


def save_settings(directory, config):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    temporary = directory / "settings.pending"
    temporary.write_bytes(_protect(json.dumps(config).encode()))
    temporary.replace(directory / "settings.dat")


def load_settings(directory):
    path = Path(directory) / "settings.dat"
    return json.loads(_protect(path.read_bytes(), decrypt=True).decode()) if path.exists() else None
