// FILE: session-jsonl-history.js
// Purpose: Reconstructs a small thread/turns/list page from local Codex session JSONL files.

const fs = require("fs");
const { buildApplyPatchFileChangeItem } = require("./apply-patch-changes");

function readThreadTurnsListPageFromSessionJsonl(filePath, {
  threadId = "",
  limit = 5,
  maxLimit = 5,
  cursor = null,
  fsModule = fs,
} = {}) {
  if (!filePath || cursor != null) {
    return null;
  }

  const content = fsModule.readFileSync(filePath, "utf8");
  const turns = parseSessionJsonlTurns(content, { threadId });
  if (turns.length === 0) {
    return null;
  }

  const requestedLimit = Number.isInteger(limit) && limit > 0 ? limit : 5;
  const requestedMaxLimit = Number.isInteger(maxLimit) && maxLimit > 0 ? maxLimit : 5;
  const safeLimit = Math.min(requestedLimit, requestedMaxLimit, 5);
  const pageTurns = turns.slice(-safeLimit).reverse();
  return {
    data: pageTurns,
    nextCursor: turns.length > pageTurns.length ? "remodex-jsonl-fallback-older-unavailable" : null,
    remodexJsonlFallback: true,
  };
}

// Extracts thread-level context that app-server history can omit for desktop-origin runs.
function parseSessionJsonlMetadata(content) {
  let threadId = "";
  let cwd = "";

  const lines = String(content || "").split(/\r?\n/);
  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (!line) {
      continue;
    }

    let entry;
    try {
      entry = JSON.parse(line);
    } catch {
      continue;
    }

    if (entry?.type !== "session_meta") {
      continue;
    }

    const payload = objectValue(entry.payload);
    threadId ||= normalizeString(payload?.id)
      || normalizeString(payload?.thread_id)
      || normalizeString(payload?.threadId);
    cwd ||= normalizeString(payload?.cwd)
      || normalizeString(payload?.current_working_directory)
      || normalizeString(payload?.working_directory);

    if (threadId && cwd) {
      break;
    }
  }

  return { threadId, cwd };
}

function parseSessionJsonlTurns(content, { threadId = "" } = {}) {
  const turns = [];
  const turnsById = new Map();
  let activeTurnId = "";
  let sessionThreadId = normalizeString(threadId);
  let sessionCwd = "";
  const skippedCallIds = new Set();
  const pendingUserMessages = [];

  const lines = String(content || "").split(/\r?\n/);
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index].trim();
    if (!line) {
      continue;
    }

    let entry;
    try {
      entry = JSON.parse(line);
    } catch {
      continue;
    }

    if (entry?.type === "session_meta") {
      const payload = objectValue(entry.payload);
      sessionThreadId ||= normalizeString(payload?.id)
        || normalizeString(payload?.thread_id)
        || normalizeString(payload?.threadId);
      sessionCwd ||= normalizeString(payload?.cwd);
      continue;
    }

    if (entry?.type === "event_msg") {
      const payload = objectValue(entry.payload);
      const eventType = normalizeString(payload?.type);
      if (eventType === "task_started") {
        activeTurnId = normalizeString(payload?.turn_id)
          || normalizeString(payload?.turnId)
          || activeTurnId
          || `turn-line-${index + 1}`;
        const turn = ensureTurn(turns, turnsById, activeTurnId, sessionThreadId, entry.timestamp);
        flushPendingUserMessagesToTurn(turn, pendingUserMessages);
        continue;
      }

      if (eventType === "task_complete") {
        const turn = ensureTurn(
          turns,
          turnsById,
          normalizeString(payload?.turn_id) || normalizeString(payload?.turnId) || activeTurnId || `turn-line-${index + 1}`,
          sessionThreadId,
          entry.timestamp
        );
        turn.status = "completed";
        activeTurnId = "";
        continue;
      }

      if (eventType === "item_completed") {
        const completedItem = objectValue(payload?.item);
        if (!completedItem) {
          continue;
        }

        const turn = ensureTurn(
          turns,
          turnsById,
          normalizeString(payload?.turn_id) || normalizeString(payload?.turnId) || activeTurnId || `turn-line-${index + 1}`,
          sessionThreadId,
          entry.timestamp
        );
        const item = normalizeResponseItemForHistory(completedItem, index + 1, {
          cwd: sessionCwd,
        });
        if (item) {
          turn.items.push(item);
        }
        continue;
      }

      if (eventType === "user_message") {
        const explicitTurnId = normalizeString(payload?.turn_id) || normalizeString(payload?.turnId);
        if (!explicitTurnId && !activeTurnId) {
          pendingUserMessages.push({
            id: normalizeString(payload?.id) || `user-message-line-${index + 1}`,
            type: "user_message",
            role: "user",
            text: normalizeString(payload?.message) || normalizeString(payload?.text),
          });
          continue;
        }

        const turn = ensureTurn(
          turns,
          turnsById,
          explicitTurnId || activeTurnId || `turn-line-${index + 1}`,
          sessionThreadId,
          entry.timestamp
        );
        turn.items.push({
          id: normalizeString(payload?.id) || `user-message-line-${index + 1}`,
          type: "user_message",
          role: "user",
          text: normalizeString(payload?.message) || normalizeString(payload?.text),
        });
        continue;
      }

      // The final assistant text is usually present again as a response_item message.
      // Skipping event agent_message avoids double-rendering streaming/final chunks.
      continue;
    }

    if (entry?.type === "response_item") {
      const payload = objectValue(entry.payload);
      if (!payload) {
        continue;
      }
      if (shouldSkipResponseItemForHistory(payload, skippedCallIds)) {
        continue;
      }
      const turn = ensureTurn(
        turns,
        turnsById,
        normalizeString(payload.turn_id) || normalizeString(payload.turnId) || activeTurnId || `turn-line-${index + 1}`,
        sessionThreadId,
        entry.timestamp
      );
      const item = normalizeResponseItemForHistory(payload, index + 1, {
        cwd: sessionCwd,
      });
      if (item) {
        if (shouldSkipDuplicateProposedPlanMessage(turn, item)) {
          continue;
        }
        turn.items.push(item);
      }
    }
  }

  return turns.filter((turn) => turn.items.length > 0);
}

