// FILE: automation-handler.test.js
// Purpose: Verifies read-only Codex automation listing RPCs for the mobile app.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, fs, os, path, ../src/automation-handler

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const {
  handleAutomationMethod,
  handleAutomationRequest,
  listAutomations,
} = require("../src/automation-handler");

function makeTempCodexHome() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "remodex-automation-handler-"));
}

function writeAutomation(codexHome, id, body) {
  const automationDirectory = path.join(codexHome, "automations", id);
  fs.mkdirSync(automationDirectory, { recursive: true });
  fs.writeFileSync(path.join(automationDirectory, "automation.toml"), body);
}

test("automation/list returns display-safe metadata sorted by update time", async () => {
  const codexHome = makeTempCodexHome();
  writeAutomation(codexHome, "weekly", [
    "version = 1",
    'id = "weekly"',
    'name = "Weekly Review"',
    'prompt = "This prompt should not be sent to the phone."',
    'status = "PAUSED"',
    'rrule = "RRULE:FREQ=WEEKLY;BYDAY=MO"',
    'execution_environment = "worktree"',
    'model = "gpt-5.3-codex"',
    'reasoning_effort = "medium"',
    'cwds = ["/Users/me/app", "/Users/me/site"]',
    "created_at = 1000",
    "updated_at = 3000",
    "",
  ].join("\n"));
  writeAutomation(codexHome, "hourly", [
    "version = 1",
    'id = "hourly"',
    'kind = "cron"',
    'name = "Hourly Poll"',
    'status = "ENABLED"',
    'rrule = "RRULE:FREQ=HOURLY;INTERVAL=1"',
    'execution_environment = "local"',
    'cwds = ["/Users/me/work"]',
    "created_at = 2000",
    "updated_at = 5000",
    "",
  ].join("\n"));

  const result = await listAutomations({ codexHome });

  assert.equal(result.automationDirectory, path.join(codexHome, "automations"));
  assert.deepEqual(
    result.automations.map((automation) => automation.id),
    ["hourly", "weekly"]
  );
  assert.equal(result.automations[0].name, "Hourly Poll");
  assert.equal(result.automations[0].status, "ENABLED");
  assert.equal(result.automations[0].rrule, "RRULE:FREQ=HOURLY;INTERVAL=1");
  assert.equal(result.automations[0].executionEnvironment, "local");
  assert.equal(result.automations[0].cwdCount, 1);
  assert.deepEqual(result.automations[0].cwds, ["/Users/me/work"]);
  assert.equal(result.automations[0].prompt, undefined);
  assert.equal(result.automations[1].model, "gpt-5.3-codex");
  assert.equal(result.automations[1].reasoningEffort, "medium");
  assert.equal(result.automations[1].cwdCount, 2);
});

test("automation/list skips malformed automation files and reports non-fatal errors", async () => {
  const codexHome = makeTempCodexHome();
  writeAutomation(codexHome, "valid", [
    'id = "valid"',
    'name = "Valid Automation"',
    'status = "PAUSED"',
    "",
  ].join("\n"));
  writeAutomation(codexHome, "broken", [
    'id = "broken"',
    'name = "Broken Automation"',
    "cwds = [",
    "",
  ].join("\n"));

  const result = await handleAutomationMethod("automation/list", {}, { codexHome });

  assert.deepEqual(
    result.automations.map((automation) => automation.id),
    ["valid"]
  );
  assert.equal(result.errors.length, 1);
  assert.equal(result.errors[0].id, "broken");
});

test("automation/setEnabled toggles the saved automation status", async () => {
  const codexHome = makeTempCodexHome();
  writeAutomation(codexHome, "demo", [
    "version = 1",
    'id = "demo"',
    'name = "Demo Automation"',
    'status = "PAUSED"',
    'prompt = "Keep this prompt intact."',
    "",
  ].join("\n"));

  const enabled = await handleAutomationMethod(
    "automation/setEnabled",
    { id: "demo", enabled: true },
    { codexHome }
  );

  assert.equal(enabled.automation.id, "demo");
  assert.equal(enabled.automation.status, "ACTIVE");
  let saved = fs.readFileSync(
    path.join(codexHome, "automations", "demo", "automation.toml"),
    "utf8"
  );
  assert.match(saved, /status = "ACTIVE"/);
  assert.match(saved, /prompt = "Keep this prompt intact."/);

  const disabled = await handleAutomationMethod(
    "automation/setEnabled",
    { id: "demo", enabled: false },
    { codexHome }
  );

  assert.equal(disabled.automation.status, "PAUSED");
  saved = fs.readFileSync(
    path.join(codexHome, "automations", "demo", "automation.toml"),
    "utf8"
  );
  assert.match(saved, /status = "PAUSED"/);
});

test("handleAutomationRequest responds to automation JSON-RPC requests", async () => {
  const codexHome = makeTempCodexHome();
  writeAutomation(codexHome, "demo", [
    'id = "demo"',
    'name = "Demo Automation"',
    'status = "PAUSED"',
    "",
  ].join("\n"));

  let response = "";
  let resolveResponse;
  const responsePromise = new Promise((resolve) => {
    resolveResponse = resolve;
  });

  const handled = handleAutomationRequest(
    JSON.stringify({
      id: "automation-1",
      method: "automation/list",
      params: {},
    }),
    (payload) => {
      response = payload;
      resolveResponse();
    },
    { codexHome }
  );

  assert.equal(handled, true);
  await responsePromise;

  const parsed = JSON.parse(response);
  assert.equal(parsed.id, "automation-1");
  assert.equal(parsed.result.automations[0].id, "demo");
});
