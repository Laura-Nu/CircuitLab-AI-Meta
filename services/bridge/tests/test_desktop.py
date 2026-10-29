"""Desktop setup and protocol tests; all acquisition fixtures are explicitly synthetic."""
import asyncio
import json
import os
import pytest
from websockets.asyncio.server import serve
from bridge.desktop_config import (
    ConfigurationError, DEFAULT_URL, configuration, enrollment, load_settings, save_settings,
)
from bridge import main as transport


def credential(**values):
    return {"device_id": "fixture-device", "device_token": "fixture-only-device-token",
            "calibration_id": "fixture-calibration", "points": ["TP1", "TP2"], "simulate": False, **values}


def test_enrollment_ignores_paths_and_never_enables_fixtures(tmp_path):
    data = enrollment(json.dumps(credential(serial_port="unsafe", journal="../../unexpected", simulated_values={"TP1": 5})))
    assert set(data) == {"device_id", "device_token", "calibration_id", "points", "url", "language", "simulate"}
    config = configuration(data, "COM7", DEFAULT_URL, "en", tmp_path)
    assert config["serial_port"] == "COM7" and config["simulate"] is False
    assert config["baudrate"] == 115200
    assert os.path.dirname(config["journal"]) == str(tmp_path)


@pytest.mark.parametrize("values,code", [
    ({"device_token": ""}, "credential"),
    ({"points": ["TP9"]}, "credential"),
    ({"points": [["TP1"]]}, "credential"),
    ({"points": ["TP1", "TP1"]}, "credential"),
    ({"simulate": True}, "simulation"),
    ({"simulate": "false"}, "simulation"),
    ({"url": None}, "server"),
    ({"url": ["invalid"]}, "server"),
    ({"url": "wss://example.com:invalid/api/v1/devices/connect"}, "server"),
    ({"url": "wss://example.com/\\napi/v1/devices/connect"}, "server"),
    ({"url": "ws://example.com/api/v1/devices/connect"}, "server"),
    ({"url": "wss://example.com/api/v1/devices/connect?token=private"}, "server"),
    ({"url": "wss://name:private@example.com/api/v1/devices/connect"}, "server"),
])
def test_invalid_desktop_settings_fail_without_echoing_values(values, code):
    with pytest.raises(ConfigurationError) as error:
        enrollment(json.dumps(credential(**values)))
    assert str(error.value) == code


@pytest.mark.skipif(os.name != "nt", reason="Windows DPAPI requires Windows")
def test_windows_settings_are_protected_and_round_trip(tmp_path):
    config = configuration(credential(), "COM7", DEFAULT_URL, "es", tmp_path)
    save_settings(tmp_path, config)
    assert config["device_token"].encode() not in (tmp_path / "settings.dat").read_bytes()
    assert load_settings(tmp_path) == config
    assert not (tmp_path / "settings.pending").exists()


def test_real_transport_replays_commands_without_reacquisition_and_closes_journal(tmp_path, monkeypatch):
    events = []
    calls = []
    results = []
    def acquire(command, config):
        calls.append(command["command_id"])
        return {"command_id": command["command_id"], "point_id": "TP1", "status": "ok",
                "value": 1.0, "source": "simulated", "notice": "Protocol fixture only; not hardware"}
    monkeypatch.setattr(transport, "acquire", acquire)

    async def scenario():
        async def handler(socket):
            assert socket.request.headers["Authorization"] == "Bearer fixture-only-device-token"
            command = {"command_id": "fixture-command", "point_id": "TP1"}
            for _ in range(2):
                await socket.send(json.dumps(command))
                results.append(json.loads(await socket.recv()))
            await socket.close(code=4401)
        async with serve(handler, "127.0.0.1", 0) as server:
            port = server.sockets[0].getsockname()[1]
            config = configuration(credential(), "COM7", f"ws://127.0.0.1:{port}/api/v1/devices/connect", "en", tmp_path)
            await asyncio.wait_for(transport.run(config, lambda state, data: events.append((state, data))), 5)
            journal = transport.Journal(config["journal"])
            assert journal.reserve("fixture-command")[0] is False
            journal.db.close()
    asyncio.run(scenario())
    assert calls == ["fixture-command"] and results[0] == results[1]
    assert [state for state, _ in events].count("connected") >= 1
    assert ("unauthorized", {}) in events and events[-1] == ("stopped", {})
    assert "fixture-only-device-token" not in repr(events)


def test_rejected_connection_stops_without_printing_server_details(tmp_path, capsys):
    async def scenario():
        def reject(connection, request):
            return connection.respond(401, "private server response must not be printed")
        async with serve(lambda socket: None, "127.0.0.1", 0, process_request=reject) as server:
            port = server.sockets[0].getsockname()[1]
            config = configuration(credential(), "COM7", f"ws://127.0.0.1:{port}/api/v1/devices/connect", "en", tmp_path)
            await asyncio.wait_for(transport.run(config), 5)
    asyncio.run(scenario())
    output = capsys.readouterr().out
    assert "credential rejected" in output
    assert "private server response" not in output
    assert "fixture-only-device-token" not in output

@pytest.mark.skipif(os.name != "nt", reason="Desktop Windows UI")
def test_desktop_setup_with_a_detected_port_and_rejected_input_in_both_languages(tmp_path, monkeypatch):
    import tkinter as tk
    from types import SimpleNamespace
    from bridge.desktop import BridgeWindow, TEXT
    monkeypatch.setattr("bridge.desktop.list_ports.comports",
                        lambda: [SimpleNamespace(device="COM7", description="UI fixture only")])
    root = tk.Tk()
    root.withdraw()
    try:
        window = BridgeWindow(root, tmp_path)
        # Language switching is a single-window operation, matching the packaged application.
        for language in ["en", "es"]:
            window.language.set(language.upper())
            window.translate()
            assert window.port_values[window.port.get()] == "COM7"
            assert window.connect_button.cget("text") == TEXT[language]["connect"]
            monkeypatch.setattr(root, "clipboard_get", lambda: "invalid credential")
            window.paste_credential()
            assert window.status.cget("text") == TEXT[language]["credential"]
            monkeypatch.setattr(root, "clipboard_get", lambda: json.dumps(credential(url=DEFAULT_URL)))
            window.paste_credential()
            assert window.credential_status.cget("text") == TEXT[language]["ready"]
            assert window.credential["device_id"] == "fixture-device"
            assert "fixture-only-device-token" not in window.credential_status.cget("text")
            root.update_idletasks()
    finally:
        root.destroy()