function shouldSkipDuplicateProposedPlanMessage(turn, item) {
  if (!turn || !item || normalizeHistoryToken(item.type) !== "message") {
    return false;
  }

  const role = normalizeString(item.role).toLowerCase();
  if (role && role !== "assistant") {
    return false;
  }

  if (!responseItemMessageText(item).includes("<proposed_plan>")) {
    return false;
  }

  return turn.items.some((candidate) => (
    normalizeHistoryToken(candidate?.type) === "plan"
      && candidate?.remodexJsonlProgressPlan !== true
  ));
}

function flushPendingUserMessagesToTurn(turn, pendingUserMessages) {
  if (!turn || pendingUserMessages.length === 0) {
    return;
  }

  turn.items.push(...pendingUserMessages.splice(0));
}

function ensureTurn(turns, turnsById, turnId, threadId, timestamp) {
  const normalizedTurnId = normalizeString(turnId) || `turn-${turns.length + 1}`;
  let turn = turnsById.get(normalizedTurnId);
  if (!turn) {
    turn = {
      id: normalizedTurnId,
      threadId: normalizeString(threadId) || undefined,
      createdAt: normalizeString(timestamp) || undefined,
      status: "running",
      items: [],
    };
    turnsById.set(normalizedTurnId, turn);
    turns.push(turn);
  }
  if (!turn.createdAt && timestamp) {
    turn.createdAt = normalizeString(timestamp);
  }
  return turn;
}

function normalizeResponseItemForHistory(payload, lineNumber, { cwd = "" } = {}) {
  const type = normalizeHistoryItemType(payload.type);
  if (!type) {
    return null;
  }

  const progressPlanItem = normalizeProgressPlanItemForHistory(payload);
  if (progressPlanItem) {
    return progressPlanItem;
  }

  const applyPatchItem = normalizeApplyPatchItemForHistory(payload, lineNumber, { cwd });
  if (applyPatchItem) {
    return applyPatchItem;
  }

  const readableToolItem = normalizeReadableToolItemForHistory(payload, lineNumber, { cwd });
  if (readableToolItem) {
    return readableToolItem;
  }

  const item = {
    ...payload,
    id: normalizeString(payload.id)
      || normalizeString(payload.item_id)
      || normalizeString(payload.itemId)
      || `response-item-line-${lineNumber}`,
    type,
  };

  if (type === "message" && !normalizeString(item.role)) {
    item.role = "assistant";
  }

  return item;
}

