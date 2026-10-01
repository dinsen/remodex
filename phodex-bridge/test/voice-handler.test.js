// FILE: voice-handler.test.js
// Purpose: Verifies bridge-owned voice transcription auth, validation, and retry behavior.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/voice-handler

const test = require("node:test");
const assert = require("node:assert/strict");

const {
  createRealtimeSessionHandler,
  createVoiceHandler,
  resolveOpenAIAPIKey,
  resolveVoiceAuth,
} = require("../src/voice-handler");

const FULL_ACCESS_TURN_START_ACCESS = {
  approvalPolicyCandidates: ["never"],
  approvalsReviewerCandidates: ["user", null],
  legacySandbox: "danger-full-access",
  sandboxPolicy: { type: "dangerFullAccess" },
};
const ASK_TURN_START_ACCESS = {
  approvalPolicyCandidates: ["on-request", "onRequest"],
  approvalsReviewerCandidates: ["user", null],
  legacySandbox: "workspace-write",
  sandboxPolicy: { type: "workspaceWrite", networkAccess: true },
};
const AUTO_REVIEW_TURN_START_ACCESS = {
  approvalPolicyCandidates: ["on-request", "onRequest"],
  approvalsReviewerCandidates: ["auto_review", "guardian_subagent"],
  legacySandbox: "workspace-write",
  sandboxPolicy: { type: "workspaceWrite", networkAccess: true },
};

test("resolveOpenAIAPIKey prefers the Mac Keychain and never includes the key in its metadata", () => {
  const commandCalls = [];
  const result = resolveOpenAIAPIKey({
    platform: "darwin",
    env: {
      REMODEX_OPENAI_REALTIME_API_KEY: "env-realtime-secret",
      OPENAI_API_KEY: "env-openai-secret",
    },
    commandRunner(command, args) {
      commandCalls.push({ command, args });
      return "keychain-secret\n";
    },
  });

  assert.deepEqual(result, { apiKey: "keychain-secret", source: "keychain" });
  assert.deepEqual(commandCalls, [{
    command: "security",
    args: [
      "find-generic-password",
      "-s",
      "com.remodex.bridge.openai",
      "-a",
      "api-key",
      "-w",
    ],
  }]);
  assert.equal(JSON.stringify(result).includes("env-realtime-secret"), false);
});

test("resolveOpenAIAPIKey falls back from the explicit Remodex env var to OPENAI_API_KEY", () => {
  assert.deepEqual(
    resolveOpenAIAPIKey({
      platform: "linux",
      env: { REMODEX_OPENAI_REALTIME_API_KEY: "remodex-secret", OPENAI_API_KEY: "openai-secret" },
      commandRunner() {
        throw new Error("security should not run outside macOS");
      },
    }),
    { apiKey: "remodex-secret", source: "env:REMODEX_OPENAI_REALTIME_API_KEY" }
  );
  assert.deepEqual(
    resolveOpenAIAPIKey({
      platform: "linux",
      env: { OPENAI_API_KEY: "openai-secret" },
    }),
    { apiKey: "openai-secret", source: "env:OPENAI_API_KEY" }
  );
});

test("resolveOpenAIAPIKey ignores Keychain errors and reports no credential without leaking values", () => {
  const result = resolveOpenAIAPIKey({
    platform: "darwin",
    env: {},
    commandRunner() {
      const error = new Error("security: password for api-key is unavailable");
      error.stderr = "keychain-secret";
      throw error;
    },
  });

  assert.equal(result, null);
});

test("GPT-Live session starts with client delegation and routes audio through the bridge", async () => {
  const responses = [];
  const upstreamMessages = [];
  const applicationEvents = [];
  const fakeSocket = makeLiveSocket({ upstreamMessages });
  const handler = createRealtimeSessionHandler({
    platform: "linux",
    env: { OPENAI_API_KEY: "mac-only-key" },
    sendCodexRequest: activeThreadRequest(),
    WebSocketImpl: class {
      constructor() {
        return fakeSocket;
      }
    },
    sendApplicationResponse(rawMessage) {
      applicationEvents.push(JSON.parse(rawMessage));
    },
  });

  handler.handleRealtimeSessionRequest(JSON.stringify({
    id: "live-1",
    method: "voice/realtime/session",
    params: { threadId: "thread-123" },
  }), (response) => responses.push(JSON.parse(response)));

  await tick();
  assert.equal(upstreamMessages.length, 1);
  assert.deepEqual(upstreamMessages[0].type, "session.start");
  assert.equal(upstreamMessages[0].session.model, "gpt-live-1");
  assert.deepEqual(upstreamMessages[0].session.audio, {
    format: { type: "audio/pcm", rate: 24_000 },
    output: { voice: "marin" },
  });
  assert.deepEqual(upstreamMessages[0].session.delegation, { type: "client" });
  assert.equal(responses[0].result?.model, "gpt-live-1");
  assert.equal(responses[0].result?.clientSecret, undefined);

  const sessionId = responses[0].result.sessionId;
  const audioHandled = handler.handleRealtimeSessionRequest(JSON.stringify({
    id: "audio-1",
    method: "voice/realtime/audio",
    params: { sessionId, audio: "AQI=" },
  }), (response) => responses.push(JSON.parse(response)));
  assert.equal(audioHandled, true);
  await tick();
  assert.deepEqual(upstreamMessages[1], {
    type: "session.input_audio.append",
    audio: "AQI=",
  });
  assert.deepEqual(responses.at(-1), { id: "audio-1", result: { ok: true } });
  assert.equal(applicationEvents.some((message) => message.method === "voice/realtime/event"), true);
});

test("GPT-Live client delegation invokes the scoped Codex adapter and appends a concise result", async () => {
  const responses = [];
  const upstreamMessages = [];
  const fakeSocket = makeLiveSocket({
    upstreamMessages,
    startedEvent: { type: "session.started", session: { id: "live_provider_1", expires_at: 1_800_000_000 } },
  });
  const delegationCalls = [];
  const handler = createRealtimeSessionHandler({
    platform: "linux",
    env: { OPENAI_API_KEY: "mac-only-key" },
    sendCodexRequest: activeThreadRequest(),
    WebSocketImpl: class {
      constructor() {
        return fakeSocket;
      }
    },
    runDelegatedTask: async (context) => {
      delegationCalls.push(context);
      return "Codex verified the requested result.";
    },
  });

  handler.handleRealtimeSessionRequest(JSON.stringify({
    id: "live-2",
    method: "voice/realtime/session",
    params: { threadId: "thread-123" },
  }), (response) => responses.push(JSON.parse(response)));
  await tick();
  const sessionId = responses[0].result.sessionId;

  fakeSocket.emitMessage({
    type: "session.input_transcript.delta",
    event_id: "input_1",
    start_ms: 0,
    end_ms: 500,
    delta: "Check the current branch.",
  });
  fakeSocket.emitMessage({
    type: "session.delegation.created",
    offset_ms: 500,
    delegation: { id: "item_delegate_1", type: "delegation", target: "client" },
  });
  await delay(150);

  assert.deepEqual(delegationCalls, [{
    threadId: "thread-123",
    sessionId,
    delegationId: "item_delegate_1",
    transcript: "Check the current branch.",
  }]);
  assert.deepEqual(upstreamMessages.at(-1), {
    type: "session.commentary.append",
    event_id: upstreamMessages.at(-1).event_id,
    delegation_id: "item_delegate_1",
    content: "Codex verified the requested result.",
  });
  assert.equal(typeof upstreamMessages.at(-1).event_id, "string");
});

test("GPT-Live waits for the matching Codex turn and sends only its final answer", async () => {
  const responses = [];
  const upstreamMessages = [];
  const turnStarts = [];
  const fakeSocket = makeLiveSocket({ upstreamMessages });
  const handler = createRealtimeSessionHandler({
    apiKey: "local-only-api-key",
    delegationCompletionTimeoutMs: 500,
    sendCodexRequest: async (method, params) => {
      if (method === "thread/read") {
        return { thread: { id: "thread-123" } };
      }
      assert.equal(method, "turn/start");
      turnStarts.push(params);
      return { turn: { id: `turn-live-${turnStarts.length}` } };
    },
    WebSocketImpl: class {
      constructor() {
        return fakeSocket;
      }
    },
  });

  handler.handleRealtimeSessionRequest(JSON.stringify({
    id: "live-final-answer",
    method: "voice/realtime/session",
    params: { threadId: "thread-123" },
  }), (response) => responses.push(JSON.parse(response)));
  await tick();
  const sessionId = responses[0].result.sessionId;

  fakeSocket.emitMessage({
    type: "session.input_transcript.delta",
    event_id: "input_final_1",
    start_ms: 0,
    end_ms: 500,
    delta: "Summarize the latest changes.",
  });
  fakeSocket.emitMessage({
    type: "session.delegation.created",
    offset_ms: 500,
    delegation: { id: "delegate_final_1", type: "delegation", target: "client" },
  });
  await delay(150);

  assert.deepEqual(turnStarts, [{
    threadId: "thread-123",
    input: [{ type: "text", text: "Summarize the latest changes." }],
    approvalPolicy: "on-request",
    approvalsReviewer: "user",
    sandboxPolicy: { type: "workspaceWrite", networkAccess: true },
  }]);
  const commentary = () => upstreamMessages.filter((event) => event.type === "session.commentary.append");
  assert.equal(commentary().length, 0, "the start acknowledgement is not a spoken answer");

  handler.handleCodexMessage({
    method: "turn/completed",
    params: {
      threadId: "another-thread",
      turn: { id: "turn-live-1", status: "completed", items: [
        { id: "wrong-thread-answer", type: "agentMessage", text: "Do not speak this." },
      ] },
    },
  });
  handler.handleCodexMessage({
    method: "turn/completed",
    params: {
      threadId: "thread-123",
      turn: { id: "different-turn", status: "completed", items: [
        { id: "wrong-turn-answer", type: "agentMessage", text: "Do not speak this either." },
      ] },
    },
  });
  assert.equal(commentary().length, 0, "other threads and turns cannot complete this delegation");

  handler.handleCodexMessage({
    method: "turn/completed",
    params: {
      threadId: "thread-123",
      turn: {
        id: "turn-live-1",
        status: "completed",
        items: [
          { id: "user-input", type: "userMessage", text: "Summarize the latest changes." },
          { id: "analysis", type: "reasoning", text: "Private reasoning." },
          { id: "tool-output", type: "commandExecution", command: "cat secrets" },
          { id: "progress", type: "agentMessage", phase: "commentary", text: "I am checking the diff." },
          { id: "unknown-phase", type: "agentMessage", text: "Do not speak an unclassified message." },
          { id: "answer-first", type: "agentMessage", phase: "final_answer", text: "An earlier answer." },
          { id: "answer-final", type: "agentMessage", phase: "final_answer", text: "The change is complete." },
        ],
      },
    },
  });
  await tick();

  assert.deepEqual(commentary().map((event) => event.content), ["The change is complete."]);

  fakeSocket.emitMessage({
    type: "session.input_transcript.delta",
    event_id: "input_final_2",
    start_ms: 600,
    end_ms: 900,
    delta: "What changed?",
  });
  fakeSocket.emitMessage({
    type: "session.delegation.created",
    offset_ms: 900,
    delegation: { id: "delegate_final_2", type: "delegation", target: "client" },
  });
  await delay(150);
  assert.equal(turnStarts.length, 2, "a later request starts a fresh Codex turn");

  handler.handleCodexMessage({
    method: "item/completed",
    params: {
      threadId: "thread-123",
      turnId: "turn-live-2",
      item: { id: "answer-other-thread", type: "agentMessage", text: "Wrong thread." },
    },
  });
  handler.handleCodexMessage({
    method: "item/completed",
    params: {
      threadId: "thread-123",
      turnId: "turn-live-1",
      item: { id: "answer-other-turn", type: "agentMessage", text: "Wrong turn." },
    },
  });
  handler.handleCodexMessage({
    method: "item/completed",
    params: {
      threadId: "thread-123",
      turnId: "turn-live-2",
      item: { id: "progress-final-2", type: "agentMessage", phase: "commentary", text: "Still working." },
    },
  });
  handler.handleCodexMessage({
    method: "item/completed",
    params: {
      threadId: "thread-123",
      turnId: "turn-live-2",
      item: { id: "answer-final-2", type: "agentMessage", phase: "final_answer", text: "Only this answer is spoken." },
    },
  });
  handler.handleCodexMessage({
    method: "turn/completed",
    params: {
      threadId: "thread-123",
      turn: { id: "turn-live-2", status: "completed" },
    },
  });
  await tick();
  assert.deepEqual(commentary().map((event) => event.content), [
    "The change is complete.",
    "Only this answer is spoken.",
  ]);
  assert.equal(sessionId, responses[0].result.sessionId);
});

