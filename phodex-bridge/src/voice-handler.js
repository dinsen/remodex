// FILE: voice-handler.js
// Purpose: Handles bridge-owned voice transcription and prewarm requests without exposing auth tokens to iPhone.
// Layer: Bridge handler
// Exports: createVoiceHandler, resolveVoiceAuth
// Depends on: global fetch/FormData/Blob, local codex app-server auth via sendCodexRequest, ./voice-audio

const {
  hasConsistentVoiceWavLayout,
  isSupportedVoiceWavFormat,
  readM4AInfo,
  readWavInfo,
  wavDurationMs,
} = require("./voice-audio");
const { randomUUID, createHash } = require("crypto");
const {
  OPENAI_KEYCHAIN_ACCOUNT,
  OPENAI_KEYCHAIN_SERVICE,
  resolveOpenAIAPIKey,
} = require("./openai-credential");
const DefaultWebSocket = require("ws");

const CHATGPT_TRANSCRIPTIONS_URL = "https://chatgpt.com/backend-api/transcribe";
const OPENAI_LIVE_WEBSOCKET_URL = "wss://api.openai.com/v1/live/sessions";
const DEFAULT_LIVE_MODEL = "gpt-live-1";
const DEFAULT_LIVE_AUDIO_FORMAT = Object.freeze({ type: "audio/pcm", rate: 24_000 });
const DEFAULT_LIVE_VOICE = "marin";
const LIVE_SESSION_TTL_MS = 15 * 60 * 1_000;
const LIVE_START_TIMEOUT_MS = 15_000;
const LIVE_CLOSE_FINALIZATION_TIMEOUT_MS = 5_000;
const LIVE_IDLE_TIMEOUT_MS = 10 * 60 * 1_000;
const LIVE_DELEGATION_TRANSCRIPT_SETTLE_MS = 100;
const LIVE_DELEGATION_TRANSCRIPT_TIMEOUT_MS = 3_000;
const MAX_TIMER_DELAY_MS = 0x7fff_ffff;
const MAX_LIVE_AUDIO_CHUNK_BYTES = 512 * 1024;
const MAX_LIVE_EVENT_BYTES = 64 * 1024;
const MAX_AUDIO_BYTES = 10 * 1024 * 1024;
const MAX_DURATION_SECONDS = 150;
const MAX_DURATION_MS = MAX_DURATION_SECONDS * 1_000;
const DEFAULT_TRANSCRIPTION_TIMEOUT_MS = 175_000;
const MAX_DURATION_DRIFT_MS = 2_000;
const AUTH_CACHE_TTL_MS = 60_000;
const PRECONNECT_MIN_INTERVAL_MS = 2_000;
const PRECONNECT_TIMEOUT_MS = 10_000;
// Live endpoint probes confirmed subscription uploads accept AAC m4a alongside WAV.
const VOICE_AUDIO_FORMATS = ["wav", "m4a"];
const VOICE_WAV_MIME_TYPE = "audio/wav";
const VOICE_M4A_MIME_TYPE = "audio/mp4";
// Cloudflare rejects Node's default fetch identity on chatgpt.com with an HTML 403,
// which used to fail every bridge upload and force the slow phone-direct fallback.
// If the accepted identity changes again (symptom: transcription turns slow because
// every upload falls back to the phone), override it without a release via env.
const VOICE_UPLOAD_USER_AGENT = process.env.REMODEX_VOICE_UPLOAD_USER_AGENT
  || "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15";

function createVoiceHandler({
  sendCodexRequest,
  fetchImpl = globalThis.fetch,
  FormDataImpl = globalThis.FormData,
  BlobImpl = globalThis.Blob,
  logPrefix = "[remodex]",
  logger = console,
  transcriptionTimeoutMs = DEFAULT_TRANSCRIPTION_TIMEOUT_MS,
} = {}) {
  // Keeps a short-lived auth context plus TLS preconnect so the post-recording
  // transcription request skips the token refresh and handshake round trips.
  const warmState = {
    authPromise: null,
    authLoadedAt: 0,
    lastPreconnectAt: 0,
  };

  function cacheAuthPromise(promise) {
    warmState.authPromise = promise;
    warmState.authLoadedAt = Date.now();
    promise.catch(() => {
      if (warmState.authPromise === promise) {
        warmState.authPromise = null;
      }
    });
    return promise;
  }

  function loadAuth() {
    if (warmState.authPromise && Date.now() - warmState.authLoadedAt < AUTH_CACHE_TTL_MS) {
      return warmState.authPromise;
    }
    return cacheAuthPromise(loadAuthContext(sendCodexRequest, { refreshToken: false }));
  }

  function refreshAuth() {
    return cacheAuthPromise(loadAuthContext(sendCodexRequest, { refreshToken: true }));
  }

  // Opens (or revives) the HTTPS connection to the provider so the upload fetch reuses it.
  function preconnectTranscriptionOrigin() {
    if (typeof fetchImpl !== "function") {
      return;
    }
    const now = Date.now();
    if (now - warmState.lastPreconnectAt < PRECONNECT_MIN_INTERVAL_MS) {
      return;
    }
    warmState.lastPreconnectAt = now;

    const controller = typeof AbortController === "function" ? new AbortController() : null;
    const timeoutID = controller
      ? setTimeout(() => controller.abort(new Error("voice preconnect timed out")), PRECONNECT_TIMEOUT_MS)
      : null;
    timeoutID?.unref?.();

    Promise.resolve()
      .then(() => fetchImpl(new URL("/", CHATGPT_TRANSCRIPTIONS_URL).toString(), {
        method: "HEAD",
        headers: { "User-Agent": VOICE_UPLOAD_USER_AGENT },
        signal: controller?.signal,
      }))
      .then((response) => {
        response?.body?.cancel?.()?.catch?.(() => {});
      })
      .catch(() => {})
      .finally(() => {
        if (timeoutID) {
          clearTimeout(timeoutID);
        }
      });
  }

  function handlePrewarmRequest(id, sendResponse) {
    preconnectTranscriptionOrigin();
    loadAuth().catch(() => {});
    logVoiceEvent(logger, "log", logPrefix, "prewarm requested");
    if (id != null) {
      sendResponse(JSON.stringify({ id, result: { ok: true, formats: VOICE_AUDIO_FORMATS } }));
    }
  }

  function handleVoiceRequest(rawMessage, sendResponse, parsedMessage = null) {
    const parsed = parsedMessage || parseJsonMessage(rawMessage);
    if (!parsed) {
      return false;
    }

    const method = typeof parsed?.method === "string" ? parsed.method.trim() : "";
    if (method === "voice/prewarm") {
      handlePrewarmRequest(parsed.id, sendResponse);
      return true;
    }
    if (method !== "voice/transcribe") {
      return false;
    }

    const id = parsed.id;
    const params = parsed.params || {};

    transcribeVoice(params, {
      sendCodexRequest,
      fetchImpl,
      FormDataImpl,
      BlobImpl,
      logger,
      logPrefix,
      transcriptionTimeoutMs,
      loadAuth,
      refreshAuth,
    })
      .then((result) => {
        sendResponse(JSON.stringify({ id, result }));
      })
      .catch((error) => {
        logVoiceEvent(logger, "error", logPrefix, "failed", {
          errorCode: error.errorCode || "voice_transcription_failed",
        });
        sendResponse(JSON.stringify({
          id,
          error: {
            code: -32000,
            message: error.userMessage || error.message || "Voice transcription failed.",
            data: voiceErrorData(error),
          },
        }));
      });

    return true;
  }

  return {
    handleVoiceRequest,
  };
}

