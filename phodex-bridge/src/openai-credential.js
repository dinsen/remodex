// FILE: openai-credential.js
// Purpose: Resolve the bridge's long-lived OpenAI credential without exposing
// it to the phone, launchd, logs, or persisted bridge state.
// Layer: Bridge credential boundary

const { execFileSync } = require("child_process");

// This service/account pair is deliberately explicit so setup can be audited
// and repeated without putting a secret in a LaunchAgent plist.
const OPENAI_KEYCHAIN_SERVICE = "com.remodex.bridge.openai";
const OPENAI_KEYCHAIN_ACCOUNT = "api-key";

/**
 * Resolve the bridge-owned OpenAI API key.
 *
 * Keychain is preferred on macOS. Environment variables are intentionally a
 * terminal-developer fallback only; launchd does not source .zshrc and the
 * resolver never reads that file. The returned object is kept in memory by
 * the caller and must not be logged or sent over the relay.
 */
function resolveOpenAIAPIKey({
  env = process.env,
  platform = process.platform,
  commandRunner = execFileSync,
} = {}) {
  if (platform === "darwin" && typeof commandRunner === "function") {
    try {
      const output = commandRunner("security", [
        "find-generic-password",
        "-s",
        OPENAI_KEYCHAIN_SERVICE,
        "-a",
        OPENAI_KEYCHAIN_ACCOUNT,
        "-w",
      ], {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
      });
      const keychainValue = normalizeCredential(output);
      if (keychainValue) {
        return { apiKey: keychainValue, source: "keychain" };
      }
    } catch {
      // A missing/locked item is expected during first-run setup. Do not
      // include command output or error text: it may contain the credential.
    }
  }

  for (const name of ["REMODEX_OPENAI_REALTIME_API_KEY", "OPENAI_API_KEY"]) {
    const value = normalizeCredential(env?.[name]);
    if (value) {
      return { apiKey: value, source: `env:${name}` };
    }
  }

  return null;
}

function normalizeCredential(value) {
  if (Buffer.isBuffer(value)) {
    return value.toString("utf8").trim();
  }
  return typeof value === "string" ? value.trim() : "";
}

module.exports = {
  OPENAI_KEYCHAIN_ACCOUNT,
  OPENAI_KEYCHAIN_SERVICE,
  resolveOpenAIAPIKey,
};