test("GPT-Live applies the access configuration captured for each Voice session", async () => {
  const upstreamMessages = [];
  const sockets = [];
  const turnStarts = [];
  const handler = createRealtimeSessionHandler({
    apiKey: "local-only-api-key",
    sendCodexRequest: async (method, params) => {
      if (method === "thread/read") return { thread: { id: params.threadId } };
      assert.equal(method, "turn/start");
      turnStarts.push(params);
      return { turn: { id: `turn-access-${turnStarts.length}` } };
    },
    WebSocketImpl: class {
      constructor() {
        const socket = makeLiveSocket({ upstreamMessages });
        sockets.push(socket);
        return socket;
      }
    },
  });

  async function runRequest(sessionIndex, accessConfiguration, text) {
    const responses = [];
    handler.handleRealtimeSessionRequest(JSON.stringify({
      id: `access-session-${sessionIndex}`,
      method: "voice/realtime/session",
      params: {
        threadId: "thread-access",
        turnStartAccessConfiguration: accessConfiguration,
      },
    }), (response) => responses.push(JSON.parse(response)));
    await tick();
    assert.equal(responses[0].error, undefined);

    const socket = sockets[sessionIndex - 1];
    const startMs = sessionIndex * 1_000;
    const endMs = startMs + 300;
    socket.emitMessage({
      type: "session.input_transcript.delta",
      event_id: `access-transcript-${sessionIndex}`,
      start_ms: startMs,
      end_ms: endMs,
      delta: text,
    });
    socket.emitMessage({
      type: "session.delegation.created",
      offset_ms: endMs,
      delegation: { id: `access-delegation-${sessionIndex}`, type: "delegation", target: "client" },
    });
    await delay(150);

    const turnId = `turn-access-${sessionIndex}`;
    handler.handleCodexMessage({
      method: "turn/completed",
      params: {
        threadId: "thread-access",
        turn: {
          id: turnId,
          status: "completed",
          items: [{
            id: `answer-access-${sessionIndex}`,
            type: "agentMessage",
            phase: "final_answer",
            text: "Done.",
          }],
        },
      },
    });
    await tick();
  }

  await runRequest(1, FULL_ACCESS_TURN_START_ACCESS, "Use full access.");
  await runRequest(2, ASK_TURN_START_ACCESS, "Switch to Ask.");
  await runRequest(3, AUTO_REVIEW_TURN_START_ACCESS, "Switch to Auto Review.");

  assert.deepEqual(turnStarts.map(({ approvalPolicy, approvalsReviewer, sandboxPolicy, sandbox }) => ({
    approvalPolicy,
    approvalsReviewer,
    sandboxPolicy,
    sandbox,
  })), [
    {
      approvalPolicy: "never",
      approvalsReviewer: "user",
      sandboxPolicy: { type: "dangerFullAccess" },
      sandbox: undefined,
    },
    {
      approvalPolicy: "on-request",
      approvalsReviewer: "user",
      sandboxPolicy: { type: "workspaceWrite", networkAccess: true },
      sandbox: undefined,
    },
    {
      approvalPolicy: "on-request",
      approvalsReviewer: "auto_review",
      sandboxPolicy: { type: "workspaceWrite", networkAccess: true },
      sandbox: undefined,
    },
  ]);
});

test("GPT-Live retries only explicit Codex access-parameter compatibility rejections", async () => {
  const responses = [];
  const upstreamMessages = [];
  const turnStarts = [];
  const fakeSocket = makeLiveSocket({ upstreamMessages });
  const handler = createRealtimeSessionHandler({
    apiKey: "local-only-api-key",
    sendCodexRequest: async (method, params) => {
      if (method === "thread/read") return { thread: { id: params.threadId } };
      turnStarts.push(params);
      if (turnStarts.length === 1) {
        const error = new Error("Invalid params: unknown field sandboxPolicy");
        error.code = -32602;
        throw error;
      }
      return { turnId: "turn-legacy-sandbox" };
    },
    WebSocketImpl: class {
      constructor() {
        return fakeSocket;
      }
    },
  });

  handler.handleRealtimeSessionRequest(JSON.stringify({
    id: "legacy-sandbox-session",
    method: "voice/realtime/session",
    params: {
      threadId: "thread-legacy-sandbox",
      turnStartAccessConfiguration: ASK_TURN_START_ACCESS,
    },
  }), (response) => responses.push(JSON.parse(response)));
  await tick();
  fakeSocket.emitMessage({
    type: "session.input_transcript.delta",
    event_id: "legacy-sandbox-transcript",
    start_ms: 0,
    end_ms: 300,
    delta: "Use the compatible sandbox field.",
  });
  fakeSocket.emitMessage({
    type: "session.delegation.created",
    offset_ms: 300,
    delegation: { id: "legacy-sandbox-delegation", type: "delegation", target: "client" },
  });
  await delay(150);

  assert.equal(responses[0].error, undefined);
  assert.equal(turnStarts.length, 2);
  assert.equal(turnStarts[0].sandboxPolicy.type, "workspaceWrite");
  assert.equal(turnStarts[0].sandbox, undefined);
  assert.equal(turnStarts[1].sandboxPolicy, undefined);
  assert.equal(turnStarts[1].sandbox, "workspace-write");
  assert.equal(turnStarts[1].approvalPolicy, "on-request");
  assert.equal(turnStarts[1].approvalsReviewer, "user");
});

test("GPT-Live buffers a matching completion that arrives before the turn/start response", async () => {
  const responses = [];
  const upstreamMessages = [];
  const fakeSocket = makeLiveSocket({ upstreamMessages });
  let handler;
  handler = createRealtimeSessionHandler({
    apiKey: "local-only-api-key",
    sendCodexRequest: async (method, params) => {
      if (method === "thread/read") return { thread: { id: params.threadId } };
      assert.equal(method, "turn/start");
      handler.handleCodexMessage({
        method: "turn/completed",
        params: {
          threadId: params.threadId,
          turn: {
            id: "turn-before-start-response",
            status: "completed",
            items: [{
              id: "answer-before-start-response",
              type: "agentMessage",
              phase: "final_answer",
              text: "The matching final answer.",
            }],
          },
        },
      });
      return { turn: { id: "turn-before-start-response" } };
    },
    WebSocketImpl: class {
      constructor() {
        return fakeSocket;
      }
    },
  });

  handler.handleRealtimeSessionRequest(JSON.stringify({
    id: "pre-start-completion-session",
    method: "voice/realtime/session",
    params: { threadId: "thread-pre-start-completion" },
  }), (response) => responses.push(JSON.parse(response)));
  await tick();
  fakeSocket.emitMessage({
    type: "session.input_transcript.delta",
    event_id: "pre-start-transcript",
    start_ms: 0,
    end_ms: 300,
    delta: "Check completion ordering.",
  });
  fakeSocket.emitMessage({
    type: "session.delegation.created",
    offset_ms: 300,
    delegation: { id: "pre-start-delegation", type: "delegation", target: "client" },
  });
  await delay(150);

  assert.deepEqual(upstreamMessages
    .filter((event) => event.type === "session.commentary.append")
    .map((event) => event.content), ["The matching final answer."]);
});

test("GPT-Live close during turn-start wait suppresses a late answer", async () => {
  const responses = [];
  const upstreamMessages = [];
  const fakeSocket = makeLiveSocket({ upstreamMessages });
  let completeStart;
  let startCalls = 0;
  const handler = createRealtimeSessionHandler({
    apiKey: "local-only-api-key",
    sendCodexRequest: (method, params) => {
      if (method === "thread/read") return Promise.resolve({ thread: { id: params.threadId } });
      startCalls += 1;
      return new Promise((resolve) => { completeStart = resolve; });
    },
    WebSocketImpl: class {
      constructor() {
        return fakeSocket;
      }
    },
  });

  handler.handleRealtimeSessionRequest(JSON.stringify({
    id: "close-during-start-session",
    method: "voice/realtime/session",
    params: { threadId: "thread-close-during-start" },
  }), (response) => responses.push(JSON.parse(response)));
  await tick();
  fakeSocket.emitMessage({
    type: "session.input_transcript.delta",
    event_id: "close-during-start-transcript",
    start_ms: 0,
    end_ms: 300,
    delta: "Close while starting.",
  });
  fakeSocket.emitMessage({
    type: "session.delegation.created",
    offset_ms: 300,
    delegation: { id: "close-during-start-delegation", type: "delegation", target: "client" },
  });
  await delay(150);
  assert.equal(startCalls, 1);

  fakeSocket.emitMessage({ type: "session.closed" });
  completeStart({ turn: { id: "late-turn-after-close" } });
  await tick();

  assert.equal(upstreamMessages.some((event) => event.type === "session.commentary.append"), false);
});

test("GPT-Live rejects overlapping Codex delegation and clears the lock after completion", async () => {
  const responses = [];
  const upstreamMessages = [];
  const turnStarts = [];
  const fakeSocket = makeLiveSocket({ upstreamMessages });
  const handler = createRealtimeSessionHandler({
    apiKey: "local-only-api-key",
    delegationCompletionTimeoutMs: 500,
    sendCodexRequest: async (method, params) => {
      if (method === "thread/read") return { thread: { id: "thread-123" } };
      turnStarts.push(params);
      return { turn: { id: `busy-turn-${turnStarts.length}` } };
    },
    WebSocketImpl: class {
      constructor() {
        return fakeSocket;
      }
    },
  });
  handler.handleRealtimeSessionRequest(JSON.stringify({
    id: "live-busy",
    method: "voice/realtime/session",
    params: { threadId: "thread-123" },
  }), (response) => responses.push(JSON.parse(response)));
  await tick();

  const emitRequest = (text, startMs, endMs, delegationId) => {
    fakeSocket.emitMessage({
      type: "session.input_transcript.delta",
      event_id: `input-${delegationId}`,
      start_ms: startMs,
      end_ms: endMs,
      delta: text,
    });
    fakeSocket.emitMessage({
      type: "session.delegation.created",
      offset_ms: endMs,
      delegation: { id: delegationId, type: "delegation", target: "client" },
    });
  };
  emitRequest("First request", 0, 500, "delegate-busy-1");
  await delay(150);
  emitRequest("Overlapping request", 600, 900, "delegate-busy-2");
  await delay(150);

  assert.equal(turnStarts.length, 1, "a second voice request does not start a concurrent turn");
  assert.match(
    upstreamMessages.find((event) => event.delegation_id === "delegate-busy-2")?.content || "",
    /already working/
  );

  handler.handleCodexMessage({
    method: "turn/completed",
    params: {
      threadId: "thread-123",
      turn: { id: "busy-turn-1", status: "completed", items: [
        { id: "answer-busy-1", type: "agentMessage", phase: "final_answer", text: "First request completed." },
      ] },
    },
  });
  await tick();
  emitRequest("Later request", 1_000, 1_300, "delegate-busy-3");
  await delay(150);
  assert.equal(turnStarts.length, 2, "the thread lock is released after the matching turn completes");
  handler.handleCodexMessage({
    method: "turn/completed",
    params: {
      threadId: "thread-123",
      turn: { id: "busy-turn-2", status: "completed", items: [
        { id: "answer-busy-2", type: "agentMessage", phase: "final_answer", text: "Later request completed." },
      ] },
    },
  });
  await tick();
  assert.ok(upstreamMessages.some((event) => event.content === "Later request completed."));
});