// Owns GPT-Live sessions on the Mac bridge. The phone reaches this handler only
// after secure-transport pairing/decryption, so the long-lived OpenAI key never
// crosses the relay or device boundary. The bridge also keeps Codex delegation
// context here and returns only a short, user-visible commentary summary.
function createRealtimeSessionHandler({
  apiKey,
  apiKeyResolver = resolveOpenAIAPIKey,
  credentialResolver = null,
  env = process.env,
  platform = process.platform,
  commandRunner,
  WebSocketImpl = DefaultWebSocket,
  sendCodexRequest = null,
  runDelegatedTask = null,
  sendApplicationResponse = null,
  logger = console,
  logPrefix = "[remodex]",
  now = Date.now,
  sessionTimeoutMs = LIVE_START_TIMEOUT_MS,
  closeFinalizationTimeoutMs = LIVE_CLOSE_FINALIZATION_TIMEOUT_MS,
  idleTimeoutMs = LIVE_IDLE_TIMEOUT_MS,
  setTimeoutImpl = setTimeout,
  clearTimeoutImpl = clearTimeout,
} = {}) {
  const sessions = new Map();
  const resolveCredential = () => {
    // apiKey is an explicit dependency-injection hook for tests and local
    // embedding. Production bridge construction leaves it undefined so the
    // Keychain-first resolver is used at session start.
    if (apiKey !== undefined) {
      const normalized = readString(apiKey);
      return normalized ? { apiKey: normalized, source: "injected" } : null;
    }
    const resolver = typeof credentialResolver === "function"
      ? credentialResolver
      : apiKeyResolver;
    if (typeof resolver !== "function") {
      return null;
    }
    try {
      const result = resolver({ env, platform, commandRunner });
      if (typeof result === "string") {
        return result.trim() ? { apiKey: result.trim(), source: "resolver" } : null;
      }
      const normalized = readString(result?.apiKey);
      return normalized ? { apiKey: normalized, source: readString(result?.source) || "resolver" } : null;
    } catch {
      // Resolver failures are deliberately opaque; command output may contain
      // the credential and must never reach logs or phone-facing errors.
      return null;
    }
  };

  function handleRealtimeSessionRequest(rawMessage, sendResponse, parsedMessage = null) {
    const parsed = parsedMessage || parseJsonMessage(rawMessage);
    if (!parsed || typeof parsed.method !== "string") {
      return false;
    }

    const method = parsed.method;
    if (method === "voice/realtime/session") {
      handleSessionStart(parsed, sendResponse);
      return true;
    }
    if (method === "voice/realtime/audio") {
      handleAudioAppend(parsed, sendResponse);
      return true;
    }
    if (method === "voice/realtime/event") {
      handleClientEvent(parsed, sendResponse);
      return true;
    }
    if (method === "voice/realtime/close") {
      handleSessionClose(parsed, sendResponse);
      return true;
    }
    return false;
  }

  function handleSessionStart(parsed, sendResponse) {
    const threadId = readString(parsed.params?.threadId);
    const id = parsed.id;
    Promise.resolve()
      .then(async () => {
        if (!threadId) {
          throw voiceError("invalid_realtime_scope", "Voice needs an active conversation before it can start.");
        }
        const credential = resolveCredential();
        if (!credential?.apiKey) {
          throw voiceError(
            "realtime_not_configured",
            "Live Voice is not configured on this Mac bridge."
          );
        }

        await verifyRealtimeThread(sendCodexRequest, threadId);

        return await openLiveSession({
          threadId,
          apiKey: credential.apiKey,
          now,
          sessionTimeoutMs,
          closeFinalizationTimeoutMs,
          idleTimeoutMs,
          setTimeoutImpl,
          clearTimeoutImpl,
        });
      })
      .then((result) => {
        if (id != null) {
          sendResponse(JSON.stringify({ id, result }));
        }
      })
      .catch((error) => {
        logRealtimeEvent(logger, "error", logPrefix, "session failed", {
          errorCode: error.errorCode || "realtime_session_failed",
        });
        if (id != null) {
          sendResponse(JSON.stringify({
            id,
            error: {
              code: -32000,
              message: error.userMessage || "Live Voice could not be started.",
              data: voiceErrorData(error),
            },
          }));
        }
      });
  }

  function handleAudioAppend(parsed, sendResponse) {
    const id = parsed.id;
    const params = parsed.params || {};
    const state = readSession(sessions, params.sessionId);
    const encodedAudio = readString(params.audio || params.audioBase64);
    Promise.resolve()
      .then(() => {
        if (!state) {
          throw voiceError("invalid_realtime_session", "The Live Voice session is no longer available.");
        }
        if (state.closeRequested) {
          throw voiceError("invalid_realtime_session", "The Live Voice session is closing.");
        }
        const requestedThreadId = readString(params.threadId);
        if (requestedThreadId && requestedThreadId !== state.threadId) {
          throw voiceError("invalid_realtime_scope", "Voice needs an active conversation before it can continue.");
        }
        const audioBuffer = decodeLiveAudioBase64(encodedAudio);
        if (!audioBuffer
          || audioBuffer.length === 0
          || audioBuffer.length % 2 !== 0
          || audioBuffer.length > MAX_LIVE_AUDIO_CHUNK_BYTES) {
          throw voiceError("invalid_realtime_audio", "Live Voice audio was not valid PCM data.");
        }
        touchLiveSession(state);
        sendLiveSocketEvent(state, {
          type: "session.input_audio.append",
          audio: encodedAudio,
        });
        return { ok: true };
      })
      .then((result) => {
        if (id != null) {
          sendResponse(JSON.stringify({ id, result }));
        }
      })
      .catch((error) => sendRealtimeErrorResponse(id, sendResponse, error, logger, logPrefix));
  }

  function handleClientEvent(parsed, sendResponse) {
    const id = parsed.id;
    const params = parsed.params || {};
    const state = readSession(sessions, params.sessionId);
    const event = params.event && typeof params.event === "object"
      ? params.event
      : params;
    Promise.resolve()
      .then(() => {
        if (!state) {
          throw voiceError("invalid_realtime_session", "The Live Voice session is no longer available.");
        }
        if (state.closeRequested) {
          throw voiceError("invalid_realtime_session", "The Live Voice session is closing.");
        }
        const requestedThreadId = readString(params.threadId);
        if (requestedThreadId && requestedThreadId !== state.threadId) {
          throw voiceError("invalid_realtime_scope", "Voice needs an active conversation before it can continue.");
        }
        if (!isAllowedLiveClientEvent(event)) {
          throw voiceError("unsupported_realtime_event", "That Live Voice control is not supported.");
        }
        touchLiveSession(state);
        sendLiveSocketEvent(state, event);
        return { ok: true };
      })
      .then((result) => {
        if (id != null) {
          sendResponse(JSON.stringify({ id, result }));
        }
      })
      .catch((error) => sendRealtimeErrorResponse(id, sendResponse, error, logger, logPrefix));
  }

  function handleSessionClose(parsed, sendResponse) {
    const id = parsed.id;
    const state = readSession(sessions, parsed.params?.sessionId);
    Promise.resolve()
      .then(() => {
        if (!state) {
          throw voiceError("invalid_realtime_session", "The Live Voice session is no longer available.");
        }
        const requestedThreadId = readString(parsed.params?.threadId);
        if (requestedThreadId && requestedThreadId !== state.threadId) {
          throw voiceError("invalid_realtime_scope", "Voice needs an active conversation before it can continue.");
        }
        if (!state.closed && !state.closeRequested) {
          if (!requestLiveSessionClose(state)) {
            throw voiceError("invalid_realtime_session", "The Live Voice session is no longer available.");
          }
        }
        return { ok: true };
      })
      .then((result) => {
        if (id != null) {
          sendResponse(JSON.stringify({ id, result }));
        }
      })
      .catch((error) => sendRealtimeErrorResponse(id, sendResponse, error, logger, logPrefix));
  }

  async function openLiveSession({
    threadId,
    apiKey: normalizedApiKey,
    now: clock,
    sessionTimeoutMs: timeoutMs,
    closeFinalizationTimeoutMs: finalizationTimeoutMs,
    idleTimeoutMs: idleTimeout,
    setTimeoutImpl: setTimer,
    clearTimeoutImpl: clearTimer,
  }) {
    if (typeof WebSocketImpl !== "function") {
      throw voiceError("realtime_unavailable", "Live Voice is unavailable right now.");
    }

    const sessionId = `live-${randomUUID()}`;
    const safetyIdentifier = createRealtimeSafetyIdentifier(threadId);
    let socket;
    try {
      socket = instantiateLiveSocket(WebSocketImpl, normalizedApiKey, safetyIdentifier);
    } catch {
      throw voiceError("realtime_unavailable", "Live Voice is unavailable right now.");
    }

    const state = {
      sessionId,
      threadId,
      socket,
      inputTranscriptSegments: [],
      inputTranscriptEventIds: new Set(),
      lastDelegationOffsetMs: 0,
      delegations: new Set(),
      pendingDelegations: new Map(),
      started: false,
      startSent: false,
      closed: false,
      closeRequested: false,
      expiresAt: null,
      startTimer: null,
      closeTimer: null,
      expiryTimer: null,
      idleTimer: null,
      closeFinalizationTimeoutMs: finalizationTimeoutMs,
      idleTimeoutMs: idleTimeout,
      setTimeoutImpl: setTimer,
      clearTimeoutImpl: clearTimer,
      startedResolve: null,
      startedReject: null,
    };
    sessions.set(sessionId, state);

    const startedPromise = new Promise((resolve, reject) => {
      state.startedResolve = resolve;
      state.startedReject = reject;
      const timeout = Number.isFinite(timeoutMs) ? Math.max(0, Number(timeoutMs)) : LIVE_START_TIMEOUT_MS;
      state.startTimer = setTimer(() => {
        if (!state.started) {
          reject(voiceError("realtime_timeout", "Live Voice took too long to start."));
          closeLiveSocket(state);
        }
      }, timeout);
      state.startTimer?.unref?.();
    });

    addLiveSocketListener(socket, "open", () => sendSessionStart(state));
    addLiveSocketListener(socket, "message", (message) => handleLiveSocketMessage(state, message));
    addLiveSocketListener(socket, "error", () => {
      if (!state.started) {
        state.startedReject?.(voiceError("realtime_unavailable", "Live Voice is unavailable right now."));
      }
      terminateLiveSession(state);
      logRealtimeEvent(logger, "error", logPrefix, "provider error", { session: "live" });
    });
    addLiveSocketListener(socket, "close", () => {
      if (!state.started) {
        state.startedReject?.(voiceError("realtime_unavailable", "Live Voice is unavailable right now."));
      }
      terminateLiveSession(state, { closeSocket: false });
    });

    // Some injected transports are already open synchronously; ws normally
    // emits `open` on a later turn.
    if (isLiveSocketOpen(socket, WebSocketImpl)) {
      sendSessionStart(state);
    }

    const startedEvent = await startedPromise.catch((error) => {
      terminateLiveSession(state);
      throw error;
    });
    if (state.startTimer) {
      clearTimer(state.startTimer);
      state.startTimer = null;
    }
    const providerExpiry = Number(startedEvent?.session?.expires_at ?? startedEvent?.expires_at);
    if (Number.isFinite(providerExpiry) && !isPlausibleFutureRealtimeExpiry(providerExpiry, clock)) {
      terminateLiveSession(state);
      throw voiceError("realtime_invalid_response", "The Live Voice session could not be started.");
    }
    state.expiresAt = Number.isFinite(providerExpiry)
      ? providerExpiry
      : Math.floor(Number(clock()) / 1_000) + Math.floor(LIVE_SESSION_TTL_MS / 1_000);
    scheduleLiveSessionExpiry(state, clock);
    touchLiveSession(state);

    logRealtimeEvent(logger, "log", logPrefix, "session started", {
      model: DEFAULT_LIVE_MODEL,
      source: "bridge",
    });
    return {
      sessionId,
      model: DEFAULT_LIVE_MODEL,
      transport: "bridge",
      expiresAt: state.expiresAt,
    };
  }

  function sendSessionStart(state) {
    if (state.closed || state.started || state.startSent) {
      return;
    }
    state.startSent = true;
    try {
      sendLiveSocketEvent(state, {
        type: "session.start",
        event_id: randomUUID(),
        session: {
          model: DEFAULT_LIVE_MODEL,
          instructions: "You are the live voice interface for the user's local Codex task. Keep spoken replies concise and delegate task execution to the paired Mac bridge.",
          audio: {
            format: { ...DEFAULT_LIVE_AUDIO_FORMAT },
            output: { voice: DEFAULT_LIVE_VOICE },
          },
          delegation: { type: "client" },
        },
      });
    } catch (error) {
      state.startedReject?.(voiceError("realtime_unavailable", "Live Voice is unavailable right now."));
      closeLiveSocket(state);
    }
  }

  function handleLiveSocketMessage(state, rawMessage) {
    const event = parseLiveSocketMessage(rawMessage);
    if (!event || state.closed) {
      return;
    }
    if (event.type !== "session.closed") {
      touchLiveSession(state);
    }
    if (event.type === "session.started") {
      state.started = true;
      state.startedResolve?.(event);
    }
    if (event.type === "session.input_transcript.delta") {
      recordLiveInputTranscript(state, event);
    }
    if (event.type === "session.delegation.created") {
      queueLiveDelegation(state, event);
    }
    sendLiveApplicationEvent(sendApplicationResponse, state.sessionId, event);
    if (event.type === "session.closed") {
      terminateLiveSession(state);
    } else if (event.type === "error") {
      terminateLiveSession(state);
    }
  }

  function recordLiveInputTranscript(state, event) {
    const text = readString(event.delta || event.text || event.transcript);
    const startMs = Number(event.start_ms);
    const endMs = Number(event.end_ms);
    if (!text || !Number.isFinite(startMs) || !Number.isFinite(endMs) || endMs < startMs) {
      return;
    }

    const eventId = readString(event.event_id) || `${startMs}:${endMs}:${text}`;
    if (state.inputTranscriptEventIds.has(eventId)) {
      return;
    }
    state.inputTranscriptEventIds.add(eventId);
    state.inputTranscriptSegments.push({ startMs, endMs, text });
    state.inputTranscriptSegments.sort((left, right) => left.startMs - right.startMs || left.endMs - right.endMs);

    for (const pending of state.pendingDelegations.values()) {
      if (liveDelegationHasTranscript(state, pending)) {
        scheduleLiveDelegationRun(state, pending);
      }
    }
  }

  function queueLiveDelegation(state, event) {
    if (state.closed || state.closeRequested) {
      return;
    }
    const delegation = event.delegation;
    const delegationId = readString(delegation?.id || delegation?.delegation_id);
    if (!delegationId || readString(delegation?.target).toLowerCase() !== "client" || state.delegations.has(delegationId)) {
      return;
    }
    state.delegations.add(delegationId);

    const offsetMs = Number(event.offset_ms);
    if (!Number.isFinite(offsetMs) || offsetMs < state.lastDelegationOffsetMs) {
      return;
    }
    const pending = {
      delegationId,
      startOffsetMs: state.lastDelegationOffsetMs,
      endOffsetMs: offsetMs,
      settleTimer: null,
      timeoutTimer: null,
      started: false,
    };
    state.lastDelegationOffsetMs = offsetMs;
    state.pendingDelegations.set(delegationId, pending);
    pending.timeoutTimer = state.setTimeoutImpl(() => {
      pending.timeoutTimer = null;
      if (pending.started || state.closed || state.closeRequested) {
        return;
      }
      state.pendingDelegations.delete(delegationId);
      try {
        sendLiveSocketEvent(state, {
          type: "session.commentary.append",
          event_id: randomUUID(),
          delegation_id: delegationId,
          content: "I didn't receive a voice request to send to Codex, so I didn't start a task.",
        });
      } catch {
        // A transcript timeout should not affect live-session cleanup.
      }
    }, LIVE_DELEGATION_TRANSCRIPT_TIMEOUT_MS);
    pending.timeoutTimer?.unref?.();
    scheduleLiveDelegationRun(state, pending);
  }

  function liveDelegationHasTranscript(state, pending) {
    return state.inputTranscriptSegments.some((segment) => (
      segment.endMs > pending.startOffsetMs
      && segment.endMs <= pending.endOffsetMs
      && segment.startMs < pending.endOffsetMs
    ));
  }

  function scheduleLiveDelegationRun(state, pending) {
    if (pending.started || !liveDelegationHasTranscript(state, pending)) {
      return;
    }
    if (pending.settleTimer) {
      state.clearTimeoutImpl(pending.settleTimer);
      pending.settleTimer = null;
    }
    pending.settleTimer = state.setTimeoutImpl(() => {
      pending.settleTimer = null;
      runLiveDelegation(state, pending).catch(() => {});
    }, LIVE_DELEGATION_TRANSCRIPT_SETTLE_MS);
    pending.settleTimer?.unref?.();
  }

  async function runLiveDelegation(state, pending) {
    if (state.closed || state.closeRequested || pending.started) {
      return;
    }
    const transcript = state.inputTranscriptSegments
      .filter((segment) => (
        segment.endMs > pending.startOffsetMs
        && segment.endMs <= pending.endOffsetMs
        && segment.startMs < pending.endOffsetMs
      ))
      .map((segment) => segment.text)
      .join("")
      .trim();
    if (!transcript) {
      return;
    }
    pending.started = true;
    state.pendingDelegations.delete(pending.delegationId);
    if (pending.timeoutTimer) {
      state.clearTimeoutImpl(pending.timeoutTimer);
      pending.timeoutTimer = null;
    }

    const context = {
      threadId: state.threadId,
      sessionId: state.sessionId,
      delegationId: pending.delegationId,
      transcript,
    };
    let result;
    try {
      result = typeof runDelegatedTask === "function"
        ? await runDelegatedTask(context)
        : await runDefaultLiveDelegation(context);
    } catch {
      result = "I couldn't complete that Codex request on the Mac.";
    }
    if (state.closed || state.closeRequested) {
      return;
    }
    sendLiveSocketEvent(state, {
      type: "session.commentary.append",
      event_id: randomUUID(),
      delegation_id: pending.delegationId,
      content: truncateLiveCommentary(result),
    });
  }

  async function runDefaultLiveDelegation({ threadId, transcript }) {
    if (typeof sendCodexRequest !== "function") {
      return "Codex is unavailable on this Mac right now.";
    }
    const text = readString(transcript);
    if (!text) {
      return "I didn't catch a voice request to send to Codex.";
    }
    try {
      await sendCodexRequest("turn/start", {
        threadId,
        input: [{ type: "text", text }],
      });
      return "Codex started the requested task on the Mac.";
    } catch {
      return "Codex could not start the requested task on the Mac.";
    }
  }

function touchLiveSession(state) {
    if (!state || state.closed || state.closeRequested) {
      return;
    }
    if (state.idleTimer) {
      state.clearTimeoutImpl(state.idleTimer);
      state.idleTimer = null;
    }
    const timeout = Number(state.idleTimeoutMs);
    if (!Number.isFinite(timeout) || timeout <= 0) {
      return;
    }
    scheduleBoundedLiveTimer(state, "idleTimer", timeout, () => {
      requestLiveSessionClose(state);
    });
  }

  function scheduleLiveSessionExpiry(state, clock) {
    const expiresAtMs = Number(state.expiresAt) * 1_000;
    const nowMs = Number(clock());
    if (!Number.isFinite(expiresAtMs) || !Number.isFinite(nowMs)) {
      return;
    }
    const delay = Math.max(0, expiresAtMs - nowMs);
    scheduleBoundedLiveTimer(state, "expiryTimer", delay, () => {
      requestLiveSessionClose(state);
    });
  }

  function requestLiveSessionClose(state) {
    if (!state || state.closed || state.closeRequested) {
      return;
    }
    // Mark the session as closing before writing the provider event so a
    // synchronous provider callback cannot race another close/audio operation
    // into the live socket. Idle/expiry cleanup uses this same graceful path.
    state.closeRequested = true;
    try {
      sendLiveSocketEvent(state, { type: "session.close" });
    } catch (error) {
      terminateLiveSession(state);
      return false;
    }
    scheduleLiveCloseFinalization(state);
    return true;
  }

  function scheduleLiveCloseFinalization(state) {
    if (!state || state.closed) {
      return;
    }
    if (state.closeTimer) {
      state.clearTimeoutImpl(state.closeTimer);
      state.closeTimer = null;
    }
    const timeout = Number(state.closeFinalizationTimeoutMs);
    if (!Number.isFinite(timeout) || timeout <= 0) {
      terminateLiveSession(state);
      return;
    }
    scheduleBoundedLiveTimer(state, "closeTimer", timeout, () => {
      terminateLiveSession(state);
    });
  }

  function terminateLiveSession(state, { closeSocket = true } = {}) {
    if (!state) {
      return;
    }
    state.closed = true;
    sessions.delete(state.sessionId);
    if (state.startTimer) {
      state.clearTimeoutImpl(state.startTimer);
      state.startTimer = null;
    }
    if (state.closeTimer) {
      state.clearTimeoutImpl(state.closeTimer);
      state.closeTimer = null;
    }
    if (state.expiryTimer) {
      state.clearTimeoutImpl(state.expiryTimer);
      state.expiryTimer = null;
    }
    if (state.idleTimer) {
      state.clearTimeoutImpl(state.idleTimer);
      state.idleTimer = null;
    }
    clearPendingLiveDelegations(state);
    if (closeSocket) {
      closeLiveSocket(state);
    }
  }

  function clearPendingLiveDelegations(state) {
    for (const pending of state.pendingDelegations.values()) {
      if (pending.settleTimer) {
        state.clearTimeoutImpl(pending.settleTimer);
      }
      if (pending.timeoutTimer) {
        state.clearTimeoutImpl(pending.timeoutTimer);
      }
    }
    state.pendingDelegations.clear();
  }

  function scheduleBoundedLiveTimer(state, timerKey, delayMs, callback) {
    const delay = Math.max(0, Number(delayMs) || 0);
    const slice = Math.min(delay, MAX_TIMER_DELAY_MS);
    state[timerKey] = state.setTimeoutImpl(() => {
      if (delay > slice && !state.closed) {
        scheduleBoundedLiveTimer(state, timerKey, delay - slice, callback);
        return;
      }
      state[timerKey] = null;
      callback();
    }, slice);
    state[timerKey]?.unref?.();
  }

  return { handleRealtimeSessionRequest };
}

