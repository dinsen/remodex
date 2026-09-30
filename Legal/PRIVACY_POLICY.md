# Remodex — Data Protection Notice

**Last updated:** September 30, 2026

This Data Protection Notice explains how the Remodex mobile application ("App"), developed by Emanuele Di Pietro ("Developer", "we", "us", or "our"), handles your information. Remodex is designed to let you control a Codex runtime on your Mac from your iPhone. Conversation and workspace activity is processed on your paired Mac. Depending on your network setup, your iPhone may connect to your Mac directly or through a relay endpoint configured for your installation.

---

## 1. Overview

Remodex is a local-first remote companion for Codex on your Mac. In practice, this means:

- Your conversations, repository actions, and workspace interactions are primarily processed on your paired Mac.
- We do not operate user accounts or cloud databases.
- We do not run analytics, advertising, or cross-app tracking.
- We do not sell your personal information.
- After the secure session is established, message contents sent between your iPhone and Mac are end-to-end encrypted.
- If your setup uses a relay, it routes traffic between your iPhone and paired Mac; after the secure transport handshake, application payloads remain end-to-end encrypted.

## 2. Information We Collect

### 2.1 Information You Provide Through the App

- **Chat messages and prompts** — Your messages are sent from the iPhone to your paired Mac for processing. After the secure transport handshake is complete, the relay forwards encrypted payloads and cannot read message contents.
- **Photo attachments** — Images you attach from the camera or photo library are sent to your paired Mac over the secure channel.
- **Voice notes** — When you use voice notes, the App records a temporary WAV file on your iPhone and uploads that audio directly from the iPhone to OpenAI/ChatGPT for transcription. The request is authenticated with a ChatGPT token resolved from your paired Mac over the encrypted Remodex channel.
- **Live Voice audio and replies** — When you use Live Voice in a Codex conversation, microphone audio is streamed through your paired Mac to OpenAI's realtime voice service. For a spoken reply, Remodex sends OpenAI only the completed final answer from the matching Codex turn. It excludes Codex reasoning, commentary, and tool output from that reply path.
- **Git operations** — Commands you initiate from the App, such as commit, pull, push, branch, or status actions, are executed on your paired Mac.

### 2.2 Information Collected Automatically

- **Pairing and identity keys** — The App generates cryptographic identity material used for secure pairing and trusted reconnect.
- **Pairing and reconnect metadata** — The App stores trusted Mac identifiers and connection/session metadata needed to restore a secure connection.
- **Connection metadata** — If your setup uses a relay, it can process network and session metadata needed to route traffic and maintain the connection.

### 2.3 Information We Do Not Collect for Analytics or Advertising

- We do **not** collect analytics, telemetry, advertising profiles, or behavioral tracking data.
- We do **not** use third-party advertising SDKs.
- We do **not** track you across other companies' apps or websites.
- We do **not** require your name, phone number, or email address to use the App.

If you contact us directly, we will of course receive whatever information you include in that message.

## 3. How We Use Information

We use the information above only to operate and secure Remodex, including:

- pairing your iPhone with your Mac
- routing encrypted traffic between your iPhone and Mac
- performing trusted reconnect
- transcribing voice notes and enabling Live Voice when you explicitly use those features
- maintaining app security and stability

We do not use your information for advertising, profiling, or resale.

### 3.1 GDPR Legal Bases

If you are in the European Economic Area, we rely on the following legal bases:

- **Contract performance** — to provide the App's core features, including pairing, connection transport, voice transcription, and Live Voice
- **Legitimate interests** — to secure the App, maintain connection reliability, and protect users and infrastructure
- **Consent** — for permissions such as camera, microphone, photo library, and local network access

## 4. Services That Process Data

### 4.1 Your Paired Mac and Configured Relay

The bridge and Codex runtime run on your paired Mac. Your setup may connect directly or use a relay endpoint configured for your installation. A relay can process routing and connection metadata such as IP address, timestamps, and session state. Once the secure session is active, the relay does **not** decrypt Remodex application payloads.

### 4.2 OpenAI / ChatGPT