test("GPT-Live does not retry an uncertain Codex start and times out completion waiters", async () => {
  const responses = [];
  const upstreamMessages = [];
  const turnStarts = [];
  const fakeSocket = makeLiveSocket({ upstreamMessages });
  const handler = createRealtimeSessionHandler({
    apiKey: "local-only-api-key",
    delegationCompletionTimeoutMs: 10,
    sendCodexRequest: async (method, params) => {
      if (method === "thread/read") return { thread: { id: "thread-123" } };
      turnStarts.push(params);
      if (turnStarts.length === 1) {
        throw new Error("timed out after the request may have reached Codex");
      }
      return { turn: { id: "timeout-turn-2" } };
    },
    WebSocketImpl: class {
      constructor() {
        return fakeSocket;
      }
    },
  });
  handler.handleRealtimeSessionRequest(JSON.stringify({
    id: "live-uncertain",
    method: "voice/realtime/session",
    params: { threadId: "thread-123" },
  }), (response) => responses.push(JSON.parse(response)));
  await tick();

  const emitRequest = (text, startMs, endMs, delegationId) => {
    fakeSocket.emitMessage({
      type: "session.input_transcript.delta",
      event_id: `input-${delegationId}`,
      start_ms: startMs,
      end_ms: endMs,
      delta: text,
    });
    fakeSocket.emitMessage({
      type: "session.delegation.created",
      offset_ms: endMs,
      delegation: { id: delegationId, type: "delegation", target: "client" },
    });
  };
  emitRequest("Possibly started", 0, 500, "delegate-uncertain");
  await delay(150);
  assert.equal(turnStarts.length, 1, "an uncertain start is never retried automatically");
  assert.match(
    upstreamMessages.find((event) => event.delegation_id === "delegate-uncertain")?.content || "",
    /didn't retry it/
  );

  emitRequest("Wait for completion", 600, 900, "delegate-timeout");
  await delay(170);
  assert.equal(turnStarts.length, 2);
  assert.match(
    upstreamMessages.find((event) => event.delegation_id === "delegate-timeout")?.content || "",
    /haven't received its final answer/
  );

  emitRequest("Try after timeout", 1_000, 1_300, "delegate-after-timeout");
  await delay(150);
  assert.equal(turnStarts.length, 3, "timeout cleanup releases the waiter for a later request");
});

test("GPT-Live commentary stays under its byte limit without splitting Unicode characters", async () => {
  const responses = [];
  const upstreamMessages = [];
  const fakeSocket = makeLiveSocket({ upstreamMessages });
  const handler = createRealtimeSessionHandler({
    apiKey: "local-only-api-key",
    sendCodexRequest: activeThreadRequest(),
    runDelegatedTask: async () => "🎙️".repeat(300),
    WebSocketImpl: class {
      constructor() {
        return fakeSocket;
      }
    },
  });
  handler.handleRealtimeSessionRequest(JSON.stringify({
    id: "live-unicode-cap",
    method: "voice/realtime/session",
    params: { threadId: "thread-123" },
  }), (response) => responses.push(JSON.parse(response)));
  await tick();

  fakeSocket.emitMessage({
    type: "session.input_transcript.delta",
    event_id: "input-unicode-cap",
    start_ms: 0,
    end_ms: 500,
    delta: "Read the answer aloud.",
  });
  fakeSocket.emitMessage({
    type: "session.delegation.created",
    offset_ms: 500,
    delegation: { id: "delegate-unicode-cap", type: "delegation", target: "client" },
  });
  await delay(150);

  const content = upstreamMessages.find((event) => event.type === "session.commentary.append")?.content || "";
  assert.ok(Buffer.byteLength(content, "utf8") <= 480);
  assert.equal(Buffer.from(content, "utf8").toString("utf8"), content);
});

test("GPT-Live drops delayed delegation work after the session begins closing", async () => {
  const responses = [];
  const upstreamMessages = [];
  const fakeSocket = makeLiveSocket({ upstreamMessages });
  let releaseDelegation;
  const handler = createRealtimeSessionHandler({
    apiKey: "mac-only-key",
    sendCodexRequest: activeThreadRequest(),
    runDelegatedTask: () => new Promise((resolve) => {
      releaseDelegation = resolve;
    }),
    WebSocketImpl: class {
      constructor() {
        return fakeSocket;
      }
    },
  });

  handler.handleRealtimeSessionRequest(JSON.stringify({
    id: "live-delayed-start",
    method: "voice/realtime/session",
    params: { threadId: "thread-123" },
  }), (response) => responses.push(JSON.parse(response)));
  await tick();
  const sessionId = responses[0].result.sessionId;

  fakeSocket.emitMessage({
    type: "session.input_transcript.delta",
    event_id: "input_delayed",
    start_ms: 0,
    end_ms: 500,
    delta: "Run the build.",
  });
  fakeSocket.emitMessage({
    type: "session.delegation.created",
    offset_ms: 500,
    delegation: { id: "item_delegate_delayed", type: "delegation", target: "client" },
  });
  await delay(150);

  handler.handleRealtimeSessionRequest(JSON.stringify({
    id: "live-delayed-close",
    method: "voice/realtime/close",
    params: { sessionId },
  }), (response) => responses.push(JSON.parse(response)));
  await tick();
  assert.equal(upstreamMessages.at(-1).type, "session.close");

  releaseDelegation?.("This must not be sent after close.");
  await tick();
  assert.equal(
    upstreamMessages.some((event) => event.type === "session.commentary.append"),
    false
  );
});

test("GPT-Live scopes each delegation to its transcript and waits for late transcript deltas", async () => {
  const responses = [];
  const upstreamMessages = [];
  const fakeSocket = makeLiveSocket({ upstreamMessages });
  const delegationCalls = [];
  const handler = createRealtimeSessionHandler({
    apiKey: "mac-only-key",
    sendCodexRequest: activeThreadRequest(),
    runDelegatedTask: async (context) => {
      delegationCalls.push(context);
      return "Done.";
    },
    WebSocketImpl: class {
      constructor() {
        return fakeSocket;
      }
    },
  });

  handler.handleRealtimeSessionRequest(JSON.stringify({
    id: "live-scoped-start",
    method: "voice/realtime/session",
    params: { threadId: "thread-123" },
  }), (response) => responses.push(JSON.parse(response)));
  await tick();
  const sessionId = responses[0].result.sessionId;

  const firstDelegation = {
    type: "session.delegation.created",
    offset_ms: 500,
    delegation: { id: "item_delegate_late", type: "delegation", target: "client" },
  };
  fakeSocket.emitMessage(firstDelegation);
  fakeSocket.emitMessage(firstDelegation);
  await tick();
  assert.equal(delegationCalls.length, 0, "a delegation without transcript must wait");

  fakeSocket.emitMessage({
    type: "session.input_transcript.delta",
    event_id: "input_late",
    start_ms: 50,
    end_ms: 500,
    delta: "Show me open pull requests.",
  });
  await delay(150);

  fakeSocket.emitMessage({
    type: "session.input_transcript.delta",
    event_id: "input_followup",
    start_ms: 900,
    end_ms: 1_200,
    delta: "Filter them to assigned reviews.",
  });
  fakeSocket.emitMessage({
    type: "session.delegation.created",
    offset_ms: 1_200,
    delegation: { id: "item_delegate_followup", type: "delegation", target: "client" },
  });
  await delay(150);

  assert.deepEqual(delegationCalls.map(({ delegationId, transcript }) => ({ delegationId, transcript })), [
    { delegationId: "item_delegate_late", transcript: "Show me open pull requests." },
    { delegationId: "item_delegate_followup", transcript: "Filter them to assigned reviews." },
  ]);
  assert.ok(delegationCalls.every((call) => call.sessionId === sessionId));
});

test("GPT-Live does not start a generic Codex command when a delegation has no transcript", async () => {
  const responses = [];
  const upstreamMessages = [];
  const fakeSocket = makeLiveSocket({ upstreamMessages });
  const codexCalls = [];
  const handler = createRealtimeSessionHandler({
    apiKey: "mac-only-key",
    sendCodexRequest: async (method, params) => {
      codexCalls.push({ method, params });
      return { thread: { id: "thread-123" } };
    },
    WebSocketImpl: class {
      constructor() {
        return fakeSocket;
      }
    },
  });

  handler.handleRealtimeSessionRequest(JSON.stringify({
    id: "live-no-transcript-start",
    method: "voice/realtime/session",
    params: { threadId: "thread-123" },
  }), (response) => responses.push(JSON.parse(response)));
  await tick();

  fakeSocket.emitMessage({
    type: "session.delegation.created",
    offset_ms: 500,
    delegation: { id: "item_delegate_empty", type: "delegation", target: "client" },
  });
  await tick();

  assert.equal(codexCalls.some(({ method }) => method === "turn/start"), false);
  const sessionId = responses[0].result.sessionId;
  handler.handleRealtimeSessionRequest(JSON.stringify({
    id: "live-no-transcript-close",
    method: "voice/realtime/close",
    params: { sessionId },
  }), () => {});
  await tick();
});

test("GPT-Live rejects odd-byte PCM16 chunks before provider append", async () => {
  const responses = [];
  const upstreamMessages = [];
  const fakeSocket = makeLiveSocket({ upstreamMessages });
  const handler = createRealtimeSessionHandler({
    apiKey: "mac-only-key",
    sendCodexRequest: activeThreadRequest(),
    WebSocketImpl: class {
      constructor() {
        return fakeSocket;
      }
    },
  });

  handler.handleRealtimeSessionRequest(JSON.stringify({
    id: "live-odd-byte-start",
    method: "voice/realtime/session",
    params: { threadId: "thread-123" },
  }), (response) => responses.push(JSON.parse(response)));
  await tick();
  const sessionId = responses[0].result.sessionId;

  handler.handleRealtimeSessionRequest(JSON.stringify({
    id: "live-odd-byte",
    method: "voice/realtime/audio",
    params: { sessionId, audio: "AQID" },
  }), (response) => responses.push(JSON.parse(response)));
  await tick();

  assert.equal(responses.at(-1).error?.data?.errorCode, "invalid_realtime_audio");
  assert.equal(upstreamMessages.some((event) => event.type === "session.input_audio.append"), false);
});

test("GPT-Live rejects response.create from client delegation controls", async () => {
  const responses = [];
  const upstreamMessages = [];
  const fakeSocket = makeLiveSocket({ upstreamMessages });
  const handler = createRealtimeSessionHandler({
    apiKey: "mac-only-key",
    sendCodexRequest: activeThreadRequest(),
    WebSocketImpl: class {
      constructor() {
        return fakeSocket;
      }
    },
  });

  handler.handleRealtimeSessionRequest(JSON.stringify({
    id: "live-control-start",
    method: "voice/realtime/session",
    params: { threadId: "thread-123" },
  }), (response) => responses.push(JSON.parse(response)));
  await tick();
  const sessionId = responses[0].result.sessionId;

  handler.handleRealtimeSessionRequest(JSON.stringify({
    id: "live-response-create",
    method: "voice/realtime/event",
    params: { sessionId, event: { type: "response.create" } },
  }), (response) => responses.push(JSON.parse(response)));
  await tick();

  assert.equal(responses.at(-1).error?.data?.errorCode, "unsupported_realtime_event");
  assert.equal(upstreamMessages.some((event) => event.type === "response.create"), false);
});

test("GPT-Live close waits for session.closed before closing the provider socket", async () => {
  const responses = [];
  const upstreamMessages = [];
  const fakeSocket = makeLiveSocket({ upstreamMessages });
  const handler = createRealtimeSessionHandler({
    apiKey: "mac-only-key",
    sendCodexRequest: activeThreadRequest(),
    closeFinalizationTimeoutMs: 100,
    WebSocketImpl: class {
      constructor() {
        return fakeSocket;
      }
    },
  });

  handler.handleRealtimeSessionRequest(JSON.stringify({
    id: "live-close-start",
    method: "voice/realtime/session",
    params: { threadId: "thread-123" },
  }), (response) => responses.push(JSON.parse(response)));
  await tick();
  const sessionId = responses[0].result.sessionId;

  handler.handleRealtimeSessionRequest(JSON.stringify({
    id: "live-close",
    method: "voice/realtime/close",
    params: { sessionId },
  }), (response) => responses.push(JSON.parse(response)));
  await tick();

  assert.deepEqual(responses.at(-1), { id: "live-close", result: { ok: true } });
  assert.deepEqual(upstreamMessages.at(-1), { type: "session.close" });
  assert.equal(fakeSocket.closeCount, 0);

  for (const [id, method, params] of [
    ["live-close-audio", "voice/realtime/audio", { sessionId, audio: "AQI=" }],
    ["live-close-control", "voice/realtime/event", { sessionId, event: { type: "session.input_audio.mute" } }],
  ]) {
    handler.handleRealtimeSessionRequest(JSON.stringify({ id, method, params }), (response) => {
      responses.push(JSON.parse(response));
    });
    await tick();
    assert.equal(responses.at(-1).error?.data?.errorCode, "invalid_realtime_session");
  }
  assert.equal(
    upstreamMessages.some((event) => event.type === "session.input_audio.append" || event.type === "session.input_audio.mute"),
    false
  );

  fakeSocket.emitMessage({ type: "session.closed" });
  await tick();
  assert.equal(fakeSocket.closeCount, 1);
});