async function verifyRealtimeThread(sendCodexRequest, threadId) {
  if (typeof sendCodexRequest !== "function") {
    throw voiceError("realtime_thread_validation_unavailable", "Live Voice could not verify this conversation.");
  }

  let response;
  try {
    response = await sendCodexRequest("thread/read", {
      threadId,
      includeTurns: false,
    });
  } catch {
    throw voiceError("realtime_thread_validation_unavailable", "Live Voice could not verify this conversation.");
  }

  const thread = response?.thread;
  const returnedThreadId = readString(thread?.id || thread?.threadId || thread?.thread_id);
  if (!thread || returnedThreadId !== threadId || isInactiveRealtimeThread(thread)) {
    throw voiceError("invalid_realtime_scope", "Voice needs an active conversation before it can start.");
  }
}

function isInactiveRealtimeThread(thread) {
  if (thread.archived === true) {
    return true;
  }

  const status = readString(thread?.status?.type || thread?.status);
  return ["archived", "inactive", "deleted"].includes(status?.toLowerCase());
}

function isPlausibleFutureRealtimeExpiry(expiresAt, now) {
  if (!Number.isFinite(expiresAt)) {
    return false;
  }

  const nowSeconds = Number(now()) / 1_000;
  return Number.isFinite(nowSeconds) && expiresAt > nowSeconds;
}