When you use voice notes, their audio is sent to OpenAI/ChatGPT for speech-to-text transcription. When you use Live Voice, microphone audio is streamed through your paired Mac to OpenAI's realtime voice service. To speak a Codex reply, Remodex sends only the completed final answer from the matching Codex turn to OpenAI; Codex reasoning, commentary, and tool output are excluded from that reply path. OpenAI processes these voice inputs and replies under its own policies; consult OpenAI's privacy policy for details about its handling and retention.

- Privacy policy: [openai.com/privacy](https://openai.com/privacy)

### 4.3 Apple

Apple provides:

- App Store distribution
- iOS permission and platform services used by the app

- Privacy policy: [apple.com/privacy](https://www.apple.com/privacy/)

## 5. Data Storage and Security

### 5.1 On Your iPhone

- **Keychain** — sensitive values such as identity keys, pairing state, relay credentials, and encryption keys
- **Encrypted message cache** — chat history is stored locally in encrypted form using a Keychain-backed key
- **UserDefaults** — non-sensitive preferences and interface settings
- **Temporary files** — voice-note recordings are stored temporarily during capture/transcription. Live Voice audio is streamed in chunks during the active session rather than recorded as a voice-note WAV by Remodex.

### 5.2 On Your Mac

Your paired Mac runs the local bridge and Codex runtime. Chat handling, git operations, workspace actions, and Live Voice forwarding are performed there.

### 5.3 On a Configured Relay

If your setup uses a relay, it may keep limited operational state such as active session and reconnect metadata needed to route traffic and restore a secure connection. Remodex does not require a developer-operated hosted relay.

### 5.4 In Transit

- The iPhone and Mac establish an end-to-end encrypted session using modern cryptography.
- A configured relay can observe connection metadata and secure-session setup traffic, but not encrypted application payloads after the secure session is established.
- Voice-note transcription and Live Voice provider traffic are sent over HTTPS/TLS from the device or paired Mac bridge, respectively.

## 6. Data Retention

- **Chat history on iPhone** — stored locally until the app's local storage is removed. Unpairing or forgetting a Mac does **not** automatically erase local chat history.
- **Voice-note recordings** — temporary voice files are deleted by the app after transcription completes or fails. Live Voice audio is streamed during the session; Remodex does not save it as a voice-note file.
- **Pairing and trusted-device state** — retained in local app storage and Keychain until removed by app actions or platform behavior.

We do not maintain a cloud chat history database for your message contents.

## 7. Your Choices

### 7.1 Permissions

You can revoke camera, microphone, photo library, and local network permissions at any time in iOS Settings. Doing so disables the related feature.

### 7.2 Local Data and Reset

- Deleting the app removes ordinary app-container files such as local encrypted chat history and temporary files.
- Keychain items are managed by iOS separately from ordinary app files and may persist differently, including across reinstall scenarios.
- If you want to reset pairing/trusted-device state before deleting or reinstalling the app, use the in-app forget/unpair controls first.

## 8. Privacy Rights

Depending on your jurisdiction, you may have rights to access, correct, delete, restrict, or object to the processing of personal information, and to request portability where applicable.

Because Remodex is primarily local-first, much of your data remains under your direct control on your devices. We do not maintain a centralized database of your personal data. Some data may be processed or retained by Apple and OpenAI according to their own operational needs and policies.

### 8.1 California Notice

We do not sell or share personal information for cross-context behavioral advertising.

## 9. Children's Privacy

The App is not directed to children under 13, or the minimum age required by local law. We do not knowingly collect personal information from children.

## 10. International Transfers

Depending on where you use the App and where service providers or configured relay endpoints are located, data processed by OpenAI, Apple, or those endpoints may be handled outside your country of residence.

## 11. Changes to This Policy

We may update this Data Protection Notice from time to time. When we do, we will update the "Last updated" date above.

## 12. Contact

If you have questions about this Data Protection Notice or want to exercise your privacy rights, you can reach us at:

- **Email:** emandipietro@gmail.com
- **GitHub:** [github.com/Emanuele-web04/remodex](https://github.com/Emanuele-web04/remodex)
- **X (Twitter):** [@emanueledpt](https://x.com/emanueledpt)
