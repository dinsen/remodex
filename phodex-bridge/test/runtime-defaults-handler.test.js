const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");

const {
  handleRuntimeDefaultsMethod,
  handleRuntimeDefaultsRequest,
  readRuntimeDefaults,
} = require("../src/runtime-defaults-handler");

function makeTempCodexHome() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "remodex-runtime-defaults-"));
}

function writeConfig(codexHome, body) {
  fs.writeFileSync(path.join(codexHome, "config.toml"), body);
}

test("runtime defaults read display-safe Codex config selections", async () => {
  const codexHome = makeTempCodexHome();
  writeConfig(codexHome, [
    'model = "gpt-5.5"',
    'model_reasoning_effort = "xhigh"',
    'sandbox_mode = "workspace-write"',
    'approval_policy = "on-request"',
    "",
    "[desktop]",
    'default-service-tier = "priority"',
  ].join("\n"));

  const result = await readRuntimeDefaults({ codexHome });

  assert.equal(result.model, "gpt-5.5");
  assert.equal(result.reasoningEffort, "xhigh");
  assert.equal(result.accessMode, "on-request");
  assert.equal(result.approvalPolicy, "on-request");
  assert.equal(result.sandboxMode, "workspace-write");
  assert.equal(result.serviceTier, "fast");
  assert.equal(result.configPath, path.join(codexHome, "config.toml"));
});

test("runtime defaults map full access from sandbox and approval settings", async () => {
  const codexHome = makeTempCodexHome();
  writeConfig(codexHome, [
    'model = "gpt-5.4"',
    'model_reasoning_effort = "high"',
    'sandbox_mode = "danger-full-access"',
    'approval_policy = "never"',
    "",
    "[desktop]",
    'default-service-tier = "standard"',
  ].join("\n"));

  const result = await readRuntimeDefaults({ codexHome });

  assert.equal(result.model, "gpt-5.4");
  assert.equal(result.reasoningEffort, "high");
  assert.equal(result.accessMode, "full-access");
  assert.equal(result.serviceTier, null);
});

test("runtime/defaults returns a JSON-RPC result", async () => {
  const codexHome = makeTempCodexHome();
  writeConfig(codexHome, [
    'model = "gpt-5.5"',
    'model_reasoning_effort = "xhigh"',
    'approval_policy = "on-request"',
  ].join("\n"));

  const result = await handleRuntimeDefaultsMethod("runtime/defaults", {}, { codexHome });

  assert.equal(result.model, "gpt-5.5");
  assert.equal(result.reasoningEffort, "xhigh");
  assert.equal(result.accessMode, "on-request");
});

test("runtime handler ignores unrelated runtime methods", () => {
  let didSend = false;
  const handled = handleRuntimeDefaultsRequest(
    JSON.stringify({ id: "1", method: "runtime/unknown", params: {} }),
    () => {
      didSend = true;
    }
  );

  assert.equal(handled, false);
  assert.equal(didSend, false);
});
