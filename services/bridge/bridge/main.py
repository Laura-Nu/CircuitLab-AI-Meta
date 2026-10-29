"""Outbound authenticated WSS transport with a durable at-most-once execution journal."""
import asyncio
import json
import os
import sqlite3
from pathlib import Path
from bridge.adapters import adapter_for
from bridge.adapters.base import failed
from websockets.asyncio.client import connect
from websockets.exceptions import InvalidStatus, ConnectionClosed


class Journal:
    def __init__(self, path):
        self.db = sqlite3.connect(path)
        self.db.execute("CREATE TABLE IF NOT EXISTS results (id TEXT PRIMARY KEY, result TEXT)")
        self.db.commit()

    def reserve(self, command_id):
        row = self.db.execute("SELECT result FROM results WHERE id=?", (command_id,)).fetchone()
        if row:
            return False, json.loads(row[0]) if row[0] else None
        self.db.execute("INSERT INTO results VALUES (?, NULL)", (command_id,))
        self.db.commit()
        return True, None

    def finish(self, command_id, result):
        self.db.execute("UPDATE results SET result=? WHERE id=?", (json.dumps(result), command_id))
        self.db.commit()


def acquire(command, config):
    return adapter_for(config).read(command)


async def run(config, on_event=None):
    english = config.get("language", "es") == "en"
    url = config["url"]
    if not url.startswith("wss://") and not url.startswith(("ws://localhost:", "ws://127.0.0.1:")):
        raise ValueError("Use WSS outside localhost" if english else "Usa WSS fuera de localhost")

    def emit(state, **details):
        if on_event is not None:
            on_event(state, details)
        elif state == "retrying":
            print(("Bridge disconnected; retrying" if english else "Bridge desconectado; reintentando"), flush=True)
        elif state == "unauthorized":
            print(("Bridge credential rejected" if english else "Credencial del bridge rechazada"), flush=True)
        elif state == "connected":
            print(("Connected to CircuitLab; waiting for a reading request" if english
                   else "Conectado a CircuitLab; esperando una solicitud de lectura"), flush=True)

    journal = Journal(config.get("journal", "bridge-state.sqlite3"))
    delay = 1
    try:
        while True:
            emit("connecting")
            try:
                async with connect(url, additional_headers={"Authorization": f"Bearer {config['device_token']}"},
                                   max_size=32_768, open_timeout=10) as socket:
                    delay = 1
                    emit("connected")
                    async for message in socket:
                        command = json.loads(message)
                        if "command_id" not in command:
                            continue
                        fresh, result = journal.reserve(command["command_id"])
                        if fresh:
                            emit("reading", point=command.get("point_id"))
                            result = await asyncio.to_thread(acquire, command, config)
                            journal.finish(command["command_id"], result)
                        elif result is None:
                            result = failed(command, config["calibration_id"], config.get("simulate", False))
                            journal.finish(command["command_id"], result)
                        await socket.send(json.dumps(result))
                        emit("result", status=result["status"], point=result["point_id"])
                        emit("connected")
            except (InvalidStatus, ConnectionClosed) as exc:
                status = exc.response.status_code if isinstance(exc, InvalidStatus) else (
                    exc.rcvd.code if exc.rcvd else None
                )
                if status in {401, 403, 4401}:
                    emit("unauthorized")
                    return
            except (OSError, ValueError):
                pass
            except Exception:
                # Exceptions may contain URLs/headers; never send their text to logs or the desktop UI.
                pass
            emit("retrying", seconds=delay)
            await asyncio.sleep(delay)
            delay = min(delay * 2, 30)
    finally:
        journal.db.close()
        emit("stopped")


def main():
    path = Path(os.environ.get("BRIDGE_CONFIG", "credentials.json"))
    config = json.loads(path.read_text(encoding="utf-8"))
    english = config.get("language", "es") == "en"
    print(("SIMULATION" if english else "SIMULACIÓN") if config.get("simulate")
          else ("INSTRUMENTED ACQUISITION" if english else "ADQUISICIÓN INSTRUMENTADA"), flush=True)
    asyncio.run(run(config))


if __name__ == "__main__":
    main()
