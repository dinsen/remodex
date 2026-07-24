// FILE: runtime-defaults-handler.js
// Purpose: Serves display-safe local Codex runtime defaults to the mobile app.
// Layer: Bridge handler
// Exports: handleRuntimeDefaultsRequest, handleRuntimeDefaultsMethod, readRuntimeDefaults
// Depends on: fs, path, ./codex-home

const fs = require("fs");
const path = require("path");
const { resolveCodexHome } = require("./codex-home");

const CONFIG_TOML_FILE = "config.toml";

function handleRuntimeDefaultsRequest(rawMessage, sendResponse, options = {}) {
  let parsed;
  try {
    parsed = JSON.parse(rawMessage);
  } catch {
    return false;
  }

  const method = typeof parsed?.method === "string" ? parsed.method.trim() : "";
  if (method !== "runtime/defaults") {
    return false;
  }

  const id = parsed.id;
  const params = parsed.params || {};
  handleRuntimeDefaultsMethod(method, params, options)
    .then((result) => {
      sendResponse(JSON.stringify({ id, result }));
    })
    .catch((err) => {
      const errorCode = err.errorCode || "runtime_defaults_error";
      const message = err.userMessage || err.message || "Unable to load Codex runtime defaults.";
      sendResponse(
        JSON.stringify({
          id,
          error: {
            code: -32000,
            message,
            data: { errorCode },
          },
        })
      );
    });

  return true;
}

async function handleRuntimeDefaultsMethod(method, params = {}, options = {}) {
  switch (method) {
    case "runtime/defaults":
      return readRuntimeDefaults(options);
    default:
      throw runtimeDefaultsError("unknown_method", `Unknown runtime method: ${method}`);
  }
}

async function readRuntimeDefaults(options = {}) {
  const codexHome = path.resolve(readString(options.codexHome) || resolveCodexHome());
  const configPath = path.join(codexHome, CONFIG_TOML_FILE);

  if (!fs.existsSync(configPath)) {
    return emptyRuntimeDefaults(configPath);
  }

  const raw = fs.readFileSync(configPath, "utf8");
  const values = parseConfigAssignments(raw);
  const model = readString(values.model);
  const reasoningEffort = readString(values.model_reasoning_effort);
  const approvalPolicy = normalizePolicy(readString(values.approval_policy));
  const sandboxMode = normalizePolicy(readString(values.sandbox_mode));

  return {
    configPath,
    model,
    reasoningEffort,
    accessMode: accessModeFromConfig({ approvalPolicy, sandboxMode }),
    approvalPolicy,
    sandboxMode,
    serviceTier: serviceTierFromDesktopDefault(readString(values["default-service-tier"])),
  };
}

function emptyRuntimeDefaults(configPath) {
  return {
    configPath,
    model: null,
    reasoningEffort: null,
    accessMode: null,
    approvalPolicy: null,
    sandboxMode: null,
    serviceTier: null,
  };
}

function parseConfigAssignments(raw) {
  const result = {};
  const lines = raw.split(/\r?\n/);

  for (let index = 0; index < lines.length; index += 1) {
    const line = stripInlineComment(lines[index]).trim();
    if (!line || line.startsWith("[") || line.startsWith("#")) {
      continue;
    }

    const match = /^("[^"]+"|[A-Za-z0-9_-]+)\s*=\s*(.*)$/.exec(line);
    if (!match) {
      continue;
    }

    const rawKey = match[1];
    const key = rawKey.startsWith("\"") ? parseQuotedString(rawKey) : rawKey;
    if (!keysOfInterest.has(key)) {
      continue;
    }

    result[key] = parseConfigValue(match[2].trim());
  }

  return result;
}

const keysOfInterest = new Set([
  "model",
  "model_reasoning_effort",
  "approval_policy",
  "sandbox_mode",
  "default-service-tier",
]);

function parseConfigValue(rawValue) {
  if (rawValue.startsWith("\"")) {
    return parseQuotedString(rawValue);
  }
  if (rawValue === "true") {
    return true;
  }
  if (rawValue === "false") {
    return false;
  }
  return rawValue;
}

function parseQuotedString(rawValue) {
  let escaped = false;
  for (let index = 1; index < rawValue.length; index += 1) {
    const character = rawValue[index];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (character === "\\") {
      escaped = true;
      continue;
    }
    if (character === "\"") {
      return JSON.parse(rawValue.slice(0, index + 1));
    }
  }
  return rawValue;
}

function stripInlineComment(line) {
  let escaped = false;
  let inString = false;
  for (let index = 0; index < line.length; index += 1) {
    const character = line[index];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (character === "\\" && inString) {
      escaped = true;
      continue;
    }
    if (character === "\"") {
      inString = !inString;
      continue;
    }
    if (character === "#" && !inString) {
      return line.slice(0, index);
    }
  }
  return line;
}

function accessModeFromConfig({ approvalPolicy, sandboxMode }) {
  if (sandboxMode === "danger-full-access" || approvalPolicy === "never") {
    return "full-access";
  }
  if (
    approvalPolicy === "on-request"
    || approvalPolicy === "onrequest"
    || sandboxMode === "workspace-write"
  ) {
    return "on-request";
  }
  return null;
}

function serviceTierFromDesktopDefault(value) {
  switch (normalizePolicy(value)) {
    case "fast":
    case "priority":
      return "fast";
    default:
      return null;
  }
}

function normalizePolicy(value) {
  return readString(value)?.toLowerCase() ?? null;
}

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function runtimeDefaultsError(errorCode, userMessage) {
  const error = new Error(userMessage);
  error.errorCode = errorCode;
  error.userMessage = userMessage;
  return error;
}

module.exports = {
  handleRuntimeDefaultsMethod,
  handleRuntimeDefaultsRequest,
  readRuntimeDefaults,
};