// Enriches raw tool-call JSONL records so mobile history can render useful rows.
function normalizeReadableToolItemForHistory(payload, lineNumber, { cwd = "" } = {}) {
  const type = normalizeHistoryItemType(payload.type);
  const typeToken = normalizeHistoryToken(type);
  if (typeToken !== "toolcall" && typeToken !== "customtoolcall") {
    return null;
  }

  const toolName = normalizeString(payload.name)
    || normalizeString(payload.tool_name)
    || normalizeString(payload.toolName);
  if (!toolName) {
    return null;
  }

  const callId = normalizeString(payload.call_id)
    || normalizeString(payload.callId)
    || normalizeString(payload.id);
  const argumentsObject = parseToolArguments(
    payload.arguments !== undefined ? payload.arguments : payload.input
  );
  const id = callId || normalizeString(payload.id) || `tool-call-line-${lineNumber}`;
  const status = normalizeString(payload.status) || "completed";

  if (isCommandToolName(toolName)) {
    return {
      ...payload,
      id,
      type: "commandExecution",
      status,
      command: resolveToolCommand(toolName, argumentsObject),
      cwd: resolveToolWorkingDirectory(argumentsObject, { cwd }),
      call_id: callId || undefined,
      tool_name: toolName,
      arguments: payload.arguments,
    };
  }

  const message = readableToolActivityMessage(toolName, argumentsObject, payload);
  if (!message) {
    return null;
  }

  return {
    ...payload,
    id,
    type: "tool_call",
    status,
    message,
    call_id: callId || undefined,
    tool_name: toolName,
  };
}

function normalizeApplyPatchItemForHistory(payload, lineNumber, { cwd = "" } = {}) {
  const type = normalizeHistoryItemType(payload.type);
  if (normalizeString(payload.name) !== "apply_patch" || normalizeHistoryToken(type) !== "customtoolcall") {
    return null;
  }

  const callId = normalizeString(payload.call_id)
    || normalizeString(payload.callId)
    || normalizeString(payload.id);
  const item = buildApplyPatchFileChangeItem({
    callId,
    patch: normalizeString(payload.input),
    status: normalizeString(payload.status) || "completed",
    idFallback: callId || `apply-patch-line-${lineNumber}`,
    cwd,
  });
  return item ? { ...payload, ...item } : null;
}

function normalizeProgressPlanItemForHistory(payload) {
  const type = normalizeHistoryItemType(payload.type);
  if (!isInternalProgressPlanCall(payload) || normalizeHistoryToken(type) !== "toolcall") {
    return null;
  }

  const argumentsObject = parseToolArguments(payload.arguments);
  const explanation = normalizeString(argumentsObject.explanation);
  const plan = normalizeHistoryPlanSteps(argumentsObject.plan);
  if (!explanation && plan.length === 0) {
    return null;
  }

  return {
    id: normalizeString(payload.call_id)
      || normalizeString(payload.callId)
      || normalizeString(payload.id)
      || undefined,
    type: "plan",
    text: explanation || "Planning...",
    explanation: explanation || undefined,
    plan,
    remodexJsonlProgressPlan: true,
  };
}

function normalizeHistoryPlanSteps(rawPlan) {
  if (!Array.isArray(rawPlan)) {
    return [];
  }

  return rawPlan.flatMap((rawStep) => {
    const stepObject = objectValue(rawStep);
    const step = normalizeString(stepObject?.step);
    const status = normalizeHistoryPlanStatus(stepObject?.status);
    return step && status ? [{ step, status }] : [];
  });
}

function normalizeHistoryPlanStatus(rawStatus) {
  const normalized = normalizeString(rawStatus);
  switch (normalized) {
    case "pending":
    case "in_progress":
    case "inProgress":
    case "completed":
      return normalized;
    default:
      return "";
  }
}