function createRealtimeSafetyIdentifier(threadId) {
  return `remodex-${createHash("sha256").update(threadId).digest("hex")}`;
}

function instantiateLiveSocket(WebSocketImpl, apiKey, safetyIdentifier) {
  const options = {
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "OpenAI-Safety-Identifier": safetyIdentifier,
    },
  };
  try {
    return new WebSocketImpl(OPENAI_LIVE_WEBSOCKET_URL, options);
  } catch (error) {
    // A tiny function-based fake is useful in unit tests; support it without
    // weakening the production ws constructor path.
    if (/not a constructor|is not a constructor/i.test(String(error?.message || ""))) {
      return WebSocketImpl(OPENAI_LIVE_WEBSOCKET_URL, options);
    }
    throw error;
  }
}

function addLiveSocketListener(socket, eventName, listener) {
  if (typeof socket?.on === "function") {
    socket.on(eventName, listener);
  } else if (typeof socket?.addEventListener === "function") {
    socket.addEventListener(eventName, listener);
  } else if (socket) {
    socket[`on${eventName}`] = listener;
  }
}

function isLiveSocketOpen(socket, WebSocketImpl) {
  const openValue = Number(WebSocketImpl?.OPEN ?? 1);
  return socket?.readyState === openValue;
}

function sendLiveSocketEvent(state, event) {
  if (!state?.socket || state.closed || typeof state.socket.send !== "function") {
    throw voiceError("invalid_realtime_session", "The Live Voice session is no longer available.");
  }
  const payload = JSON.stringify(event);
  if (Buffer.byteLength(payload, "utf8") > MAX_LIVE_EVENT_BYTES) {
    throw voiceError("realtime_event_too_large", "The Live Voice event was too large.");
  }
  state.socket.send(payload);
}