test("GPT-Live finalizes a close when the provider never sends session.closed", async () => {
  const responses = [];
  const upstreamMessages = [];
  const fakeSocket = makeLiveSocket({ upstreamMessages });
  const handler = createRealtimeSessionHandler({
    apiKey: "mac-only-key",
    sendCodexRequest: activeThreadRequest(),
    closeFinalizationTimeoutMs: 5,
    WebSocketImpl: class {
      constructor() {
        return fakeSocket;
      }
    },
  });

  handler.handleRealtimeSessionRequest(JSON.stringify({
    id: "live-timeout-start",
    method: "voice/realtime/session",
    params: { threadId: "thread-123" },
  }), (response) => responses.push(JSON.parse(response)));
  await tick();
  const sessionId = responses[0].result.sessionId;
  handler.handleRealtimeSessionRequest(JSON.stringify({
    id: "live-timeout-close",
    method: "voice/realtime/close",
    params: { sessionId },
  }), () => {});
  await delay(20);

  assert.equal(fakeSocket.closeCount, 1);
});

test("GPT-Live abandons idle sessions after the cleanup deadline", async () => {
  const responses = [];
  const upstreamMessages = [];
  const fakeSocket = makeLiveSocket({ upstreamMessages });
  const handler = createRealtimeSessionHandler({
    apiKey: "mac-only-key",
    sendCodexRequest: activeThreadRequest(),
    idleTimeoutMs: 5,
    closeFinalizationTimeoutMs: 50,
    WebSocketImpl: class {
      constructor() {
        return fakeSocket;
      }
    },
  });

  handler.handleRealtimeSessionRequest(JSON.stringify({
    id: "live-idle-start",
    method: "voice/realtime/session",
    params: { threadId: "thread-123" },
  }), (response) => responses.push(JSON.parse(response)));
  await tick();
  await delay(20);

  assert.equal(upstreamMessages.at(-1).type, "session.close");
  assert.equal(fakeSocket.closeCount, 0);
  await delay(60);
  assert.equal(fakeSocket.closeCount, 1);
});

test("GPT-Live expiry cleanup requests provider close before bounded finalization", async () => {
  const responses = [];
  const upstreamMessages = [];
  const timerHandles = [];
  const fakeSocket = makeLiveSocket({
    upstreamMessages,
    startedEvent: {
      type: "session.started",
      session: { expires_at: 1_800_000_001 },
    },
  });
  const handler = createRealtimeSessionHandler({
    apiKey: "mac-only-key",
    now: () => 1_800_000_000_000,
    sendCodexRequest: activeThreadRequest(),
    closeFinalizationTimeoutMs: 5_000,
    setTimeoutImpl(callback, delayMs) {
      const handle = { callback, delayMs, cleared: false };
      timerHandles.push(handle);
      return handle;
    },
    clearTimeoutImpl(handle) {
      if (handle) handle.cleared = true;
    },
    WebSocketImpl: class {
      constructor() {
        return fakeSocket;
      }
    },
  });

  handler.handleRealtimeSessionRequest(JSON.stringify({
    id: "live-expiry-start",
    method: "voice/realtime/session",
    params: { threadId: "thread-123" },
  }), (response) => responses.push(JSON.parse(response)));
  await tick();

  const expiryTimer = timerHandles.find((handle) => !handle.cleared && handle.delayMs === 1_000);
  assert.ok(expiryTimer, "expected a one-second provider expiry timer");
  expiryTimer.callback();

  assert.equal(upstreamMessages.at(-1).type, "session.close");
  assert.equal(fakeSocket.closeCount, 0);

  const closeTimer = timerHandles.find((handle) => !handle.cleared && handle.delayMs === 5_000);
  assert.ok(closeTimer, "expected bounded close finalization timer");
  closeTimer.callback();
  assert.equal(fakeSocket.closeCount, 1);
});

test("voice/realtime/session returns only a bridge-owned session handle", async () => {
  const responses = [];
  const loggerCapture = makeLogger();
  const upstreamMessages = [];
  const fakeSocket = makeLiveSocket({ upstreamMessages });
  const handler = createRealtimeSessionHandler({
    apiKey: "mac-only-api-key",
    logger: loggerCapture.logger,
    sendCodexRequest: activeThreadRequest(),
    WebSocketImpl: class {
      constructor() {
        return fakeSocket;
      }
    },
  });

  const handled = handler.handleRealtimeSessionRequest(JSON.stringify({
    id: "realtime-1",
    method: "voice/realtime/session",
    params: { threadId: "thread-123" },
  }), (response) => {
    responses.push(JSON.parse(response));
  });

  assert.equal(handled, true);
  await tick();

  assert.equal(upstreamMessages[0].type, "session.start");
  assert.equal(upstreamMessages[0].session.model, "gpt-live-1");
  assert.deepEqual(upstreamMessages[0].session.delegation, { type: "client" });
  assert.equal(responses[0].result?.sessionId?.startsWith("live-"), true);
  assert.equal(responses[0].result?.transport, "bridge");
  assert.equal(responses[0].result?.clientSecret, undefined);
  assert.deepEqual(responses, [{
    id: "realtime-1",
    result: {
      sessionId: responses[0].result.sessionId,
      model: "gpt-live-1",
      transport: "bridge",
      expiresAt: 1_800_000_000,
    },
  }]);
  assert.equal(loggerCapture.messages.join("\n").includes("mac-only-api-key"), false);
});

test("voice/realtime/session is unavailable until a local bridge credential provider is configured", async () => {
  const responses = [];
  const handler = createRealtimeSessionHandler({ apiKey: "" });

  handler.handleRealtimeSessionRequest(JSON.stringify({
    id: "realtime-unconfigured",
    method: "voice/realtime/session",
    params: { threadId: "thread-123" },
  }), (response) => {
    responses.push(JSON.parse(response));
  });

  await tick();

  assert.equal(responses[0].error?.data?.errorCode, "realtime_not_configured");
  assert.match(responses[0].error?.message || "", /not configured/i);
});

test("voice/realtime/session opens the official GPT-Live endpoint with the Mac-only credential", async () => {
  const responses = [];
  const calls = [];
  const upstreamMessages = [];
  const fakeSocket = makeLiveSocket({ upstreamMessages });
  const loggerCapture = makeLogger();
  const handler = createRealtimeSessionHandler({
    apiKey: "local-only-api-key",
    logger: loggerCapture.logger,
    sendCodexRequest: activeThreadRequest(),
    WebSocketImpl: class {
      constructor(url, options) {
        calls.push({ url, options });
        return fakeSocket;
      }
    },
  });

  handler.handleRealtimeSessionRequest(JSON.stringify({
    id: "realtime-configured",
    method: "voice/realtime/session",
    params: { threadId: "thread-123" },
  }), (response) => {
    responses.push(JSON.parse(response));
  });

  await tick();

  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, "wss://api.openai.com/v1/live/sessions");
  assert.equal(calls[0].options.headers.Authorization, "Bearer local-only-api-key");
  assert.equal(calls[0].options.headers["OpenAI-Safety-Identifier"].includes("thread-123"), false);
  assert.equal(upstreamMessages[0].session.model, "gpt-live-1");
  assert.deepEqual(upstreamMessages[0].session.delegation, { type: "client" });
  assert.equal(responses[0].result?.clientSecret, undefined);
  assert.equal(loggerCapture.messages.join("\n").includes("local-only-api-key"), false);
});

test("voice/realtime/session rejects unscoped requests before opening a provider socket", async () => {
  const responses = [];
  let socketCalls = 0;
  const handler = createRealtimeSessionHandler({
    apiKey: "local-only-api-key",
    sendCodexRequest: activeThreadRequest(),
    WebSocketImpl: class {
      constructor() {
        socketCalls += 1;
        throw new Error("should not open");
      }
    },
  });

  handler.handleRealtimeSessionRequest(JSON.stringify({
    id: "realtime-missing-thread",
    method: "voice/realtime/session",
    params: {},
  }), (response) => {
    responses.push(JSON.parse(response));
  });

  await tick();

  assert.equal(socketCalls, 0);
  assert.equal(responses[0].error?.data?.errorCode, "invalid_realtime_scope");
});

test("voice/realtime/session rejects an unknown or inactive Codex thread before opening a provider socket", async () => {
  for (const [name, response] of [
    ["unknown", { thread: null }],
    ["inactive", { thread: { id: "thread-123", archived: true } }],
  ]) {
    const responses = [];
    let socketCalls = 0;
    const codexCalls = [];
    const handler = createRealtimeSessionHandler({
      apiKey: "local-only-api-key",
      sendCodexRequest: async (method, params) => {
        codexCalls.push({ method, params });
        return response;
      },
      WebSocketImpl: class {
        constructor() {
          socketCalls += 1;
          throw new Error("should not open");
        }
      },
    });

    handler.handleRealtimeSessionRequest(JSON.stringify({
      id: `realtime-${name}-thread`,
      method: "voice/realtime/session",
      params: { threadId: "thread-123" },
    }), (rawResponse) => responses.push(JSON.parse(rawResponse)));

    await tick();

    assert.deepEqual(codexCalls, [{
      method: "thread/read",
      params: { threadId: "thread-123", includeTurns: false },
    }]);
    assert.equal(socketCalls, 0);
    assert.equal(responses[0].error?.data?.errorCode, "invalid_realtime_scope");
  }
});

test("voice/realtime/session rejects an already expired provider session", async () => {
  const responses = [];
  const upstreamMessages = [];
  const fakeSocket = makeLiveSocket({
    upstreamMessages,
    startedEvent: { type: "session.started", session: { expires_at: 1_699_999_999 } },
  });
  const handler = createRealtimeSessionHandler({
    apiKey: "local-only-api-key",
    sendCodexRequest: activeThreadRequest(),
    now: () => 1_700_000_000_000,
    WebSocketImpl: class {
      constructor() {
        return fakeSocket;
      }
    },
  });

  handler.handleRealtimeSessionRequest(JSON.stringify({
    id: "realtime-expired-secret",
    method: "voice/realtime/session",
    params: { threadId: "thread-123" },
  }), (rawResponse) => responses.push(JSON.parse(rawResponse)));

  await tick();

  assert.equal(responses[0].error?.data?.errorCode, "realtime_invalid_response");
  assert.equal(responses[0].result, undefined);
});

