const assert = require("node:assert/strict");
const { createCipheriv, createDecipheriv } = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const test = require("node:test");

function bridgeNonce(sender, counter) {
  const nonce = Buffer.alloc(12);
  nonce.writeUInt8(sender === "mac" ? 1 : 2, 0);
  nonce.writeBigUInt64BE(BigInt(counter), 4);
  return nonce;
}

function bridgeEncrypt(payloadObject, key, sender, counter, sessionId, keyEpoch) {
  const cipher = createCipheriv("aes-256-gcm", key, bridgeNonce(sender, counter));
  const ciphertext = Buffer.concat([
    cipher.update(Buffer.from(JSON.stringify(payloadObject), "utf8")),
    cipher.final(),
  ]);
  return {
    kind: "encryptedEnvelope",
    v: 2,
    sessionId,
    keyEpoch,
    sender,
    counter,
    ciphertext: ciphertext.toString("base64"),
    tag: cipher.getAuthTag().toString("base64"),
  };
}

function bridgeDecrypt(envelope, key) {
  const decipher = createDecipheriv("aes-256-gcm", key, bridgeNonce(envelope.sender, envelope.counter));
  decipher.setAuthTag(Buffer.from(envelope.tag, "base64"));
  return Buffer.concat([
    decipher.update(Buffer.from(envelope.ciphertext, "base64")),
    decipher.final(),
  ]);
}

test("iOS transfer work runs CPU preparation away from MainActor", {
  skip: process.platform !== "darwin" ? "requires the macOS Swift compiler" : false,
  timeout: 60000,
}, (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-swift-transfer-work-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const mobile = path.resolve(__dirname, "../../CodexMobile/CodexMobile");
  const models = path.join(mobile, "Models");
  const services = path.join(mobile, "Services");
  const binary = path.join(directory, "transfer-work");
  const transferKey = Buffer.alloc(32, 0x27);
  const fixedBridgeVector = bridgeEncrypt({
    bridgeOutboundSeq: 33,
    payloadText: "{\"id\":\"response-1\",\"result\":{\"ok\":true}}",
  }, transferKey, "mac", 12, "session-a", 9);
  assert.equal(fixedBridgeVector.ciphertext,
    "4a5E9DIokohFz5SBbmDObnpdl+GKMT4mlEGADQwORAIEnbXsh52Tn26qlWAOxuQ4xjsvvxpXEeadIP8stGpeMRvNi4XPnTnM8sZV6TQ/zf+S2sQCMYmm26M=");
  assert.equal(fixedBridgeVector.tag, "DdNADB2ETI5k1eoBW3m2rg==");
  execFileSync("xcrun", ["swiftc", "-DDEBUG", "-default-isolation", "MainActor", "-strict-concurrency=complete",
    "-swift-version", "5", "-module-cache-path", path.join(directory, "cache"), "-parse-as-library",
    path.join(models, "JSONValue.swift"), path.join(models, "RPCMessage.swift"),
    path.join(models, "CodexRuntimeSettings.swift"), path.join(models, "CodexThreadGoal.swift"),
    path.join(models, "CodexThread.swift"), path.join(models, "CodexFuzzyFileMatch.swift"),
    path.join(models, "CodexSkillMetadata.swift"),
    path.join(services, "CodexTransferWork.swift"),
    path.join(__dirname, "fixtures/ios-transfer-work-harness.swift"), "-o", binary], { timeout: 45000 });
  const output = execFileSync(binary, { encoding: "utf8", timeout: 10000 });
  assert.match(output, /transfer work off-main checks passed/);

  const sealedLine = output.split("\n").find((line) => line.startsWith("swift-outbound-envelope-base64="));
  assert.ok(sealedLine, "Swift production codec did not emit its outbound interoperability vector");
  const swiftEnvelope = JSON.parse(Buffer.from(sealedLine.slice("swift-outbound-envelope-base64=".length), "base64"));
  assert.equal(swiftEnvelope.kind, "encryptedEnvelope");
  assert.equal(swiftEnvelope.sender, "iphone");
  assert.equal(swiftEnvelope.counter, 4);
  const swiftPayload = JSON.parse(bridgeDecrypt(swiftEnvelope, transferKey).toString("utf8"));
  assert.equal(Object.hasOwn(swiftPayload, "bridgeOutboundSeq"), false);
  assert.equal(swiftPayload.payloadText, "{\"jsonrpc\":\"2.0\",\"id\":\"probe\",\"method\":\"probe\"}");
});