function parseToolArguments(rawArguments) {
  const parsed = typeof rawArguments === "string"
    ? safeParseJSON(normalizeString(rawArguments))
    : rawArguments;
  return objectValue(parsed) || {};
}

function resolveToolCommand(toolName, argumentsObject) {
  if (!isCommandToolName(toolName)) {
    return toolName;
  }

  return firstNonEmptyString([
    normalizeString(argumentsObject.cmd),
    normalizeString(argumentsObject.command),
    normalizeString(argumentsObject.raw_command),
    normalizeString(argumentsObject.rawCommand),
    normalizeString(argumentsObject.input),
  ]) || toolName;
}

function resolveToolWorkingDirectory(argumentsObject, { cwd = "" } = {}) {
  return firstNonEmptyString([
    normalizeString(argumentsObject.workdir),
    normalizeString(argumentsObject.cwd),
    normalizeString(argumentsObject.working_directory),
    normalizeString(argumentsObject.workingDirectory),
    normalizeString(cwd),
  ]) || "";
}

function isCommandToolName(toolName) {
  const normalized = normalizeString(toolName).toLowerCase();
  return normalized === "exec_command" || normalized === "shell_command";
}

function readableToolActivityMessage(toolName, argumentsObject, payload) {
  const normalized = normalizeString(toolName).toLowerCase();
  switch (normalized) {
    case "write_stdin":
      return "Write to terminal";
    case "read_thread_terminal":
      return "Read terminal output";
    case "view_image": {
      const imagePath = firstNonEmptyString([
        normalizeString(argumentsObject.path),
        normalizeString(payload.path),
      ]);
      return imagePath ? `Open image ${compactHistoryPath(imagePath)}` : "Open image";
    }
    case "open":
    case "browser.open":
      return readableTargetMessage("Open", argumentsObject, payload);
    case "click":
    case "browser.click":
      return readableTargetMessage("Click", argumentsObject, payload);
    case "find":
    case "browser.find":
      return readableTargetMessage("Find", argumentsObject, payload);
    case "screenshot":
    case "browser.screenshot":
      return "Capture screenshot";
    case "web.run":
    case "search_query":
    case "image_query":
      return readableSearchMessage(argumentsObject, payload);
    case "weather":
      return readableLocationMessage("Check weather", argumentsObject, payload);
    case "finance":
      return readableSymbolMessage("Check market data", argumentsObject, payload);
    case "sports":
      return readableLocationMessage("Check sports", argumentsObject, payload);
    case "automation_update":
      return "Update automation";
    case "update_goal":
      return "Update goal";
    case "create_goal":
      return "Create goal";
    case "get_goal":
      return "Read goal";
    case "request_user_input":
      return "Request input";
    default:
      return `Run ${humanizeToolName(toolName)}`;
  }
}

function readableTargetMessage(verb, argumentsObject, payload) {
  const target = firstNonEmptyString([
    normalizeString(argumentsObject.ref_id),
    normalizeString(argumentsObject.refId),
    normalizeString(argumentsObject.url),
    normalizeString(argumentsObject.pattern),
    normalizeString(argumentsObject.query),
    normalizeString(payload.ref_id),
    normalizeString(payload.url),
  ]);
  return target ? `${verb} ${compactHistoryPath(target)}` : verb;
}

function readableSearchMessage(argumentsObject, payload) {
  const query = firstSearchQuery(argumentsObject) || firstSearchQuery(payload);
  return query ? `Search ${query}` : "Search web";
}

function firstSearchQuery(object) {
  const direct = normalizeString(object.q)
    || normalizeString(object.query)
    || normalizeString(object.search_query);
  if (direct) {
    return direct;
  }

  let searchArray = null;
  if (Array.isArray(object.search_query)) {
    searchArray = object.search_query;
  } else if (Array.isArray(object.image_query)) {
    searchArray = object.image_query;
  }
  if (!searchArray) {
    return "";
  }
  for (const item of searchArray) {
    const query = normalizeString(objectValue(item)?.q)
      || normalizeString(objectValue(item)?.query);
    if (query) {
      return query;
    }
  }
  return "";
}