function closeLiveSocket(state) {
  if (!state) {
    return;
  }
  state.closed = true;
  if (state.startTimer) {
    clearLiveTimer(state, state.startTimer);
    state.startTimer = null;
  }
  if (state.closeTimer) {
    clearLiveTimer(state, state.closeTimer);
    state.closeTimer = null;
  }
  if (state.expiryTimer) {
    clearLiveTimer(state, state.expiryTimer);
    state.expiryTimer = null;
  }
  if (state.idleTimer) {
    clearLiveTimer(state, state.idleTimer);
    state.idleTimer = null;
  }
  if (state.pendingDelegations instanceof Map) {
    for (const pending of state.pendingDelegations.values()) {
      clearLiveTimer(state, pending.settleTimer);
      clearLiveTimer(state, pending.timeoutTimer);
    }
    state.pendingDelegations.clear();
  }
  try {
    const closedState = Number(state.socket?.CLOSED ?? 3);
    if (state.socket && state.socket.readyState !== closedState) {
      state.socket.close?.();
    }
  } catch {
    // Cleanup must remain best-effort and opaque.
  }
}

function clearLiveTimer(state, timer) {
  if (typeof state?.clearTimeoutImpl === "function") {
    state.clearTimeoutImpl(timer);
  } else {
    clearTimeout(timer);
  }
}

