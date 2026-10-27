"""Adapter selection is explicit and cannot switch after a real instrument failure."""
from .serial import SerialAdapter
from .simulated import SimulatedAdapter


def adapter_for(config):
    mode = config.get("simulate", False)
    if not isinstance(mode, bool):
        raise ValueError("simulate must be a JSON boolean")
    return SimulatedAdapter(config) if mode else SerialAdapter(config)