test("voice/transcribe returns transcribed text without exposing auth tokens", async () => {
  const responses = [];
  const fetchCalls = [];
  const loggerCapture = makeLogger();
  const audioBase64 = makeTestWavBase64();
  const authToken = makeJWT({
    "https://api.openai.com/auth": {
      chatgpt_account_id: "acct-123",
    },
  });
  const handler = createVoiceHandler({
    logger: loggerCapture.logger,
    sendCodexRequest: async (method, params) => {
      assert.equal(method, "getAuthStatus");
      assert.deepEqual(params, {
        includeToken: true,
        refreshToken: false,
      });
      return {
        authMethod: "chatgpt",
        authToken,
        requiresOpenaiAuth: false,
      };
    },
    fetchImpl: async (url, options) => {
      fetchCalls.push({ url, options });
      return {
        ok: true,
        status: 200,
        async json() {
          return { text: "hello world" };
        },
      };
    },
  });

  const handled = handler.handleVoiceRequest(JSON.stringify({
    id: "voice-1",
    method: "voice/transcribe",
    params: {
      mimeType: "audio/wav",
      audioBase64,
      sampleRateHz: 24_000,
      durationMs: 1_200,
    },
  }), (response) => {
    responses.push(JSON.parse(response));
  });

  assert.equal(handled, true);
  await tick();

  assert.equal(fetchCalls.length, 1);
  assert.equal(fetchCalls[0].url, "https://chatgpt.com/backend-api/transcribe");
  assert.equal(fetchCalls[0].options.method, "POST");
  assert.equal(fetchCalls[0].options.headers.Authorization.startsWith("Bearer "), true);
  assert.equal(fetchCalls[0].options.headers["ChatGPT-Account-Id"], undefined);
  assert.match(fetchCalls[0].options.headers["User-Agent"], /Safari/);
  assert.deepEqual(responses, [{
    id: "voice-1",
    result: {
      text: "hello world",
    },
  }]);

  const logText = loggerCapture.messages.join("\n");
  assert.match(logText, /voice transcribe request received durationMs=1200 actualDurationMs=\d+ audioBytes=46/);
  assert.match(logText, /voice transcribe auth selected attempt=1 source=mac_runtime method=chatgpt provider=chatgpt/);
  assert.match(logText, /voice transcribe provider status attempt=1 provider=chatgpt status=200 ok=true/);
  assert.match(logText, /voice transcribe success provider=chatgpt status=200 textLength=11/);
  assert.equal(logText.includes(authToken), false);
  assert.equal(logText.includes("acct-123"), false);
  assert.equal(logText.includes(audioBase64), false);
  assert.doesNotMatch(logText, /Bearer/i);
});

test("voice/resolveAuth returns a ChatGPT token for legacy phone clients", async () => {
  const result = await resolveVoiceAuth(async (method, params) => {
    assert.equal(method, "getAuthStatus");
    assert.deepEqual(params, {
      includeToken: true,
      refreshToken: true,
    });
    return {
      authMethod: "chatgpt",
      authToken: "chatgpt-token",
      requiresOpenaiAuth: false,
    };
  });

  assert.deepEqual(result, { token: "chatgpt-token" });
});

test("voice/transcribe normalizes bearer-prefixed ChatGPT tokens", async () => {
  const fetchCalls = [];
  const handler = createVoiceHandler({
    sendCodexRequest: async () => ({
      authMethod: "chatgpt_auth_tokens",
      authToken: "Bearer chatgpt-token",
      requiresOpenaiAuth: false,
    }),
    fetchImpl: async (url, options) => {
      fetchCalls.push({ url, options });
      return {
        ok: true,
        status: 200,
        async json() {
          return { text: "normalized" };
        },
      };
    },
  });

  handler.handleVoiceRequest(JSON.stringify({
    id: "voice-normalized-bearer",
    method: "voice/transcribe",
    params: {
      mimeType: "audio/wav",
      audioBase64: makeTestWavBase64(),
      sampleRateHz: 24_000,
      durationMs: 800,
    },
  }), () => {});

  await tick();

  assert.equal(fetchCalls[0].url, "https://chatgpt.com/backend-api/transcribe");
  assert.equal(fetchCalls[0].options.headers.Authorization, "Bearer chatgpt-token");
});

test("voice/resolveAuth normalizes bearer-prefixed tokens for legacy clients", async () => {
  const result = await resolveVoiceAuth(async () => ({
    authMethod: "chatgpt_auth_tokens",
    authToken: "Bearer chatgpt-token",
    requiresOpenaiAuth: false,
  }));

  assert.deepEqual(result, { token: "chatgpt-token" });
});

test("voice/resolveAuth rejects API-key auth for legacy direct upload clients", async () => {
  await assert.rejects(
    () => resolveVoiceAuth(async () => ({
      authMethod: "apiKey",
      authToken: "sk-test",
      requiresOpenaiAuth: false,
    })),
    (error) => {
      assert.equal(error.errorCode, "not_chatgpt");
      assert.match(error.message, /ChatGPT account/);
      return true;
    }
  );
});

test("voice/transcribe retries once after a 401 response", async () => {
  const responses = [];
  const authRequestParams = [];
  let authRequestCount = 0;
  let fetchCount = 0;
  const handler = createVoiceHandler({
    sendCodexRequest: async (_method, params) => {
      authRequestCount += 1;
      authRequestParams.push(params);
      return {
        authMethod: "chatgpt",
        authToken: makeJWT({
          "https://api.openai.com/auth": {
            chatgpt_account_id: `acct-${authRequestCount}`,
          },
        }),
        requiresOpenaiAuth: false,
      };
    },
    fetchImpl: async () => {
      fetchCount += 1;
      if (fetchCount === 1) {
        return {
          ok: false,
          status: 401,
          async json() {
            return { error: { message: "expired" } };
          },
        };
      }

      return {
        ok: true,
        status: 200,
        async json() {
          return { text: "second try works" };
        },
      };
    },
  });

  handler.handleVoiceRequest(JSON.stringify({
    id: "voice-2",
    method: "voice/transcribe",
    params: {
      mimeType: "audio/wav",
      audioBase64: makeTestWavBase64(),
      sampleRateHz: 24_000,
      durationMs: 800,
    },
  }), (response) => {
    responses.push(JSON.parse(response));
  });

  await tick();

  assert.equal(authRequestCount, 2);
  assert.equal(fetchCount, 2);
  assert.equal(authRequestParams[0].refreshToken, false);
  assert.equal(authRequestParams[1].refreshToken, true);
  assert.equal(responses[0].result?.text, "second try works");
});

test("voice/transcribe retries once after a 403 response", async () => {
  const responses = [];
  let authRequestCount = 0;
  let fetchCount = 0;
  const handler = createVoiceHandler({
    sendCodexRequest: async () => {
      authRequestCount += 1;
      return {
        authMethod: "chatgpt",
        authToken: makeJWT({
          "https://api.openai.com/auth": {
            chatgpt_account_id: `acct-${authRequestCount}`,
          },
        }),
        requiresOpenaiAuth: false,
      };
    },
    fetchImpl: async () => {
      fetchCount += 1;
      if (fetchCount === 1) {
        return {
          ok: false,
          status: 403,
          async json() {
            return { error: { message: "forbidden" } };
          },
        };
      }

      return {
        ok: true,
        status: 200,
        async json() {
          return { text: "third try works" };
        },
      };
    },
  });

  handler.handleVoiceRequest(JSON.stringify({
    id: "voice-403",
    method: "voice/transcribe",
    params: {
      mimeType: "audio/wav",
      audioBase64: makeTestWavBase64(),
      sampleRateHz: 24_000,
      durationMs: 800,
    },
  }), (response) => {
    responses.push(JSON.parse(response));
  });

  await tick();

  assert.equal(authRequestCount, 2);
  assert.equal(fetchCount, 2);
  assert.equal(responses[0].result?.text, "third try works");
});

test("voice/transcribe accepts valid WAV files with metadata chunks before fmt", async () => {
  const responses = [];
  const handler = createVoiceHandler({
    sendCodexRequest: async () => ({
      authMethod: "chatgpt",
      authToken: "chatgpt-token",
      requiresOpenaiAuth: false,
    }),
    fetchImpl: async () => ({
      ok: true,
      status: 200,
      async json() {
        return { text: "chunked wav works" };
      },
    }),
  });

  handler.handleVoiceRequest(JSON.stringify({
    id: "voice-chunked-wav",
    method: "voice/transcribe",
    params: {
      mimeType: "audio/wav",
      audioBase64: makeTestWavBase64({ includeJunkChunk: true }),
      sampleRateHz: 24_000,
      durationMs: 800,
    },
  }), (response) => {
    responses.push(JSON.parse(response));
  });

  await tick();

  assert.equal(responses[0].result?.text, "chunked wav works");
});

test("voice/transcribe rejects API-key auth before contacting the provider", async () => {
  const responses = [];
  let fetchCalls = 0;
  const handler = createVoiceHandler({
    sendCodexRequest: async () => ({
      authMethod: "apiKey",
      authToken: "sk-test",
      requiresOpenaiAuth: false,
    }),
    fetchImpl: async () => {
      fetchCalls += 1;
      throw new Error("fetch should not run for API-key auth");
    },
  });

  handler.handleVoiceRequest(JSON.stringify({
    id: "voice-4",
    method: "voice/transcribe",
    params: {
      mimeType: "audio/wav",
      audioBase64: makeTestWavBase64(),
      sampleRateHz: 24_000,
      durationMs: 300,
    },
  }), (response) => {
    responses.push(JSON.parse(response));
  });

  await tick();

  assert.equal(fetchCalls, 0);
  assert.equal(responses[0].error?.data?.errorCode, "not_chatgpt");
  assert.match(responses[0].error?.message || "", /ChatGPT account/);
});

test("voice/transcribe requires ChatGPT auth even when an OPENAI_API_KEY is present", async () => {
  const responses = [];
  let authRequestCount = 0;
  let fetchCalls = 0;
  const handler = createVoiceHandler({
    env: {
      OPENAI_API_KEY: "sk-env-ignored",
    },
    sendCodexRequest: async () => {
      authRequestCount += 1;
      return {
        authMethod: null,
        authToken: null,
        requiresOpenaiAuth: true,
      };
    },
    fetchImpl: async () => {
      fetchCalls += 1;
      throw new Error("fetch should not run without ChatGPT auth");
    },
  });

  handler.handleVoiceRequest(JSON.stringify({
    id: "voice-api-key-ignored",
    method: "voice/transcribe",
    params: {
      mimeType: "audio/wav",
      audioBase64: makeTestWavBase64(),
      sampleRateHz: 24_000,
      durationMs: 300,
    },
  }), (response) => {
    responses.push(JSON.parse(response));
  });

  await tick();

  assert.equal(authRequestCount, 1);
  assert.equal(fetchCalls, 0);
  assert.equal(responses[0].error?.data?.errorCode, "not_authenticated");
  assert.match(responses[0].error?.message || "", /Sign in with ChatGPT/);
});

test("voice/transcribe logs provider failures without raw provider details", async () => {
  const responses = [];
  const loggerCapture = makeLogger();
  const audioBase64 = makeTestWavBase64();
  const authToken = "chatgpt-provider-failure";
  const handler = createVoiceHandler({
    logger: loggerCapture.logger,
    sendCodexRequest: async () => ({
      authMethod: "chatgpt",
      authToken,
      requiresOpenaiAuth: false,
    }),
    fetchImpl: async () => ({
      ok: false,
      status: 500,
      async json() {
        return {
          error: {
            message: `provider leaked Bearer ${authToken} and ${audioBase64}`,
          },
        };
      },
    }),
  });

  handler.handleVoiceRequest(JSON.stringify({
    id: "voice-provider-failure",
    method: "voice/transcribe",
    params: {
      mimeType: "audio/wav",
      audioBase64,
      sampleRateHz: 24_000,
      durationMs: 300,
    },
  }), (response) => {
    responses.push(JSON.parse(response));
  });

  await tick();

  const logText = loggerCapture.messages.join("\n");
  assert.equal(responses[0].error?.data?.errorCode, "transcription_failed");
  assert.equal(responses[0].error?.data?.provider, "chatgpt");
  assert.equal(responses[0].error?.data?.status, 500);
  assert.doesNotMatch(responses[0].error?.message || "", /Bearer|provider leaked|chatgpt-provider-failure/);
  assert.match(logText, /voice transcribe request received durationMs=300 actualDurationMs=\d+ audioBytes=46/);
  assert.match(logText, /voice transcribe auth selected attempt=1 source=mac_runtime method=chatgpt provider=chatgpt/);
  assert.match(logText, /voice transcribe provider status attempt=1 provider=chatgpt status=500 ok=false/);
  assert.match(logText, /voice transcribe failed errorCode=transcription_failed/);
  assert.equal(logText.includes(authToken), false);
  assert.equal(logText.includes(audioBase64), false);
  assert.doesNotMatch(logText, /Bearer/i);
});

