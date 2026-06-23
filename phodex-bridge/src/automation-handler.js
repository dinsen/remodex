// FILE: automation-handler.js
// Purpose: Serves read-only Codex automation metadata to the mobile app.
// Layer: Bridge handler
// Exports: handleAutomationRequest, handleAutomationMethod, listAutomations
// Depends on: fs, path, ./codex-home

const fs = require("fs");
const path = require("path");
const { resolveCodexHome } = require("./codex-home");

const AUTOMATION_TOML_FILE = "automation.toml";

function handleAutomationRequest(rawMessage, sendResponse, options = {}) {
  let parsed;
  try {
    parsed = JSON.parse(rawMessage);
  } catch {
    return false;
  }

  const method = typeof parsed?.method === "string" ? parsed.method.trim() : "";
  if (!method.startsWith("automation/")) {
    return false;
  }

  const id = parsed.id;
  const params = parsed.params || {};
  handleAutomationMethod(method, params, options)
    .then((result) => {
      sendResponse(JSON.stringify({ id, result }));
    })
    .catch((err) => {
      const errorCode = err.errorCode || "automation_error";
      const message = err.userMessage || err.message || "Unable to load Codex automations.";
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

async function handleAutomationMethod(method, params = {}, options = {}) {
  switch (method) {
    case "automation/list":
      return listAutomations(options);
    default:
      throw automationError("unknown_method", `Unknown automation method: ${method}`);
  }
}

async function listAutomations(options = {}) {
  const codexHome = path.resolve(readString(options.codexHome) || resolveCodexHome());
  const automationDirectory = path.join(codexHome, "automations");
  const automations = [];
  const errors = [];

  if (!fs.existsSync(automationDirectory)) {
    return { automationDirectory, automations, errors };
  }

  const entries = fs.readdirSync(automationDirectory, { withFileTypes: true });
  for (const entry of entries) {
    if (!entry.isDirectory()) {
      continue;
    }

    const filePath = path.join(automationDirectory, entry.name, AUTOMATION_TOML_FILE);
    if (!fs.existsSync(filePath)) {
      continue;
    }

    try {
      const automation = automationFromTomlFile(filePath, entry.name);
      automations.push(automation);
    } catch (error) {
      errors.push({
        id: entry.name,
        message: error?.message || "Invalid automation file",
      });
    }
  }

  automations.sort(compareAutomations);
  return { automationDirectory, automations, errors };
}

function automationFromTomlFile(filePath, folderName) {
  const raw = fs.readFileSync(filePath, "utf8");
  const parsed = parseTopLevelToml(raw);
  const id = readString(parsed.id) || folderName;
  const name = readString(parsed.name) || id;
  const cwds = Array.isArray(parsed.cwds)
    ? parsed.cwds.map(readString).filter(Boolean)
    : [];

  return {
    id,
    name,
    kind: readString(parsed.kind),
    status: readString(parsed.status),
    rrule: readString(parsed.rrule),
    model: readString(parsed.model),
    reasoningEffort: readString(parsed.reasoning_effort),
    executionEnvironment: readString(parsed.execution_environment),
    cwds,
    cwdCount: cwds.length,
    createdAt: readNumber(parsed.created_at),
    updatedAt: readNumber(parsed.updated_at),
  };
}

function parseTopLevelToml(raw) {
  const result = {};
  const lines = raw.split(/\r?\n/);

  for (let index = 0; index < lines.length; index += 1) {
    const lineNumber = index + 1;
    const line = stripInlineComment(lines[index]).trim();
    if (!line || line.startsWith("[") || line.startsWith("#")) {
      continue;
    }

    const match = /^([A-Za-z0-9_-]+)\s*=\s*(.*)$/.exec(line);
    if (!match) {
      continue;
    }

    const [, key, rawValue] = match;
    result[key] = parseTomlValue(rawValue.trim(), lineNumber);
  }

  return result;
}

function parseTomlValue(rawValue, lineNumber) {
  if (rawValue.startsWith("\"")) {
    return parseTomlString(rawValue, lineNumber).value;
  }
  if (rawValue.startsWith("[")) {
    return parseTomlArray(rawValue, lineNumber);
  }
  if (/^-?\d+$/.test(rawValue)) {
    return Number(rawValue);
  }
  if (rawValue === "true") {
    return true;
  }
  if (rawValue === "false") {
    return false;
  }
  return rawValue;
}

function parseTomlArray(rawValue, lineNumber) {
  if (!rawValue.endsWith("]")) {
    throw new Error(`Unclosed array on line ${lineNumber}`);
  }

  const body = rawValue.slice(1, -1).trim();
  if (!body) {
    return [];
  }

  const values = [];
  let rest = body;
  while (rest.trim()) {
    rest = rest.trimStart();
    if (!rest.startsWith("\"")) {
      throw new Error(`Unsupported array value on line ${lineNumber}`);
    }

    const parsed = parseTomlString(rest, lineNumber);
    values.push(parsed.value);
    rest = parsed.rest.trimStart();
    if (!rest) {
      break;
    }
    if (!rest.startsWith(",")) {
      throw new Error(`Expected comma in array on line ${lineNumber}`);
    }
    rest = rest.slice(1);
  }

  return values;
}

function parseTomlString(rawValue, lineNumber) {
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
      const literal = rawValue.slice(0, index + 1);
      try {
        return {
          value: JSON.parse(literal),
          rest: rawValue.slice(index + 1),
        };
      } catch {
        throw new Error(`Invalid string on line ${lineNumber}`);
      }
    }
  }

  throw new Error(`Unclosed string on line ${lineNumber}`);
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

function compareAutomations(a, b) {
  const aDate = a.updatedAt ?? a.createdAt ?? 0;
  const bDate = b.updatedAt ?? b.createdAt ?? 0;
  if (aDate !== bDate) {
    return bDate - aDate;
  }
  return a.name.localeCompare(b.name, undefined, { sensitivity: "base" });
}

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function readNumber(value) {
  return Number.isFinite(value) ? value : null;
}

function automationError(errorCode, userMessage) {
  const error = new Error(userMessage);
  error.errorCode = errorCode;
  error.userMessage = userMessage;
  return error;
}

module.exports = {
  handleAutomationMethod,
  handleAutomationRequest,
  listAutomations,
};
