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

test("automation/read returns full editable automation details", async () => {
  const codexHome = makeTempCodexHome();
  writeAutomation(codexHome, "daily-report", [
    "version = 1",
    'id = "daily-report"',
    'name = "Daily Report"',
    'prompt = "Summarize yesterday."',
    'status = "ACTIVE"',
    'rrule = "FREQ=DAILY;BYHOUR=9;BYMINUTE=0"',
    'execution_environment = "local"',
    'model = "gpt-5.4"',
    'reasoning_effort = "high"',
    'cwds = ["/Users/me/app"]',
    "created_at = 1000",
    "updated_at = 2000",
    "",
  ].join("\n"));

  const result = await handleAutomationMethod(
    "automation/read",
    { id: "daily-report" },
    { codexHome }
  );

  assert.equal(result.automation.id, "daily-report");
  assert.equal(result.automation.prompt, "Summarize yesterday.");
  assert.equal(result.automation.executionEnvironment, "local");
  assert.equal(result.automation.model, "gpt-5.4");
  assert.equal(result.automation.reasoningEffort, "high");
  assert.deepEqual(result.automation.cwds, ["/Users/me/app"]);
});

test("automation/create writes a new automation toml file", async () => {
  const codexHome = makeTempCodexHome();

  const result = await handleAutomationMethod(
    "automation/create",
    {
      name: "Daily Report",
      prompt: "Summarize yesterday.",
      status: "ACTIVE",
      rrule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0",
      executionEnvironment: "local",
      model: "gpt-5.4",
      reasoningEffort: "high",
      cwds: ["/Users/me/app"],
    },
    { codexHome, now: () => 1234567890 }
  );

  assert.equal(result.automation.id, "daily-report");
  assert.equal(result.automation.status, "ACTIVE");
  assert.equal(result.automation.prompt, "Summarize yesterday.");
  assert.equal(result.automation.createdAt, 1234567890);
  assert.equal(result.automation.updatedAt, 1234567890);

  const saved = fs.readFileSync(
    path.join(codexHome, "automations", "daily-report", "automation.toml"),
    "utf8"
  );
  assert.match(saved, /id = "daily-report"/);
  assert.match(saved, /name = "Daily Report"/);
  assert.match(saved, /prompt = "Summarize yesterday\."/);
  assert.match(saved, /execution_environment = "local"/);
  assert.ok(saved.includes('cwds = ["/Users/me/app"]'));
});

test("automation/update rewrites editable fields and preserves created time", async () => {
  const codexHome = makeTempCodexHome();
  writeAutomation(codexHome, "daily-report", [
    "version = 1",
    'id = "daily-report"',
    'name = "Daily Report"',
    'prompt = "Old prompt."',
    'status = "ACTIVE"',
    'rrule = "FREQ=DAILY;BYHOUR=9;BYMINUTE=0"',
    'execution_environment = "worktree"',
    'cwds = ["/Users/me/app"]',
    "created_at = 1000",
    "updated_at = 2000",
    "",
  ].join("\n"));

  const result = await handleAutomationMethod(
    "automation/update",
    {
      id: "daily-report",
      name: "Daily Report Updated",
      prompt: "New prompt.",
      status: "PAUSED",
      rrule: "FREQ=WEEKLY;BYDAY=MO;BYHOUR=10;BYMINUTE=30",
      executionEnvironment: "local",
      model: "gpt-5.4",
      reasoningEffort: "medium",
      cwds: ["/Users/me/new-app"],
    },
    { codexHome, now: () => 9000 }
  );

  assert.equal(result.automation.id, "daily-report");
  assert.equal(result.automation.name, "Daily Report Updated");
  assert.equal(result.automation.status, "PAUSED");
  assert.equal(result.automation.createdAt, 1000);
  assert.equal(result.automation.updatedAt, 9000);
  assert.deepEqual(result.automation.cwds, ["/Users/me/new-app"]);

  const saved = fs.readFileSync(
    path.join(codexHome, "automations", "daily-report", "automation.toml"),
    "utf8"
  );
  assert.match(saved, /name = "Daily Report Updated"/);
  assert.match(saved, /prompt = "New prompt\."/);
  assert.match(saved, /status = "PAUSED"/);
  assert.match(saved, /created_at = 1000/);
  assert.match(saved, /updated_at = 9000/);
});

test("automation/delete removes the automation directory", async () => {
  const codexHome = makeTempCodexHome();
  writeAutomation(codexHome, "daily-report", [
    'id = "daily-report"',
    'name = "Daily Report"',
    'prompt = "Summarize yesterday."',
    'status = "ACTIVE"',
    "",
  ].join("\n"));

  const result = await handleAutomationMethod(
    "automation/delete",
    { id: "daily-report" },
    { codexHome }
  );

  assert.equal(result.deleted, true);
  assert.equal(
    fs.existsSync(path.join(codexHome, "automations", "daily-report")),
    false
  );
  assert.deepEqual((await listAutomations({ codexHome })).automations, []);
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
