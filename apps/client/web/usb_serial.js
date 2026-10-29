/* Fixed read-only instrument protocol. No credentials, firmware upload or arbitrary serial console. */
(() => {
  "use strict";
  let port = null, reader = null, writer = null, reading = null, pending = null;
  let buffer = "", closing = null;
  const seen = new Map();
  const api = {
    get supported() { return !!(globalThis.isSecureContext && navigator.serial?.requestPort); },
    onDisconnect: null,
    async connect() {
      if (!api.supported) return JSON.stringify({status: "unsupported"});
      if (port || closing) return JSON.stringify({status: "busy"});
      let selected;
      try {
        // Must be invoked directly by the user's Connect button, before any API request.
        selected = await navigator.serial.requestPort();
        await selected.open({baudRate: 115200, bufferSize: 4096});
        port = selected; buffer = ""; seen.clear();
        reader = port.readable.getReader();
        reading = readLoop(reader, selected);
        await new Promise(resolve => setTimeout(resolve, 2000)); // UNO resets when opening USB.
        if (port !== selected) return JSON.stringify({status: "disconnected"});
        buffer = "";
        return JSON.stringify({status: "connected"});
      } catch (error) {
        if (selected && selected === port) await api.disconnect();
        return JSON.stringify({status: error?.name === "NotFoundError" ? "cancelled"
          : error?.name === "SecurityError" ? "permission_denied" : "port_unavailable"});
      }
    },
    async disconnect() {
      if (closing) return closing;
      const previous = port, previousReader = reader, previousWriter = writer;
      port = null; reader = null; writer = null;
      settle({status: "disconnected", sample_count: 0});
      closing = (async () => {
        try { await previousReader?.cancel(); } catch (_) {}
        try { await previousWriter?.abort(); } catch (_) {}
        try { await reading; } catch (_) {}
        try { await previous?.close(); } catch (_) {}
        reading = null; buffer = ""; seen.clear();
      })();
      try { await closing; } finally { closing = null; }
    },
    async read(raw, allowedRaw) {
      let command, allowed;
      try { command = JSON.parse(raw); allowed = JSON.parse(allowedRaw); }
      catch (_) { return JSON.stringify({status: "precondition_failed", sample_count: 0}); }
      if (!command || !Array.isArray(allowed) || command.protocol_version !== "1" || command.action !== "read_voltage" ||
          typeof command.command_id !== "string" || command.command_id.length > 64 ||
          !["TP1", "TP2", "TP3"].includes(command.point_id) || !allowed.includes(command.point_id) ||
          !Number.isInteger(command.sample_count) || command.sample_count < 1 || command.sample_count > 100 ||
          !Number.isInteger(command.deadline_ms) || command.deadline_ms < 100 || command.deadline_ms > 10000) {
        return JSON.stringify({status: "precondition_failed", sample_count: 0});
      }
      if (seen.has(command.command_id)) {
        return JSON.stringify(seen.get(command.command_id) || {status: "timeout", sample_count: 0});
      }
      if (!port) return JSON.stringify({status: "disconnected", sample_count: 0});
      if (pending || seen.size >= 4096) return JSON.stringify({status: "precondition_failed", sample_count: 0});
      seen.set(command.command_id, null); // Reserve before touching USB; never reacquire the same command.
      const current = port;
      const result = new Promise(resolve => {
        pending = {command, resolve, timer: setTimeout(() => settle({status: "timeout", sample_count: 0}), command.deadline_ms)};
      });
      try {
        writer = current.writable.getWriter();
        // Only this validated fixed command is sent, never arbitrary user or model text.
        await Promise.race([writer.write(new TextEncoder().encode(JSON.stringify(command) + "\n")), result]);
      } catch (_) {
        settle({status: "disconnected", sample_count: 0});
      } finally {
        try { writer?.releaseLock(); } catch (_) {}
        writer = null;
      }
      return JSON.stringify(await result);
    }
  };
  function settle(result) {
    if (!pending) return;
    const request = pending; pending = null; clearTimeout(request.timer);
    seen.set(request.command.command_id, result);
    request.resolve(result);
  }
  function line(raw) {
    if (!pending) return;
    let result;
    try { result = JSON.parse(raw); } catch (_) { return; }
    const command = pending.command;
    if (result.command_id !== command.command_id) return;
    if (result.point_id !== command.point_id) {
      settle({status: "precondition_failed", sample_count: 0}); return;
    }
    if (result.status !== "ok") {
      settle({status: ["timeout","disconnected","out_of_range","precondition_failed"].includes(result.status)
        ? result.status : "out_of_range", sample_count: 0}); return;
    }
    if (typeof result.value !== "number" || !Number.isFinite(result.value) || result.value < 0 ||
        result.value > 5 || result.sample_count !== command.sample_count) {
      settle({status: "out_of_range", sample_count: 0}); return;
    }
    settle({status: "ok", value: result.value, sample_count: result.sample_count});
  }
  async function readLoop(input, selected) {
    const decoder = new TextDecoder();
    try {
      while (port === selected) {
        const {value, done} = await input.read();
        if (done) break;
        buffer += decoder.decode(value, {stream: true});
        if (buffer.length > 8192) {
          buffer = ""; settle({status: "out_of_range", sample_count: 0}); continue;
        }
        let end;
        while ((end = buffer.indexOf("\n")) >= 0) {
          const raw = buffer.slice(0, end); buffer = buffer.slice(end + 1);
          if (raw.length <= 4096) line(raw);
        }
      }
    } catch (_) { /* Port removal is reported through the same explicit disconnect path. */ }
    finally {
      try { input.releaseLock(); } catch (_) {}
      if (port === selected) {
        queueMicrotask(async () => {
          await api.disconnect();
          api.onDisconnect?.();
        });
      }
    }
  }
  globalThis.addEventListener("pagehide", () => { void api.disconnect(); });
  document.addEventListener("visibilitychange", () => {
    if (document.hidden && port) {
      void api.disconnect().then(() => api.onDisconnect?.());
    }
  });
  globalThis.circuitLabUsb = api;
})();
