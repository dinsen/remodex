// FILE: host-pins-handler.js
// Purpose: Reads the one supported Codex Desktop host pin field without exposing the host file.
// Layer: Bridge handler
// Exports: handleHostPinsRequest, handleHostPinsMethod, readHostPins
// Depends on: fs, path, ./codex-home

const fs = require("fs");
const path = require("path");
const { resolveCodexHome } = require("./codex-home");

const HOST_PINS_METHOD = "bridge/hostPins/read";
const HOST_STATE_FILE = ".codex-global-state.json";
const MAX_HOST_STATE_BYTES = 1_048_576;
const MAX_HOST_PIN_IDS = 512;
const MAX_HOST_PIN_ID_CHARS = 256;
const SAFE_THREAD_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$/;

function handleHostPinsRequest(rawMessage, sendResponse, options = {}) {
  let parsed;
  try {
    parsed = JSON.parse(rawMessage);
  } catch {
    return false;
  }

  if (parsed?.method !== HOST_PINS_METHOD) {
    return false;
  }

  const id = parsed.id;
  handleHostPinsMethod(parsed.method, parsed.params, options)
    .then((result) => {
      sendResponse(JSON.stringify({ id, result }));
    })
    .catch((error) => {
      sendResponse(JSON.stringify({
        id,
        error: {
          code: -32000,
          message: error.userMessage || "Unable to read Codex host pins.",
          data: { errorCode: error.errorCode || "host_pins_unavailable" },
        },
      }));
    });

  return true;
}

async function handleHostPinsMethod(method, params, options = {}) {
  if (method !== HOST_PINS_METHOD) {
    throw hostPinsError("host_pins_malformed", "Invalid Codex host pin request.");
  }

  if (params !== undefined && params !== null) {
    if (typeof params !== "object" || Array.isArray(params) || Object.keys(params).length > 0) {
      throw hostPinsError("host_pins_malformed", "Invalid Codex host pin request.");
    }
  }

  return readHostPins(options);
}

async function readHostPins({
  fsModule = fs,
  codexHome = resolveCodexHome(),
} = {}) {
  const statePath = path.join(path.resolve(codexHome), HOST_STATE_FILE);
  let lastRacingError;

  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      const raw = readStableHostState(fsModule, statePath);
      return parseHostPins(raw);
    } catch (error) {
      if (error?.errorCode !== "host_pins_racing") {
        throw error;
      }
      lastRacingError = error;
    }
  }

  throw lastRacingError || hostPinsError("host_pins_racing", "Codex host pins changed while being read.");
}

function readStableHostState(fsModule, statePath) {
  let beforePathStat;
  try {
    beforePathStat = fsModule.statSync(statePath);
  } catch {
    throw hostPinsError("host_pins_unavailable", "Codex host pins are unavailable.");
  }

  if (!isBoundedFileSize(beforePathStat.size)) {
    throw hostPinsError("host_pins_malformed", "Codex host pins are malformed.");
  }

  let fileDescriptor;
  try {
    fileDescriptor = fsModule.openSync(statePath, "r");
    const beforeReadStat = fsModule.fstatSync(fileDescriptor);
    if (!sameFileSnapshot(beforePathStat, beforeReadStat)) {
      throw hostPinsError("host_pins_racing", "Codex host pins changed while being read.");
    }
    if (!isBoundedFileSize(beforeReadStat.size)) {
      throw hostPinsError("host_pins_malformed", "Codex host pins are malformed.");
    }

    const raw = readFileDescriptor(fsModule, fileDescriptor, beforeReadStat.size);
    const afterReadStat = fsModule.fstatSync(fileDescriptor);
    const afterPathStat = fsModule.statSync(statePath);
    if (!sameFileSnapshot(beforeReadStat, afterReadStat)
      || !sameFileSnapshot(beforeReadStat, afterPathStat)) {
      throw hostPinsError("host_pins_racing", "Codex host pins changed while being read.");
    }
    return raw;
  } catch (error) {
    if (error?.errorCode) {
      throw error;
    }
    throw hostPinsError("host_pins_unavailable", "Codex host pins are unavailable.");
  } finally {
    if (fileDescriptor !== undefined) {
      try {
        fsModule.closeSync(fileDescriptor);
      } catch {
        // The read result is already classified. Do not expose filesystem details.
      }
    }
  }
}

function readFileDescriptor(fsModule, fileDescriptor, size) {
  const buffer = Buffer.alloc(size);
  let offset = 0;
  while (offset < size) {
    let bytesRead;
    try {
      bytesRead = fsModule.readSync(fileDescriptor, buffer, offset, size - offset, offset);
    } catch {
      throw hostPinsError("host_pins_unavailable", "Codex host pins are unavailable.");
    }
    if (!Number.isInteger(bytesRead) || bytesRead <= 0) {
      throw hostPinsError("host_pins_racing", "Codex host pins changed while being read.");
    }
    offset += bytesRead;
  }
  return buffer.toString("utf8");
}

function parseHostPins(raw) {
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw hostPinsError("host_pins_malformed", "Codex host pins are malformed.");
  }

  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)
    || !Object.hasOwn(parsed, "pinned-thread-ids")
    || !Array.isArray(parsed["pinned-thread-ids"])
    || parsed["pinned-thread-ids"].length > MAX_HOST_PIN_IDS) {
    throw hostPinsError("host_pins_malformed", "Codex host pins are malformed.");
  }

  const pinnedThreadIds = [];
  const seen = new Set();
  for (const value of parsed["pinned-thread-ids"]) {
    if (typeof value !== "string"
      || value.length === 0
      || value.length > MAX_HOST_PIN_ID_CHARS
      || !SAFE_THREAD_ID_PATTERN.test(value)
      || seen.has(value)) {
      throw hostPinsError("host_pins_malformed", "Codex host pins are malformed.");
    }
    seen.add(value);
    pinnedThreadIds.push(value);
  }

  return {
    schemaVersion: 1,
    source: "codex-host",
    pinnedThreadIds,
  };
}

function isBoundedFileSize(size) {
  return Number.isSafeInteger(size) && size >= 0 && size <= MAX_HOST_STATE_BYTES;
}

function sameFileSnapshot(left, right) {
  return ["dev", "ino", "size", "mtimeMs", "ctimeMs"].every((key) => left?.[key] === right?.[key]);
}

function hostPinsError(errorCode, userMessage) {
  const error = new Error(userMessage);
  error.errorCode = errorCode;
  error.userMessage = userMessage;
  return error;
}

module.exports = {
  handleHostPinsMethod,
  handleHostPinsRequest,
  readHostPins,
};