test("voice/transcribe does not fall back to OPENAI_API_KEY when ChatGPT auth is rejected", async () => {
  const responses = [];
  const fetchCalls = [];
  const handler = createVoiceHandler({
    env: {
      OPENAI_API_KEY: "sk-env-fallback",
    },
    sendCodexRequest: async () => ({
      authMethod: "chatgpt",
      authToken: "expired-chatgpt-token",
      requiresOpenaiAuth: false,
    }),
    fetchImpl: async (url, options) => {
      fetchCalls.push({ url, options });
      return {
        ok: false,
        status: 401,
        async json() {
          return { error: { message: "expired" } };
        },
      };
    },
  });

  handler.handleVoiceRequest(JSON.stringify({
    id: "voice-chatgpt-api-fallback",
    method: "voice/transcribe",
    params: {
      mimeType: "audio/wav",
      audioBase64: makeTestWavBase64(),
      sampleRateHz: 24_000,
      durationMs: 300,
    },
  }), (response) => {
    responses.push(JSON.parse(response));
  });

  await tick();

  assert.equal(fetchCalls.length, 2);
  assert.equal(fetchCalls[0].url, "https://chatgpt.com/backend-api/transcribe");
  assert.equal(fetchCalls[1].url, "https://chatgpt.com/backend-api/transcribe");
  assert.equal(fetchCalls.some((call) => call.url.includes("api.openai.com")), false);
  assert.equal(responses[0].error?.data?.errorCode, "auth_rejected");
  assert.equal(responses[0].error?.data?.provider, "chatgpt");
  assert.match(responses[0].error?.message || "", /ChatGPT login/);
});

test("voice/transcribe returns a user-facing auth error when Mac auth is missing", async () => {
  const responses = [];
  const handler = createVoiceHandler({
    env: {},
    sendCodexRequest: async () => ({
      authMethod: null,
      authToken: null,
      requiresOpenaiAuth: true,
    }),
    fetchImpl: async () => {
      throw new Error("fetch should not run");
    },
  });

  handler.handleVoiceRequest(JSON.stringify({
    id: "voice-3",
    method: "voice/transcribe",
    params: {
      mimeType: "audio/wav",
      audioBase64: makeTestWavBase64(),
      sampleRateHz: 24_000,
      durationMs: 300,
    },
  }), (response) => {
    responses.push(JSON.parse(response));
  });

  await tick();

  assert.equal(responses[0].error?.data?.errorCode, "not_authenticated");
  assert.match(responses[0].error?.message || "", /Sign in with ChatGPT/);
});

test("voice/transcribe maps auth status read failures to reconnect guidance", async () => {
  const responses = [];
  const handler = createVoiceHandler({
    sendCodexRequest: async () => {
      throw new Error("socket closed");
    },
    fetchImpl: async () => {
      throw new Error("fetch should not run");
    },
  });

  handler.handleVoiceRequest(JSON.stringify({
    id: "voice-auth-unavailable",
    method: "voice/transcribe",
    params: {
      mimeType: "audio/wav",
      audioBase64: makeTestWavBase64(),
      sampleRateHz: 24_000,
      durationMs: 300,
    },
  }), (response) => {
    responses.push(JSON.parse(response));
  });

  await tick();

  assert.equal(responses[0].error?.data?.errorCode, "auth_unavailable");
  assert.match(responses[0].error?.message || "", /Could not read ChatGPT auth/);
});

test("voice/transcribe rejects malformed or non-WAV audio before contacting the provider", async () => {
  const cases = [
    {
      name: "malformed base64",
      audioBase64: "%%%not-base64%%%",
      message: /could not be decoded/,
    },
    {
      name: "non-WAV payload",
      audioBase64: Buffer.from("hello from remodex").toString("base64"),
      message: /not a valid WAV file/,
    },
  ];

  for (const testCase of cases) {
    const responses = [];
    let authRequests = 0;
    let fetchCalls = 0;
    const handler = createVoiceHandler({
      sendCodexRequest: async () => {
        authRequests += 1;
        throw new Error("auth should not be requested for invalid audio");
      },
      fetchImpl: async () => {
        fetchCalls += 1;
        throw new Error("fetch should not run for invalid audio");
      },
    });

    handler.handleVoiceRequest(JSON.stringify({
      id: `voice-invalid-${testCase.name}`,
      method: "voice/transcribe",
      params: {
        mimeType: "audio/wav",
        audioBase64: testCase.audioBase64,
        sampleRateHz: 24_000,
        durationMs: 300,
      },
    }), (response) => {
      responses.push(JSON.parse(response));
    });

    await tick();

    assert.equal(authRequests, 0);
    assert.equal(fetchCalls, 0);
    assert.equal(responses[0].error?.data?.errorCode, "invalid_audio");
    assert.match(responses[0].error?.message || "", testCase.message);
  }
});

test("voice/transcribe rejects unsupported WAV metadata before contacting auth", async () => {
  const responses = [];
  let authRequests = 0;
  let fetchCalls = 0;
  const handler = createVoiceHandler({
    sendCodexRequest: async () => {
      authRequests += 1;
      throw new Error("auth should not be requested for unsupported audio");
    },
    fetchImpl: async () => {
      fetchCalls += 1;
      throw new Error("fetch should not run for unsupported audio");
    },
  });

  handler.handleVoiceRequest(JSON.stringify({
    id: "voice-unsupported-wav",
    method: "voice/transcribe",
    params: {
      mimeType: "audio/wav",
      audioBase64: makeTestWavBase64({ sampleRateHz: 16_000 }),
      sampleRateHz: 24_000,
      durationMs: 300,
    },
  }), (response) => {
    responses.push(JSON.parse(response));
  });

  await tick();

  assert.equal(authRequests, 0);
  assert.equal(fetchCalls, 0);
  assert.equal(responses[0].error?.data?.errorCode, "unsupported_sample_rate");
  assert.match(responses[0].error?.message || "", /24 kHz mono WAV/);
});

test("voice/transcribe accepts large clips without overflowing base64 validation", async () => {
  const responses = [];
  let fetchCalls = 0;
  const handler = createVoiceHandler({
    sendCodexRequest: async () => ({
      authMethod: "chatgpt",
      authToken: "chatgpt-token",
      requiresOpenaiAuth: false,
    }),
    fetchImpl: async () => {
      fetchCalls += 1;
      return {
        ok: true,
        status: 200,
        async json() {
          return { text: "long clip transcript" };
        },
      };
    },
  });

  handler.handleVoiceRequest(JSON.stringify({
    id: "voice-large-valid",
    method: "voice/transcribe",
    params: {
      mimeType: "audio/wav",
      audioBase64: makeTestWavBase64({ durationSeconds: 150 }),
      sampleRateHz: 24_000,
      durationMs: 150_000,
    },
  }), (response) => {
    responses.push(JSON.parse(response));
  });

  await tick();

  assert.equal(fetchCalls, 1);
  assert.equal(responses[0].result?.text, "long clip transcript");
});

test("voice/transcribe rejects clips longer than 150 seconds before contacting the provider", async () => {
  const responses = [];
  let authRequests = 0;
  let fetchCalls = 0;
  const handler = createVoiceHandler({
    sendCodexRequest: async () => {
      authRequests += 1;
      throw new Error("auth should not be requested for overlong audio");
    },
    fetchImpl: async () => {
      fetchCalls += 1;
      throw new Error("fetch should not run for overlong audio");
    },
  });

  handler.handleVoiceRequest(JSON.stringify({
    id: "voice-too-long",
    method: "voice/transcribe",
    params: {
      mimeType: "audio/wav",
      audioBase64: makeTestWavBase64(),
      sampleRateHz: 24_000,
      durationMs: 150_100,
    },
  }), (response) => {
    responses.push(JSON.parse(response));
  });

  await tick();

  assert.equal(authRequests, 0);
  assert.equal(fetchCalls, 0);
  assert.equal(responses[0].error?.data?.errorCode, "duration_too_long");
  assert.match(responses[0].error?.message || "", /150 seconds/);
});

test("voice/transcribe rejects WAV data whose actual duration exceeds the limit", async () => {
  const responses = [];
  let authRequests = 0;
  let fetchCalls = 0;
  const handler = createVoiceHandler({
    sendCodexRequest: async () => {
      authRequests += 1;
      throw new Error("auth should not be requested for oversized audio");
    },
    fetchImpl: async () => {
      fetchCalls += 1;
      throw new Error("fetch should not run for oversized audio");
    },
  });

  handler.handleVoiceRequest(JSON.stringify({
    id: "voice-actual-too-long",
    method: "voice/transcribe",
    params: {
      mimeType: "audio/wav",
      audioBase64: makeTestWavBase64({ durationSeconds: 151 }),
      sampleRateHz: 24_000,
      durationMs: 150_000,
    },
  }), (response) => {
    responses.push(JSON.parse(response));
  });

  await tick();

  assert.equal(authRequests, 0);
  assert.equal(fetchCalls, 0);
  assert.equal(responses[0].error?.data?.errorCode, "duration_too_long");
  assert.match(responses[0].error?.message || "", /150 seconds/);
});

test("voice/transcribe rejects inconsistent WAV byte-rate metadata before contacting the provider", async () => {
  const responses = [];
  let authRequests = 0;
  let fetchCalls = 0;
  const handler = createVoiceHandler({
    sendCodexRequest: async () => {
      authRequests += 1;
      throw new Error("auth should not be requested for malformed audio");
    },
    fetchImpl: async () => {
      fetchCalls += 1;
      throw new Error("fetch should not run for malformed audio");
    },
  });

  handler.handleVoiceRequest(JSON.stringify({
    id: "voice-forged-byte-rate",
    method: "voice/transcribe",
    params: {
      mimeType: "audio/wav",
      audioBase64: makeTestWavBase64({
        durationSeconds: 151,
        byteRate: 4_800_000,
      }),
      sampleRateHz: 24_000,
      durationMs: 150_000,
    },
  }), (response) => {
    responses.push(JSON.parse(response));
  });

  await tick();

  assert.equal(authRequests, 0);
  assert.equal(fetchCalls, 0);
  assert.equal(responses[0].error?.data?.errorCode, "invalid_audio");
  assert.match(responses[0].error?.message || "", /valid WAV/);
});

test("voice/transcribe rejects audio that is materially longer than the request duration", async () => {
  const responses = [];
  let authRequests = 0;
  let fetchCalls = 0;
  const handler = createVoiceHandler({
    sendCodexRequest: async () => {
      authRequests += 1;
      throw new Error("auth should not be requested for mismatched audio");
    },
    fetchImpl: async () => {
      fetchCalls += 1;
      throw new Error("fetch should not run for mismatched audio");
    },
  });

  handler.handleVoiceRequest(JSON.stringify({
    id: "voice-duration-mismatch",
    method: "voice/transcribe",
    params: {
      mimeType: "audio/wav",
      audioBase64: makeTestWavBase64({ durationSeconds: 5 }),
      sampleRateHz: 24_000,
      durationMs: 1_000,
    },
  }), (response) => {
    responses.push(JSON.parse(response));
  });

  await tick();

  assert.equal(authRequests, 0);
  assert.equal(fetchCalls, 0);
  assert.equal(responses[0].error?.data?.errorCode, "duration_mismatch");
  assert.match(responses[0].error?.message || "", /duration/);
});

test("voice/transcribe aborts stalled provider requests", async () => {
  const responses = [];
  let abortSeen = false;
  const handler = createVoiceHandler({
    transcriptionTimeoutMs: 1,
    sendCodexRequest: async () => ({
      authMethod: "chatgpt",
      authToken: "chatgpt-token",
      requiresOpenaiAuth: false,
    }),
    fetchImpl: async (_url, options) => new Promise((_resolve, reject) => {
      options.signal?.addEventListener("abort", () => {
        abortSeen = true;
        reject(options.signal.reason || new Error("aborted"));
      }, { once: true });
    }),
  });

  handler.handleVoiceRequest(JSON.stringify({
    id: "voice-provider-timeout",
    method: "voice/transcribe",
    params: {
      mimeType: "audio/wav",
      audioBase64: makeTestWavBase64(),
      sampleRateHz: 24_000,
      durationMs: 300,
    },
  }), (response) => {
    responses.push(JSON.parse(response));
  });

  await delay(20);

  assert.equal(abortSeen, true);
  assert.equal(responses[0].error?.data?.errorCode, "transcription_timeout");
  assert.equal(responses[0].error?.data?.provider, "chatgpt");
  assert.match(responses[0].error?.message || "", /timed out/);
});