function readSession(sessions, sessionId) {
  const normalized = readString(sessionId);
  return normalized ? sessions.get(normalized) || null : null;
}

function parseLiveSocketMessage(rawMessage) {
  const value = rawMessage && typeof rawMessage === "object" && "data" in rawMessage
    ? rawMessage.data
    : rawMessage;
  try {
    return JSON.parse(Buffer.isBuffer(value) ? value.toString("utf8") : String(value));
  } catch {
    return null;
  }
}

function decodeLiveAudioBase64(value) {
  if (!value || typeof value !== "string" || value.length % 4 === 1 || !/^[A-Za-z0-9+/]*={0,2}$/.test(value)) {
    return null;
  }
  try {
    const buffer = Buffer.from(value, "base64");
    // Buffer.from is permissive; reject non-canonical encodings so malformed
    // input cannot be smuggled into the provider event stream.
    if (buffer.length === 0 || buffer.toString("base64").replace(/=+$/, "") !== value.replace(/=+$/, "")) {
      return null;
    }
    return buffer;
  } catch {
    return null;
  }
}

const ALLOWED_LIVE_CLIENT_EVENTS = new Set([
  "session.input_audio.mute",
  "session.input_audio.unmute",
]);

function isAllowedLiveClientEvent(event) {
  const type = readString(event?.type);
  if (!ALLOWED_LIVE_CLIENT_EVENTS.has(type)) {
    return false;
  }
  return JSON.stringify(event).length <= MAX_LIVE_EVENT_BYTES;
}

function sendLiveApplicationEvent(sendApplicationResponse, sessionId, event) {
  if (typeof sendApplicationResponse !== "function") {
    return;
  }
  try {
    sendApplicationResponse(JSON.stringify({
      method: "voice/realtime/event",
      params: { sessionId, event },
    }));
  } catch {
    // A disconnected phone should not tear down the provider session.
  }
}

function truncateLiveCommentary(value) {
  const text = typeof value === "string"
    ? value
    : readString(value?.content || value?.summary || value?.text);
  const normalized = text || "Codex handled the delegated request on the Mac.";
  // GPT-Live limits commentary content to 500 tokens. Four characters per
  // token is conservative for ordinary English and keeps the wire payload
  // comfortably below that limit.
  return normalized.length <= 2_000 ? normalized : `${normalized.slice(0, 1_997)}...`;
}

function sendRealtimeErrorResponse(id, sendResponse, error, logger, logPrefix) {
  logRealtimeEvent(logger, "error", logPrefix, "session request failed", {
    errorCode: error?.errorCode || "realtime_session_failed",
  });
  if (id != null) {
    sendResponse(JSON.stringify({
      id,
      error: {
        code: -32000,
        message: error?.userMessage || "Live Voice could not be started.",
        data: voiceErrorData(error),
      },
    }));
  }
}

function parseJsonMessage(rawMessage) {
  try {
    return JSON.parse(rawMessage);
  } catch {
    return null;
  }
}

// ─── Audio validation helpers ───────────────────────────────

// Validates iPhone-owned audio input and proxies it to the official transcription endpoint.
async function transcribeVoice(
  params,
  {
    sendCodexRequest,
    fetchImpl,
    FormDataImpl,
    BlobImpl,
    logger = console,
    logPrefix = "[remodex]",
    transcriptionTimeoutMs = DEFAULT_TRANSCRIPTION_TIMEOUT_MS,
    loadAuth = () => loadAuthContext(sendCodexRequest, { refreshToken: false }),
    refreshAuth = () => loadAuthContext(sendCodexRequest, { refreshToken: true }),
  }
) {
  if (typeof sendCodexRequest !== "function") {
    throw voiceError("bridge_not_ready", "Voice transcription is not available right now.");
  }
  if (typeof fetchImpl !== "function" || !FormDataImpl || !BlobImpl) {
    throw voiceError("transcription_unavailable", "Voice transcription is unavailable on this bridge.");
  }

  const mimeType = readString(params.mimeType);
  if (!isSupportedVoiceMimeType(mimeType)) {
    throw voiceError("unsupported_mime_type", "Only WAV or M4A audio is supported for voice transcription.");
  }

  const sampleRateHz = readPositiveNumber(params.sampleRateHz);
  if (sampleRateHz !== 24_000) {
    throw voiceError("unsupported_sample_rate", "Voice transcription requires 24 kHz mono WAV audio.");
  }

  const durationMs = readPositiveNumber(params.durationMs);
  if (durationMs <= 0) {
    throw voiceError("invalid_duration", "Voice messages must include a positive duration.");
  }
  if (durationMs > MAX_DURATION_MS) {
    throw voiceError("duration_too_long", `Voice messages are limited to ${MAX_DURATION_SECONDS} seconds.`);
  }

  const audioBuffer = decodeAudioBase64(params.audioBase64);
  if (audioBuffer.length > MAX_AUDIO_BYTES) {
    throw voiceError("audio_too_large", "Voice messages are limited to 10 MB.");
  }
  const audioInfo = readVoiceAudioInfo(audioBuffer, mimeType);
  const actualDurationMs = audioInfo.durationMs;
  if (!Number.isFinite(actualDurationMs) || actualDurationMs <= 0) {
    throw voiceError("invalid_audio", "The recorded audio is not a valid audio file.");
  }
  if (actualDurationMs > MAX_DURATION_MS) {
    throw voiceError("duration_too_long", `Voice messages are limited to ${MAX_DURATION_SECONDS} seconds.`);
  }
  if (actualDurationMs > durationMs + MAX_DURATION_DRIFT_MS) {
    throw voiceError("duration_mismatch", "The recorded audio duration did not match the voice request.");
  }

  logVoiceEvent(logger, "log", logPrefix, "request received", {
    durationMs,
    actualDurationMs: Math.round(actualDurationMs),
    audioBytes: audioBuffer.length,
  });

  const authContext = await loadAuth();
  return requestTranscription({
    authContext,
    audioBuffer,
    mimeType,
    filename: audioInfo.filename,
    fetchImpl,
    FormDataImpl,
    BlobImpl,
    refreshAuth,
    logger,
    logPrefix,
    transcriptionTimeoutMs,
  });
}