function readableLocationMessage(verb, argumentsObject, payload) {
  const target = firstNonEmptyString([
    normalizeString(argumentsObject.location),
    normalizeString(argumentsObject.team),
    normalizeString(argumentsObject.league),
    normalizeString(payload.location),
  ]);
  return target ? `${verb} ${target}` : verb;
}

function readableSymbolMessage(verb, argumentsObject, payload) {
  const target = firstNonEmptyString([
    normalizeString(argumentsObject.ticker),
    normalizeString(argumentsObject.symbol),
    normalizeString(payload.ticker),
  ]);
  return target ? `${verb} ${target}` : verb;
}

function humanizeToolName(toolName) {
  return normalizeString(toolName)
    .replace(/^[^.]+\./, "")
    .replace(/[_-]+/g, " ")
    .replace(/\s+/g, " ")
    .trim() || "tool";
}

function compactHistoryPath(path) {
  const text = normalizeString(path);
  if (!text) {
    return "";
  }
  const normalized = text.replace(/\\/g, "/");
  const parts = normalized.split("/").filter(Boolean);
  if (parts.length <= 2) {
    return text;
  }
  const prefix = normalized.startsWith("/") ? "…/" : "";
  return `${prefix}${parts.slice(-2).join("/")}`;
}

function firstNonEmptyString(values) {
  for (const value of values) {
    const normalized = normalizeString(value);
    if (normalized) {
      return normalized;
    }
  }
  return "";
}

function safeParseJSON(rawValue) {
  if (!rawValue) {
    return null;
  }
  try {
    return JSON.parse(rawValue);
  } catch {
    return null;
  }
}

// Filters desktop transcript internals that are stored as response items but are not chat history.
function shouldSkipResponseItemForHistory(payload, skippedCallIds) {
  const type = normalizeHistoryItemType(payload.type);
  const callId = normalizeString(payload.call_id) || normalizeString(payload.callId);

  if (type === "tool_call_output" && callId && skippedCallIds.has(callId)) {
    return true;
  }

  if (type === "tool_call" && isSubagentOrchestrationCall(payload)) {
    if (callId) {
      skippedCallIds.add(callId);
    }
    return true;
  }

  if (type === "tool_call" && isInternalProgressPlanCall(payload)) {
    if (callId) {
      skippedCallIds.add(callId);
    }
    return false;
  }

  if (type !== "message") {
    return false;
  }

  const role = normalizeString(payload.role).toLowerCase();
  if (role && role !== "user" && role !== "assistant") {
    return true;
  }

  if (role === "user" && isSubagentNotificationMessage(payload)) {
    return true;
  }

  return false;
}

function isSubagentOrchestrationCall(payload) {
  const name = normalizeString(payload.name).toLowerCase();
  return name === "spawn_agent"
    || name === "wait_agent"
    || name === "send_input"
    || name === "resume_agent"
    || name === "close_agent";
}

function isInternalProgressPlanCall(payload) {
  return normalizeString(payload.name).toLowerCase() === "update_plan";
}

function isSubagentNotificationMessage(payload) {
  const text = responseItemMessageText(payload).trimStart();
  return text.startsWith("<subagent_notification>");
}

function responseItemMessageText(payload) {
  const directText = normalizeString(payload.text) || normalizeString(payload.message);
  if (directText) {
    return directText;
  }

  const content = Array.isArray(payload.content) ? payload.content : [];
  return content
    .map((item) => objectValue(item))
    .filter(Boolean)
    .map((item) => normalizeString(item.text) || normalizeString(objectValue(item.data)?.text))
    .filter(Boolean)
    .join("\n");
}

function normalizeHistoryItemType(rawType) {
  const normalized = normalizeHistoryToken(rawType);
  if (!normalized) {
    return "";
  }
  if (normalized === "functioncall") {
    return "tool_call";
  }
  if (normalized === "functioncalloutput") {
    return "tool_call_output";
  }
  if (normalized === "plan") {
    return "plan";
  }
  return rawType;
}

function normalizeHistoryToken(rawType) {
  return normalizeString(rawType).toLowerCase().replace(/[\s_-]+/g, "");
}

function objectValue(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : null;
}

function normalizeString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

module.exports = {
  parseSessionJsonlMetadata,
  parseSessionJsonlTurns,
  readThreadTurnsListPageFromSessionJsonl,
};