test("voice/prewarm preconnects to the provider and pre-loads auth", async () => {
  const responses = [];
  const fetchCalls = [];
  let authRequestCount = 0;
  const handler = createVoiceHandler({
    sendCodexRequest: async (method, params) => {
      authRequestCount += 1;
      assert.equal(method, "getAuthStatus");
      assert.equal(params.refreshToken, false);
      return {
        authMethod: "chatgpt",
        authToken: "chatgpt-token",
        requiresOpenaiAuth: false,
      };
    },
    fetchImpl: async (url, options) => {
      fetchCalls.push({ url, options });
      return { ok: true, status: 200, async json() { return {}; } };
    },
  });

  const handled = handler.handleVoiceRequest(JSON.stringify({
    id: "voice-prewarm-1",
    method: "voice/prewarm",
  }), (response) => {
    responses.push(JSON.parse(response));
  });

  assert.equal(handled, true);
  await tick();

  assert.deepEqual(responses, [{ id: "voice-prewarm-1", result: { ok: true, formats: ["wav", "m4a"] } }]);
  assert.equal(authRequestCount, 1);
  assert.equal(fetchCalls.length, 1);
  assert.equal(fetchCalls[0].url, "https://chatgpt.com/");
  assert.equal(fetchCalls[0].options.method, "HEAD");
});

test("voice/transcribe accepts valid M4A clips and uploads them as audio/mp4", async () => {
  const responses = [];
  const formAppends = [];
  const handler = createVoiceHandler({
    sendCodexRequest: async () => ({
      authMethod: "chatgpt",
      authToken: "chatgpt-token",
      requiresOpenaiAuth: false,
    }),
    FormDataImpl: class FakeFormData {
      append(...args) {
        formAppends.push(args);
      }
    },
    BlobImpl: class FakeBlob {
      constructor(parts, options) {
        this.parts = parts;
        this.type = options.type;
      }
    },
    fetchImpl: async () => ({
      ok: true,
      status: 200,
      async json() {
        return { text: "m4a transcript" };
      },
    }),
  });

  handler.handleVoiceRequest(JSON.stringify({
    id: "voice-m4a-valid",
    method: "voice/transcribe",
    params: {
      mimeType: "audio/mp4",
      audioBase64: makeTestM4ABase64({ durationSeconds: 1 }),
      sampleRateHz: 24_000,
      durationMs: 1_000,
    },
  }), (response) => {
    responses.push(JSON.parse(response));
  });

  await tick();

  assert.equal(responses[0].result?.text, "m4a transcript");
  assert.equal(formAppends.length, 1);
  assert.equal(formAppends[0][0], "file");
  assert.equal(formAppends[0][1].type, "audio/mp4");
  assert.equal(formAppends[0][2], "voice.m4a");
});

test("voice/transcribe accepts mono AAC clips whose sample entry reports 2 channels", async () => {
  // CoreAudio writes channelCount=2 in the mp4a sample entry even for mono AAC,
  // so Remodex-generated clips from AVAudioFile must not be rejected.
  const responses = [];
  const handler = createVoiceHandler({
    sendCodexRequest: async () => ({
      authMethod: "chatgpt",
      authToken: "chatgpt-token",
      requiresOpenaiAuth: false,
    }),
    fetchImpl: async () => ({
      ok: true,
      status: 200,
      async json() {
        return { text: "coreaudio m4a transcript" };
      },
    }),
  });

  handler.handleVoiceRequest(JSON.stringify({
    id: "voice-m4a-coreaudio-channels",
    method: "voice/transcribe",
    params: {
      mimeType: "audio/mp4",
      audioBase64: makeTestM4ABase64({ durationSeconds: 1, channelCount: 2 }),
      sampleRateHz: 24_000,
      durationMs: 1_000,
    },
  }), (response) => {
    responses.push(JSON.parse(response));
  });

  await tick();

  assert.equal(responses[0].result?.text, "coreaudio m4a transcript");
});

test("voice/transcribe rejects M4A clips whose mvhd duration exceeds the limit", async () => {
  const responses = [];
  let authRequests = 0;
  const handler = createVoiceHandler({
    sendCodexRequest: async () => {
      authRequests += 1;
      throw new Error("auth should not be requested for overlong m4a");
    },
    fetchImpl: async () => {
      throw new Error("fetch should not run for overlong m4a");
    },
  });

  handler.handleVoiceRequest(JSON.stringify({
    id: "voice-m4a-too-long",
    method: "voice/transcribe",
    params: {
      mimeType: "audio/mp4",
      audioBase64: makeTestM4ABase64({ durationSeconds: 151 }),
      sampleRateHz: 24_000,
      durationMs: 150_000,
    },
  }), (response) => {
    responses.push(JSON.parse(response));
  });

  await tick();

  assert.equal(authRequests, 0);
  assert.equal(responses[0].error?.data?.errorCode, "duration_too_long");
  assert.match(responses[0].error?.message || "", /150 seconds/);
});

test("voice/transcribe rejects M4A clips whose audio track duration exceeds the limit", async () => {
  const responses = [];
  let authRequests = 0;
  const handler = createVoiceHandler({
    sendCodexRequest: async () => {
      authRequests += 1;
      throw new Error("auth should not be requested for overlong m4a track");
    },
    fetchImpl: async () => {
      throw new Error("fetch should not run for overlong m4a track");
    },
  });

  handler.handleVoiceRequest(JSON.stringify({
    id: "voice-m4a-track-too-long",
    method: "voice/transcribe",
    params: {
      mimeType: "audio/mp4",
      audioBase64: makeTestM4ABase64({ durationSeconds: 1, mediaDurationSeconds: 151 }),
      sampleRateHz: 24_000,
      durationMs: 150_000,
    },
  }), (response) => {
    responses.push(JSON.parse(response));
  });

  await tick();

  assert.equal(authRequests, 0);
  assert.equal(responses[0].error?.data?.errorCode, "duration_too_long");
  assert.match(responses[0].error?.message || "", /150 seconds/);
});

test("voice/transcribe rejects forged M4A containers before contacting auth", async () => {
  const responses = [];
  let authRequests = 0;
  const handler = createVoiceHandler({
    sendCodexRequest: async () => {
      authRequests += 1;
      throw new Error("auth should not be requested for invalid m4a");
    },
    fetchImpl: async () => {
      throw new Error("fetch should not run for invalid m4a");
    },
  });

  handler.handleVoiceRequest(JSON.stringify({
    id: "voice-m4a-forged",
    method: "voice/transcribe",
    params: {
      mimeType: "audio/mp4",
      audioBase64: makeTestM4ABase64({ brand: "mp42", compatibleBrand: "mp42" }),
      sampleRateHz: 24_000,
      durationMs: 1_000,
    },
  }), (response) => {
    responses.push(JSON.parse(response));
  });

  await tick();

  assert.equal(authRequests, 0);
  assert.equal(responses[0].error?.data?.errorCode, "invalid_audio");
  assert.match(responses[0].error?.message || "", /M4A/);
});

test("voice/transcribe reuses auth pre-loaded by voice/prewarm", async () => {
  const responses = [];
  let authRequestCount = 0;
  const handler = createVoiceHandler({
    sendCodexRequest: async () => {
      authRequestCount += 1;
      return {
        authMethod: "chatgpt",
        authToken: "chatgpt-token",
        requiresOpenaiAuth: false,
      };
    },
    fetchImpl: async () => ({
      ok: true,
      status: 200,
      async json() {
        return { text: "prewarmed transcript" };
      },
    }),
  });

  handler.handleVoiceRequest(JSON.stringify({
    id: "voice-prewarm-2",
    method: "voice/prewarm",
  }), () => {});
  await tick();
  assert.equal(authRequestCount, 1);

  handler.handleVoiceRequest(JSON.stringify({
    id: "voice-prewarm-transcribe",
    method: "voice/transcribe",
    params: {
      mimeType: "audio/wav",
      audioBase64: makeTestWavBase64(),
      sampleRateHz: 24_000,
      durationMs: 300,
    },
  }), (response) => {
    responses.push(JSON.parse(response));
  });
  await tick();

  assert.equal(authRequestCount, 1);
  assert.equal(responses[0].result?.text, "prewarmed transcript");
});

test("voice/prewarm auth failures do not poison later transcriptions", async () => {
  const responses = [];
  let authRequestCount = 0;
  const handler = createVoiceHandler({
    sendCodexRequest: async () => {
      authRequestCount += 1;
      if (authRequestCount === 1) {
        throw new Error("socket closed");
      }
      return {
        authMethod: "chatgpt",
        authToken: "chatgpt-token",
        requiresOpenaiAuth: false,
      };
    },
    fetchImpl: async () => ({
      ok: true,
      status: 200,
      async json() {
        return { text: "recovered transcript" };
      },
    }),
  });

  handler.handleVoiceRequest(JSON.stringify({
    id: "voice-prewarm-3",
    method: "voice/prewarm",
  }), () => {});
  await tick();

  handler.handleVoiceRequest(JSON.stringify({
    id: "voice-prewarm-recovery",
    method: "voice/transcribe",
    params: {
      mimeType: "audio/wav",
      audioBase64: makeTestWavBase64(),
      sampleRateHz: 24_000,
      durationMs: 300,
    },
  }), (response) => {
    responses.push(JSON.parse(response));
  });
  await tick();

  assert.equal(authRequestCount, 2);
  assert.equal(responses[0].result?.text, "recovered transcript");
});

function makeJWT(payload) {
  const header = base64UrlEncode({ alg: "none", typ: "JWT" });
  const body = base64UrlEncode(payload);
  return `${header}.${body}.signature`;
}

function makeTestWavBase64({
  sampleRateHz = 24_000,
  includeJunkChunk = false,
  durationSeconds = null,
  byteRate = sampleRateHz * 2,
  blockAlign = 2,
} = {}) {
  const chunks = [];
  if (includeJunkChunk) {
    const junk = Buffer.alloc(12);
    junk.write("JUNK", 0, "ascii");
    junk.writeUInt32LE(4, 4);
    junk.writeUInt32LE(0x01020304, 8);
    chunks.push(junk);
  }

  const fmt = Buffer.alloc(24);
  fmt.write("fmt ", 0, "ascii");
  fmt.writeUInt32LE(16, 4);
  fmt.writeUInt16LE(1, 8);
  fmt.writeUInt16LE(1, 10);
  fmt.writeUInt32LE(sampleRateHz, 12);
  fmt.writeUInt32LE(byteRate, 16);
  fmt.writeUInt16LE(blockAlign, 20);
  fmt.writeUInt16LE(16, 22);
  chunks.push(fmt);

  const dataByteCount = durationSeconds == null
    ? 2
    : Math.max(2, Math.floor(durationSeconds * sampleRateHz * 2));
  const data = Buffer.alloc(8 + dataByteCount);
  data.write("data", 0, "ascii");
  data.writeUInt32LE(dataByteCount, 4);
  data.writeInt16LE(0, 8);
  chunks.push(data);

  const payloadSize = chunks.reduce((sum, chunk) => sum + chunk.length, 0);
  const header = Buffer.alloc(12);
  header.write("RIFF", 0, "ascii");
  header.writeUInt32LE(4 + payloadSize, 4);
  header.write("WAVE", 8, "ascii");
  return Buffer.concat([header, ...chunks]).toString("base64");
}