// Posts the validated clip to the active transcription provider and logs only safe metadata.
async function requestTranscription({
  authContext,
  audioBuffer,
  mimeType,
  filename = "voice.wav",
  fetchImpl,
  FormDataImpl,
  BlobImpl,
  refreshAuth,
  logger = console,
  logPrefix = "[remodex]",
  transcriptionTimeoutMs = DEFAULT_TRANSCRIPTION_TIMEOUT_MS,
}) {
  const makeAttempt = async (activeAuthContext, attempt) => {
    logVoiceEvent(logger, "log", logPrefix, "auth selected", {
      attempt,
      source: activeAuthContext.authSource,
      method: activeAuthContext.authMethodClass,
      provider: activeAuthContext.provider,
    });

    const formData = new FormDataImpl();
    formData.append("file", new BlobImpl([audioBuffer], { type: mimeType }), filename);

    const headers = {
      Authorization: `Bearer ${activeAuthContext.token}`,
      "User-Agent": VOICE_UPLOAD_USER_AGENT,
    };

    const timeoutMs = Number.isFinite(transcriptionTimeoutMs)
      ? Math.max(0, Math.floor(transcriptionTimeoutMs))
      : DEFAULT_TRANSCRIPTION_TIMEOUT_MS;
    const controller = typeof AbortController === "function" && timeoutMs > 0
      ? new AbortController()
      : null;
    const timeoutID = controller
      ? setTimeout(() => {
        controller.abort(createTranscriptionTimeoutError(timeoutMs));
      }, timeoutMs)
      : null;
    timeoutID?.unref?.();

    let response;
    try {
      response = await fetchImpl(activeAuthContext.transcriptionURL, {
        method: "POST",
        headers,
        body: formData,
        signal: controller?.signal,
      });
    } catch (error) {
      if (isAbortError(error, controller)) {
        logVoiceEvent(logger, "warn", logPrefix, "provider status", {
          attempt,
          provider: activeAuthContext.provider,
          status: "timeout",
          ok: false,
        });
        throw voiceError(
          "transcription_timeout",
          "Voice transcription timed out. Try a shorter clip or retry when the connection is stable.",
          { provider: activeAuthContext.provider }
        );
      }

      logVoiceEvent(logger, "warn", logPrefix, "provider status", {
        attempt,
        provider: activeAuthContext.provider,
        status: "network_error",
        ok: false,
      });
      throw voiceError(
        "transcription_network_error",
        "Voice transcription could not reach the provider.",
        { provider: activeAuthContext.provider }
      );
    } finally {
      if (timeoutID) {
        clearTimeout(timeoutID);
      }
    }

    logVoiceEvent(logger, response.ok ? "log" : "warn", logPrefix, "provider status", {
      attempt,
      provider: activeAuthContext.provider,
      status: response.status,
      ok: Boolean(response.ok),
    });
    return response;
  };

  let activeAuthContext = authContext;
  let attempt = 1;
  let response = await makeAttempt(activeAuthContext, attempt);
  if (response.status === 401 || response.status === 403) {
    // First attempt runs on a cached/non-refreshed token, so force a refresh here.
    activeAuthContext = await refreshAuth();
    attempt += 1;
    response = await makeAttempt(activeAuthContext, attempt);
  }

  if (!response.ok) {
    if (response.status === 401 || response.status === 403) {
      throw voiceError(
        "auth_rejected",
        "Your ChatGPT login has expired. Sign in again.",
        { provider: activeAuthContext.provider }
      );
    }

    throw voiceError(
      "transcription_failed",
      `Voice transcription failed with provider status ${response.status}.`,
      { provider: activeAuthContext.provider, status: response.status }
    );
  }

  const payload = await response.json().catch(() => null);
  const text = readString(payload?.text) || readString(payload?.transcript);
  if (!text) {
    throw voiceError("transcription_invalid_response", "The transcription response did not include any text.");
  }

  logVoiceEvent(logger, "log", logPrefix, "success", {
    provider: activeAuthContext.provider,
    status: response.status,
    textLength: text.length,
  });

  return { text };
}

// Reads the current bridge-owned ChatGPT auth state; refresh is reserved for 401/403 retries.
async function loadAuthContext(sendCodexRequest, { refreshToken = false } = {}) {
  const authStatus = await readVoiceAuthStatus(sendCodexRequest, { refreshToken });

  const authMethod = readString(authStatus?.authMethod);
  const token = normalizeBearerToken(authStatus?.authToken);
  const isChatGPT = isChatGPTAuthMethod(authMethod);

  if (!token) {
    throw voiceError("not_authenticated", "Sign in with ChatGPT before using voice transcription.");
  }

  if (!isChatGPT) {
    throw voiceError("not_chatgpt", "Voice transcription requires a ChatGPT account.");
  }

  return {
    authMethod,
    authSource: "mac_runtime",
    authMethodClass: "chatgpt",
    provider: "chatgpt",
    token,
    transcriptionURL: CHATGPT_TRANSCRIPTIONS_URL,
  };
}

async function readVoiceAuthStatus(sendCodexRequest, { refreshToken = true } = {}) {
  try {
    return await sendCodexRequest("getAuthStatus", {
      includeToken: true,
      refreshToken,
    });
  } catch {
    console.error("[remodex] voice auth: getAuthStatus RPC failed");
    throw voiceError("auth_unavailable", "Could not read ChatGPT auth from the Mac runtime. Is the bridge running?");
  }
}

