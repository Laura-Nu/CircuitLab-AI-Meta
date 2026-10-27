"""Outbound authenticated WSS transport with a durable at-most-once execution journal."""
import asyncio
import json
import os
import sqlite3
import time
from pathlib import Path
import serial
from websockets.asyncio.client import connect


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


def failed(command, calibration, simulated, status="timeout"):
    return {"protocol_version": "1", "command_id": command["command_id"], "status": status,
        "point_id": command["point_id"], "value": None, "unit": "V", "sample_count": 0,
        "source": "simulated" if simulated else "instrumented", "calibration_id": calibration,
        "measured_at": time.time()}


def acquire(command, config):
    simulated = bool(config.get("simulate", False))
    calibration = config["calibration_id"]
    allowed = (command.get("protocol_version") == "1" and command.get("action") == "read_voltage"
        and command.get("device_id") == config["device_id"]
        and command.get("point_id") in config["points"]
        and 1 <= command.get("sample_count", 0) <= 100
        and 100 <= command.get("deadline_ms", 0) <= 10000)
    if not allowed:
        return failed(command, calibration, simulated, "precondition_failed")
    if simulated:
        return {**failed(command, calibration, True), "status": "ok", "sample_count": command["sample_count"],
                "value": float(config.get("simulated_values", {}).get(command["point_id"], 2.5))}
    try:
        # Never upload or execute user firmware. This speaks only the fixed instrument protocol.
        with serial.Serial(config["serial_port"], config.get("baudrate", 115200), timeout=0.2) as port:
            time.sleep(2)  # UNO resets when opening the port; configured deadline includes this.
            port.reset_input_buffer()
            port.write((json.dumps(command) + "\n").encode())
            deadline = time.monotonic() + command["deadline_ms"] / 1000
            while time.monotonic() < deadline:
                line = port.readline()
                if not line:
                    continue
                result = json.loads(line)
                if result.get("command_id") != command["command_id"]:
                    continue
                if result.get("status") != "ok":
                    return failed(command, calibration, False, result.get("status", "out_of_range"))
                value = float(result["value"])
                if not 0 <= value <= 5:
                    return failed(command, calibration, False, "out_of_range")
                return {**failed(command, calibration, False), "status": "ok", "value": value,
                        "sample_count": result["sample_count"]}
    except (serial.SerialException, OSError):
        return failed(command, calibration, False, "disconnected")
    except (ValueError, KeyError):
        return failed(command, calibration, False, "out_of_range")
    return failed(command, calibration, False)


async def run(config):
    english = config.get("language", "es") == "en"
    url = config["url"]
    if not url.startswith("wss://") and not url.startswith(("ws://localhost:", "ws://127.0.0.1:")):
        raise ValueError("Use WSS outside localhost" if english else "Usa WSS fuera de localhost")
    journal = Journal(config.get("journal", "bridge-state.sqlite3"))
    delay = 1
    while True:
        try:
            async with connect(url, additional_headers={"Authorization": f"Bearer {config['device_token']}"},
                               max_size=32_768) as socket:
                delay = 1
                async for message in socket:
                    command = json.loads(message)
                    if "command_id" not in command:
                        continue
                    fresh, result = journal.reserve(command["command_id"])
                    if fresh:
                        result = await asyncio.to_thread(acquire, command, config)
                        journal.finish(command["command_id"], result)
                    elif result is None:
                        # A crash may have happened during acquisition: do not repeat it.
                        result = failed(command, config["calibration_id"], config.get("simulate", False))
                        journal.finish(command["command_id"], result)
                    await socket.send(json.dumps(result))
        except (OSError, ValueError) as exc:
            print((f"Bridge disconnected ({type(exc).__name__}); retrying in {delay}s" if english
                   else f"Bridge desconectado ({type(exc).__name__}); reintento en {delay}s"), flush=True)
        except Exception as exc:
            print((f"Transport unavailable ({type(exc).__name__})" if english
                   else f"Transporte no disponible ({type(exc).__name__})"), flush=True)
        await asyncio.sleep(delay)
        delay = min(delay * 2, 30)


def main():
    path = Path(os.environ.get("BRIDGE_CONFIG", "credentials.json"))
    config = json.loads(path.read_text(encoding="utf-8"))
    english = config.get("language", "es") == "en"
    print(("SIMULATION" if english else "SIMULACIÓN") if config.get("simulate")
          else ("INSTRUMENTED ACQUISITION" if english else "ADQUISICIÓN INSTRUMENTADA"), flush=True)
    asyncio.run(run(config))


if __name__ == "__main__":
    main()
