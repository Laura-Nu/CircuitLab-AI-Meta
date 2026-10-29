/* Fixed read-only instrument protocol. No credentials, firmware upload or arbitrary serial console. */
(() => {
  "use strict";
  let port = null, reader = null, writer = null, reading = null, pending = null;
  let buffer = "", closing = null;
  const seen = new Map();
  const openingPorts = new Set();
  let generation = 0, starting = null;
  const api = {
    get supported() { return !!(globalThis.isSecureContext && navigator.serial?.requestPort); },
    onDisconnect: null,
    onState: null,
    async connect() {
      if (!api.supported) return JSON.stringify({status: "unsupported"});
      if (port || closing || starting !== null || openingPorts.size) return JSON.stringify({status: "busy"});
      const attempt = ++generation;
      starting = attempt;
      let selected;
      try {
        stage("choosing_port");
        // No awaited operation before the browser's user-activated port chooser.
        selected = await navigator.serial.requestPort();
        if (generation !== attempt) return JSON.stringify({status: "cancelled"});
        stage("opening_port");
        openingPorts.add(selected);
        let opened;
        try { opened = Promise.resolve(selected.open({baudRate: 115200, bufferSize: 4096})); }
        catch (error) { openingPorts.delete(selected); throw error; }
        // A driver operation cannot be cancelled. Close it if it succeeds after cancellation/timeout.
        void opened.then(async () => {
          if (generation !== attempt) {
            try { await bounded(Promise.resolve(selected.close()), 1500, "cleanup_timeout"); } catch (_) {}
          }
          openingPorts.delete(selected);
        }, () => openingPorts.delete(selected));
        await bounded(opened, 10000, "open_timeout");
        if (generation !== attempt) return JSON.stringify({status: "cancelled"});
        port = selected; buffer = ""; seen.clear();
        if (!port.readable || !port.writable) throw {code: "port_unavailable"};
        stage("starting_instrument");
        reading = readLoop(selected, attempt);
        await new Promise(resolve => setTimeout(resolve, 2000));
        if (generation !== attempt || port !== selected) return JSON.stringify({status: "disconnected"});
        if (document.hidden) {
          await api.disconnect();
          return JSON.stringify({status: "tab_hidden"});
        }
        buffer = "";
        return JSON.stringify({status: "connected"});
      } catch (error) {
        if (generation === attempt) ++generation;
        if (selected && selected === port) await api.disconnect();
        const status = error?.code === "open_timeout" ? "open_timeout"
          : error?.name === "NotFoundError" ? "cancelled"
          : ["SecurityError", "NotAllowedError"].includes(error?.name) ? "permission_denied"
          : "port_unavailable";
        return JSON.stringify({status});
      } finally {
        if (starting === attempt) starting = null;
      }
    },
    async disconnect() {
      ++generation;
      starting = null;
      if (closing) return closing;
      const previous = port, previousReader = reader, previousWriter = writer;
      port = null; reader = null; writer = null;
      settle({status: "disconnected", sample_count: 0});
      closing = (async () => {
        try { await bounded(Promise.resolve(previousReader?.cancel()), 1500, "cleanup_timeout"); } catch (_) {}
        try { await bounded(Promise.resolve(previousWriter?.abort()), 1500, "cleanup_timeout"); } catch (_) {}
        try { await bounded(Promise.resolve(reading), 1500, "cleanup_timeout"); } catch (_) {}
        try { await bounded(Promise.resolve(previous?.close()), 1500, "cleanup_timeout"); } catch (_) {}
        reading = null; buffer = ""; seen.clear();
      })();
      try { await closing; } finally { closing = null; }
    },
    async read(raw, allowedRaw) {
      let command, allowed;
      try { command = JSON.parse(raw); allowed = JSON.parse(allowedRaw); }
      catch (_) { return JSON.stringify({status: "precondition_failed", sample_count: 0}); }
      if (!command || !Array.isArray(allowed) || command.protocol_version !== "1" || !["read_voltage", "read_digital"].includes(command.action) ||
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
    const digital = command.action === "read_digital";
    const validValue = digital ? typeof result.value === "boolean"
      : typeof result.value === "number" && Number.isFinite(result.value) && result.value >= 0 && result.value <= 5;
    if (!validValue || (result.unit ?? "V") !== (digital ? "boolean" : "V") ||
        result.sample_count !== command.sample_count) {
      settle({status: "out_of_range", sample_count: 0}); return;
    }
    settle({status: "ok", value: result.value, sample_count: result.sample_count});
  }
  function stage(value) {
    try { api.onState?.(value); } catch (_) {}
  }
  function bounded(operation, milliseconds, code) {
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject({code}), milliseconds);
      operation.then(value => { clearTimeout(timeout); resolve(value); },
        error => { clearTimeout(timeout); reject(error); });
    });
  }
  async function readLoop(selected, attempt) {
    const decoder = new TextDecoder();
    let recoveries = 0;
    while (generation === attempt && port === selected && selected.readable) {
      const stream = selected.readable;
      let input, recover = false;
      try {
        input = stream.getReader();
        reader = input;
        while (generation === attempt && port === selected) {
          const {value, done} = await input.read();
          if (generation !== attempt || port !== selected) break;
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
      } catch (_) {
        // Web Serial replaces readable after recoverable framing/parity/overflow errors.
        recover = generation === attempt && port === selected && !!selected.readable &&
          selected.readable !== stream && ++recoveries <= 3;
        if (generation === attempt) {
          buffer = "";
          settle({status: "out_of_range", sample_count: 0});
        }
      } finally {
        try { input?.releaseLock(); } catch (_) {}
        if (reader === input) reader = null;
      }
      if (!recover) break;
    }
    if (generation === attempt && port === selected) {
      queueMicrotask(async () => {
        if (generation !== attempt || port !== selected) return;
        await api.disconnect();
        api.onDisconnect?.();
      });
    }
  }
  globalThis.addEventListener("pagehide", () => { void api.disconnect(); });
  document.addEventListener("visibilitychange", () => {
    if (document.hidden && port && starting === null) {
      void api.disconnect().then(() => api.onDisconnect?.());
    }
  });
  globalThis.circuitLabUsb = api;
})();