function decodeAudioBase64(value) {
  const normalized = normalizeBase64(value);
  if (!normalized) {
    throw voiceError("missing_audio", "The voice request did not include any audio.");
  }

  const audioBuffer = Buffer.from(normalized, "base64");
  if (!audioBuffer.length) {
    throw voiceError("invalid_audio", "The recorded audio could not be decoded.");
  }

  if (audioBuffer.toString("base64") !== normalized) {
    throw voiceError("invalid_audio", "The recorded audio could not be decoded.");
  }

  return audioBuffer;
}

// Keeps the bridge strict about the payload shape so malformed uploads fail before fetch().
function normalizeBase64(value) {
  return typeof value === "string" ? value.replace(/\s+/g, "").trim() : "";
}

function isSupportedVoiceMimeType(mimeType) {
  return mimeType === VOICE_WAV_MIME_TYPE || mimeType === VOICE_M4A_MIME_TYPE;
}

function readVoiceAudioInfo(buffer, mimeType) {
  if (mimeType === VOICE_WAV_MIME_TYPE) {
    const wavInfo = readWavInfo(buffer);
    if (!wavInfo) {
      throw voiceError("invalid_audio", "The recorded audio is not a valid WAV file.");
    }
    if (!isSupportedVoiceWavFormat(wavInfo)) {
      throw voiceError("unsupported_sample_rate", "Voice transcription requires 24 kHz mono WAV audio.");
    }
    if (!hasConsistentVoiceWavLayout(wavInfo)) {
      throw voiceError("invalid_audio", "The recorded audio is not a valid WAV file.");
    }
    return {
      durationMs: wavDurationMs(wavInfo),
      filename: "voice.wav",
    };
  }

  const m4aInfo = readM4AInfo(buffer);
  if (!m4aInfo) {
    throw voiceError("invalid_audio", "The recorded audio is not a valid M4A file.");
  }
  return {
    durationMs: m4aInfo.durationMs,
    filename: "voice.m4a",
  };
}

function readString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function normalizeBearerToken(value) {
  const token = readString(value);
  if (!token) {
    return null;
  }
  const match = token.match(/^bearer\s+(.+)$/i);
  return match ? match[1].trim() : token;
}

function isChatGPTAuthMethod(value) {
  const normalized = readString(value)?.toLowerCase().replace(/[^a-z0-9]/g, "") || "";
  return normalized.includes("chatgpt");
}

// Formats fixed safe fields only; callers must pass classifications, counts, and statuses.
function logVoiceEvent(logger, level, logPrefix, event, fields = {}) {
  logSafeVoiceEvent(logger, level, logPrefix, "transcribe", event, fields);
}

function logRealtimeEvent(logger, level, logPrefix, event, fields = {}) {
  logSafeVoiceEvent(logger, level, logPrefix, "realtime", event, fields);
}

function logSafeVoiceEvent(logger, level, logPrefix, category, event, fields = {}) {
  const writer = resolveLogWriter(logger, level);
  const details = Object.entries(fields)
    .map(([key, value]) => `${key}=${formatLogValue(value)}`)
    .join(" ");
  writer(`${logPrefix} voice ${category} ${event}${details ? ` ${details}` : ""}`);
}

function resolveLogWriter(logger, level) {
  if (typeof logger?.[level] === "function") {
    return logger[level].bind(logger);
  }
  if (level === "warn" && typeof logger?.log === "function") {
    return logger.log.bind(logger);
  }
  if (level === "error" && typeof logger?.warn === "function") {
    return logger.warn.bind(logger);
  }
  if (typeof console[level] === "function") {
    return console[level].bind(console);
  }
  return console.log.bind(console);
}

function formatLogValue(value) {
  if (typeof value === "number" && Number.isFinite(value)) {
    return String(value);
  }
  if (typeof value === "boolean") {
    return value ? "true" : "false";
  }
  return String(value).replace(/[^a-zA-Z0-9_.:-]/g, "_");
}

function readPositiveNumber(value) {
  const numericValue = typeof value === "number" ? value : Number(value);
  return Number.isFinite(numericValue) && numericValue >= 0 ? numericValue : 0;
}

function createTranscriptionTimeoutError(timeoutMs) {
  const error = new Error(`Voice transcription timed out after ${timeoutMs}ms`);
  error.name = "AbortError";
  error.code = "voice_transcription_timeout";
  return error;
}

function isAbortError(error, controller) {
  return Boolean(controller?.signal?.aborted)
    || error?.name === "AbortError"
    || error?.code === "ABORT_ERR"
    || error?.code === "voice_transcription_timeout";
}

function voiceErrorData(error) {
  const data = {
    errorCode: error.errorCode || "voice_transcription_failed",
  };
  if (error.provider === "chatgpt") {
    data.provider = error.provider;
  }
  if (Number.isInteger(error.status)) {
    data.status = error.status;
  }
  return data;
}

function voiceError(errorCode, userMessage, details = {}) {
  const error = new Error(userMessage);
  error.errorCode = errorCode;
  error.userMessage = userMessage;
  if (details.provider === "chatgpt") {
    error.provider = details.provider;
  }
  if (Number.isInteger(details.status)) {
    error.status = details.status;
  }
  return error;
}

// Serves older phone builds that upload directly to ChatGPT with a Mac-owned token.
async function resolveVoiceAuth(sendCodexRequest) {
  if (typeof sendCodexRequest !== "function") {
    throw voiceError("bridge_not_ready", "Voice transcription is not available right now.");
  }

  const authStatus = await readVoiceAuthStatus(sendCodexRequest);
  const authMethod = readString(authStatus?.authMethod);
  const token = normalizeBearerToken(authStatus?.authToken);
  const isChatGPT = isChatGPTAuthMethod(authMethod);

  if (isChatGPT && token) {
    return { token };
  }

  if (!token) {
    throw voiceError("token_missing", "No ChatGPT session token available. Sign in to ChatGPT on the Mac.");
  }

  throw voiceError("not_chatgpt", "Voice transcription requires a ChatGPT account.");
}

module.exports = {
  OPENAI_KEYCHAIN_ACCOUNT,
  OPENAI_KEYCHAIN_SERVICE,
  OPENAI_LIVE_WEBSOCKET_URL,
  DEFAULT_LIVE_MODEL,
  createRealtimeSessionHandler,
  createVoiceHandler,
  resolveOpenAIAPIKey,
  resolveVoiceAuth,
};