function makeTestM4ABase64({
  durationSeconds = 1,
  mediaDurationSeconds = durationSeconds,
  brand = "M4A ",
  compatibleBrand = "M4A ",
  includeMediaData = true,
  sampleRateHz = 24_000,
  channelCount = 1,
} = {}) {
  const ftypPayload = Buffer.alloc(12);
  ftypPayload.write(brand, 0, "ascii");
  ftypPayload.writeUInt32BE(0, 4);
  ftypPayload.write(compatibleBrand, 8, "ascii");

  const mvhdPayload = Buffer.alloc(100);
  mvhdPayload.writeUInt8(0, 0); // version 0
  mvhdPayload.writeUInt32BE(1_000, 12);
  mvhdPayload.writeUInt32BE(Math.max(1, Math.round(durationSeconds * 1_000)), 16);

  const mdhdPayload = Buffer.alloc(24);
  mdhdPayload.writeUInt8(0, 0); // version 0
  mdhdPayload.writeUInt32BE(sampleRateHz, 12);
  mdhdPayload.writeUInt32BE(Math.max(1, Math.round(mediaDurationSeconds * sampleRateHz)), 16);

  const hdlrPayload = Buffer.alloc(24);
  hdlrPayload.write("soun", 8, "ascii");

  const mp4aPayload = Buffer.alloc(28);
  mp4aPayload.writeUInt16BE(1, 6); // data_reference_index
  mp4aPayload.writeUInt16BE(channelCount, 16);
  mp4aPayload.writeUInt16BE(16, 18);
  mp4aPayload.writeUInt32BE(sampleRateHz << 16, 24);

  const stsdPayload = Buffer.concat([
    Buffer.from([0, 0, 0, 0, 0, 0, 0, 1]),
    mp4Box("mp4a", mp4aPayload),
  ]);

  const boxes = [
    mp4Box("ftyp", ftypPayload),
    mp4Box("moov", Buffer.concat([
      mp4Box("mvhd", mvhdPayload),
      mp4Box("trak", mp4Box("mdia", Buffer.concat([
        mp4Box("mdhd", mdhdPayload),
        mp4Box("hdlr", hdlrPayload),
        mp4Box("minf", mp4Box("stbl", mp4Box("stsd", stsdPayload))),
      ]))),
    ])),
  ];
  if (includeMediaData) {
    boxes.push(mp4Box("mdat", Buffer.from([0, 1, 2, 3])));
  }
  return Buffer.concat(boxes).toString("base64");
}

function mp4Box(type, payload) {
  const header = Buffer.alloc(8);
  header.writeUInt32BE(8 + payload.length, 0);
  header.write(type, 4, "ascii");
  return Buffer.concat([header, payload]);
}

function base64UrlEncode(value) {
  return Buffer.from(JSON.stringify(value))
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

// Captures handler log output without mutating the process-wide console.
function makeLogger() {
  const messages = [];
  return {
    messages,
    logger: {
      log(message) {
        messages.push(String(message));
      },
      warn(message) {
        messages.push(String(message));
      },
      error(message) {
        messages.push(String(message));
      },
    },
  };
}

function makeLiveSocket({ upstreamMessages, startedEvent = null } = {}) {
  const listeners = new Map();
  const socket = {
    readyState: 1,
    closeCount: 0,
    on(eventName, listener) {
      listeners.set(eventName, listener);
    },
    send(rawMessage) {
      const event = JSON.parse(String(rawMessage));
      upstreamMessages.push(event);
      if (event.type === "session.start") {
        queueMicrotask(() => {
          listeners.get("message")?.({
            data: JSON.stringify(startedEvent || {
              type: "session.started",
              session: { expires_at: 1_800_000_000 },
            }),
          });
        });
      }
    },
    close() {
      socket.closeCount += 1;
      socket.readyState = 3;
      listeners.get("close")?.();
    },
    emitMessage(event) {
      listeners.get("message")?.({ data: JSON.stringify(event) });
    },
  };
  return socket;
}

function tick() {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

function activeThreadRequest() {
  return async (method, params) => {
    assert.equal(method, "thread/read");
    assert.deepEqual(params, { threadId: "thread-123", includeTurns: false });
    return { thread: { id: "thread-123" } };
  };
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

test("device GPT-Live sessions bypass bridge credentials and provider sockets and reject key or audio payloads", async () => {
  const responses = [];
  const loggerCapture = makeLogger();
  let credentialResolverCalls = 0;
  let providerSocketCalls = 0;
  const handler = createRealtimeSessionHandler({
    apiKeyResolver() {
      credentialResolverCalls += 1;
      return { apiKey: "must-not-be-used" };
    },
    credentialResolver() {
      credentialResolverCalls += 1;
      return { apiKey: "must-not-be-used" };
    },
    WebSocketImpl: class {
      constructor() {
        providerSocketCalls += 1;
        throw new Error("device path must not open a bridge provider socket");
      }
    },
    sendCodexRequest: activeThreadRequest(),
    resolveThreadOwner: async () => "single-runtime",
    logger: loggerCapture.logger,
  });
  const request = (id, method, params) => handler.handleRealtimeSessionRequest(
    JSON.stringify({ id, method, params }),
    (response) => responses.push(JSON.parse(response))
  );

  assert.equal(request("device-session", "voice/realtime/device/session", {
    threadId: "thread-123",
    turnStartAccessConfiguration: ASK_TURN_START_ACCESS,
  }), true);
  await tick();

  const sessionResponse = responses.find((response) => response.id === "device-session");
  assert.equal(sessionResponse.result?.transport, "device");
  assert.equal(sessionResponse.result?.model, "gpt-live-1");
  assert.equal(sessionResponse.result?.clientSecret, undefined);
  assert.equal(credentialResolverCalls, 0);
  assert.equal(providerSocketCalls, 0);

  const sessionId = sessionResponse.result.sessionId;
  request("device-key", "voice/realtime/device/session", {
    threadId: "thread-123",
    apiKey: "must-not-be-used",
  });
  request("device-audio", "voice/realtime/device/event", {
    sessionId,
    event: { type: "session.input_audio.append", audio: "AQI=" },
  });
  request("legacy-audio", "voice/realtime/audio", { sessionId, audio: "AQI=" });
  await tick();

  assert.equal(responses.find((response) => response.id === "device-key").error?.data?.errorCode,
    "invalid_device_realtime_request");
  assert.equal(responses.find((response) => response.id === "device-audio").error?.data?.errorCode,
    "unsupported_device_realtime_event");
  assert.equal(responses.find((response) => response.id === "legacy-audio").error?.data?.errorCode,
    "unsupported_device_realtime_event");
  assert.equal(credentialResolverCalls, 0);
  assert.equal(providerSocketCalls, 0);
  assert.equal(loggerCapture.messages.join("\n").includes("must-not-be-used"), false);

  request("device-close", "voice/realtime/device/close", { sessionId });
  await tick();
  assert.deepEqual(responses.find((response) => response.id === "device-close"), {
    id: "device-close",
    result: { ok: true },
  });
});

test("device GPT-Live transcript and delegation events reuse bridge selection and return only commentary", async () => {
  const responses = [];
  const applicationEvents = [];
  const delegatedContexts = [];
  let credentialResolverCalls = 0;
  let providerSocketCalls = 0;
  const handler = createRealtimeSessionHandler({
    apiKeyResolver() {
      credentialResolverCalls += 1;
      return "must-not-be-used";
    },
    WebSocketImpl: class {
      constructor() {
        providerSocketCalls += 1;
        throw new Error("device path must not open a bridge provider socket");
      }
    },
    sendCodexRequest: activeThreadRequest(),
    resolveThreadOwner: async () => "single-runtime",
    async runDelegatedTask(context) {
      delegatedContexts.push(context);
      return "Codex verified the requested result.";
    },
    sendApplicationResponse(rawMessage) {
      applicationEvents.push(JSON.parse(rawMessage));
    },
  });
  const request = (id, method, params) => handler.handleRealtimeSessionRequest(
    JSON.stringify({ id, method, params }),
    (response) => responses.push(JSON.parse(response))
  );

  request("device-session", "voice/realtime/device/session", {
    threadId: "thread-123",
    turnStartAccessConfiguration: ASK_TURN_START_ACCESS,
  });
  await tick();
  const sessionId = responses[0].result.sessionId;

  request("device-transcript", "voice/realtime/device/event", {
    sessionId,
    event: {
      type: "session.input_transcript.delta",
      event_id: "input_1",
      start_ms: 0,
      end_ms: 500,
      delta: "Check the current branch.",
    },
  });
  request("device-delegation", "voice/realtime/device/event", {
    sessionId,
    event: {
      type: "session.delegation.created",
      event_id: "delegation_1",
      offset_ms: 500,
      delegation: { id: "item_delegate_1", type: "delegation", target: "client" },
    },
  });
  await delay(150);

  assert.deepEqual(delegatedContexts, [{
    threadId: "thread-123",
    sessionId,
    delegationId: "item_delegate_1",
    transcript: "Check the current branch.",
  }]);
  const returnedEvents = applicationEvents.filter((message) => message.method === "voice/realtime/device/event");
  assert.equal(returnedEvents.length, 1);
  assert.deepEqual(returnedEvents[0].params, {
    sessionId,
    event: {
      type: "session.commentary.append",
      event_id: returnedEvents[0].params.event.event_id,
      delegation_id: "item_delegate_1",
      content: "Codex verified the requested result.",
    },
  });
  assert.equal(JSON.stringify(applicationEvents).includes("audio"), false);
  assert.equal(JSON.stringify(applicationEvents).includes("must-not-be-used"), false);
  assert.equal(credentialResolverCalls, 0);
  assert.equal(providerSocketCalls, 0);

  request("device-close", "voice/realtime/device/close", { sessionId });
  await tick();
  assert.equal(responses.find((response) => response.id === "device-close").result?.ok, true);
});

test("device GPT-Live idle and expiry close the phone and discard pending delegations", async () => {
  const scenarios = [
    { name: "idle", reason: "idle", idleTimeoutMs: 5, timerDelayMs: 5 },
    { name: "expiry", reason: "expired", idleTimeoutMs: 60_000, timerDelayMs: 900_000 },
  ];

  for (const scenario of scenarios) {
    const responses = [];
    const applicationEvents = [];
    const timerHandles = [];
    const delegatedContexts = [];
    const now = 1_800_000_000_000;
    const handler = createRealtimeSessionHandler({
      now: () => now,
      idleTimeoutMs: scenario.idleTimeoutMs,
      sendCodexRequest: activeThreadRequest(),
      sendApplicationResponse(rawMessage) {
        applicationEvents.push(JSON.parse(rawMessage));
      },
      async runDelegatedTask(context) {
        delegatedContexts.push(context);
        return "This work must not run after session termination.";
      },
      setTimeoutImpl(callback, delayMs) {
        const handle = { callback, delayMs, cleared: false };
        timerHandles.push(handle);
        return handle;
      },
      clearTimeoutImpl(handle) {
        if (handle) handle.cleared = true;
      },
    });
    const request = (id, method, params) => handler.handleRealtimeSessionRequest(
      JSON.stringify({ id, method, params }),
      (response) => responses.push(JSON.parse(response))
    );

    request(`${scenario.name}-session`, "voice/realtime/device/session", {
      threadId: "thread-123",
    });
    await tick();
    const sessionID = responses.find((response) => response.id === `${scenario.name}-session`).result.sessionId;
    request(`${scenario.name}-delegation`, "voice/realtime/device/event", {
      sessionId: sessionID,
      event: {
        type: "session.delegation.created",
        event_id: `${scenario.name}-delegation-event`,
        offset_ms: 500,
        delegation: { id: `${scenario.name}-pending`, type: "delegation", target: "client" },
      },
    });
    await tick();

    const expirationTimer = [...timerHandles].reverse().find((handle) => (
      !handle.cleared && handle.delayMs === scenario.timerDelayMs
    ));
    assert.ok(expirationTimer, `${scenario.name} timer should be scheduled`);
    expirationTimer.callback();
    await tick();

    const terminalEvent = applicationEvents.find((message) => (
      message.method === "voice/realtime/device/event"
        && message.params?.sessionId === sessionID
        && message.params?.event?.type === "session.closed"
    ));
    assert.ok(terminalEvent, `${scenario.name} should notify the iPhone that the session closed`);
    assert.equal(terminalEvent.params.event.reason, scenario.reason);
    assert.equal(delegatedContexts.length, 0, "pending Codex delegation must be discarded");
    assert.equal(
      timerHandles.find((handle) => handle.delayMs === 3_000)?.cleared,
      true,
      "pending delegation timeout should be canceled",
    );
    assert.equal(
      applicationEvents.some((message) => message.params?.event?.type === "session.commentary.append"),
      false,
      "terminated sessions must not send new commentary",
    );
  }
});
