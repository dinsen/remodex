// FILE: TurnComposerViewState.swift
// Purpose: Groups the heaviest composer render inputs into focused value types for smaller view sections.
// Layer: View Support
// Exports: TurnComposerAutocompleteState, TurnComposerAccessoryState
// Depends on: SwiftUI, TurnComposer command/attachment/message models

import AVFAudio
import SwiftUI

enum VoicePreference {
    static let storageKey = "codex.voice.enabled"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: storageKey)
    }

    static func setEnabled(_ isEnabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(isEnabled, forKey: storageKey)
    }
}

enum VoiceComposerPhaseOne {
    enum TrailingControl: Equatable {
        case normal
        case send
        case voiceWave
    }

    static func trailingControl(
        isVoiceEnabled: Bool,
        hasSendableContent: Bool,
        isVoiceSessionActive: Bool
    ) -> TrailingControl {
        guard isVoiceEnabled else { return .normal }
        if isVoiceSessionActive { return .voiceWave }
        return hasSendableContent ? .send : .voiceWave
    }
}

enum VoiceMicrophonePermission {
    case granted
    case denied
    case restricted
}

enum VoiceMicrophonePermissionRequest {
    static func request() async -> VoiceMicrophonePermission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return .granted
        case .denied:
            return .denied
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { isGranted in
                    continuation.resume(returning: isGranted ? .granted : .denied)
                }
            }
        @unknown default:
            return .restricted
        }
    }
}

@MainActor
@Observable
final class VoiceComposerPhaseTwoController {
    typealias PermissionRequester = () async -> VoiceMicrophonePermission

    private let requestPermission: PermissionRequester
    private var activePermissionRequestID: UUID?
    private(set) var isVoiceSessionActive = false
    var permissionExplanation: String?

    init(requestPermission: @escaping PermissionRequester = VoiceMicrophonePermissionRequest.request) {
        self.requestPermission = requestPermission
    }

    func handleWaveTap() async {
        if isVoiceSessionActive {
            endVoiceSession()
            return
        }

        permissionExplanation = nil
        let requestID = UUID()
        activePermissionRequestID = requestID
        switch await requestPermission() {
        case .granted:
            guard activePermissionRequestID == requestID else { return }
            isVoiceSessionActive = true
            activePermissionRequestID = nil
        case .denied, .restricted:
            guard activePermissionRequestID == requestID else { return }
            isVoiceSessionActive = false
            permissionExplanation = "Allow Microphone access for Remodex in Settings to use Voice."
            activePermissionRequestID = nil
        }
    }

    func endVoiceSession() {
        isVoiceSessionActive = false
        activePermissionRequestID = nil
    }

    func disableVoice() {
        endVoiceSession()
    }
}

struct TurnComposerAutocompleteState: Equatable {
    let availableSlashCommands: [TurnComposerSlashCommand]
    let fileAutocompleteItems: [CodexFuzzyFileMatch]
    let isFileAutocompleteVisible: Bool
    let isFileAutocompleteLoading: Bool
    let fileAutocompleteQuery: String
    let skillAutocompleteItems: [CodexSkillMetadata]
    let isSkillAutocompleteVisible: Bool
    let isSkillAutocompleteLoading: Bool
    let skillAutocompleteQuery: String
    let skillAutocompleteTrigger: String
    let pluginAutocompleteItems: [CodexPluginMetadata]
    let isPluginAutocompleteVisible: Bool
    let isPluginAutocompleteLoading: Bool
    let pluginAutocompleteQuery: String
    let slashCommandPanelState: TurnComposerSlashCommandPanelState
    let hasComposerContentConflictingWithReview: Bool
    let isThreadRunning: Bool
    let showsGitBranchSelector: Bool
    let isLoadingGitBranchTargets: Bool
    let availableGitBranchTargets: [String]
    let selectedGitBaseBranch: String
    let gitDefaultBranch: String
}

struct TurnComposerAccessoryState: Equatable {
    let queuedDrafts: [QueuedTurnDraft]
    let canSteerQueuedDrafts: Bool
    let canRestoreQueuedDrafts: Bool
    let steeringDraftID: String?
    let composerAttachments: [TurnComposerImageAttachment]
    let composerMentionedFiles: [TurnComposerMentionedFile]
    let composerMentionedSkills: [TurnComposerMentionedSkill]
    let composerMentionedPlugins: [TurnComposerMentionedPlugin]
    let composerReviewSelection: TurnComposerReviewSelection?
    let isSubagentsSelectionArmed: Bool
    let isPlanModeArmed: Bool
    let isVoiceRecording: Bool
    let voiceAudioLevels: [CGFloat]
    let voiceRecordingDuration: TimeInterval

    var hasQueuedDrafts: Bool {
        !queuedDrafts.isEmpty
    }

    var showsComposerAttachments: Bool {
        !composerAttachments.isEmpty
    }

    var showsMentionedFiles: Bool {
        !showsVoiceRecordingCapsule && !composerMentionedFiles.isEmpty
    }

    var showsMentionedPlugins: Bool {
        !showsVoiceRecordingCapsule && !composerMentionedPlugins.isEmpty
    }

    var reviewTarget: TurnComposerReviewTarget? {
        composerReviewSelection?.target
    }

    var showsSubagentsSelection: Bool {
        !showsVoiceRecordingCapsule && isSubagentsSelectionArmed
    }

    var showsPlanModeSelection: Bool {
        !showsVoiceRecordingCapsule && isPlanModeArmed
    }

    var showsReviewSelection: Bool {
        !showsVoiceRecordingCapsule && reviewTarget != nil
    }

    var showsVoiceRecordingCapsule: Bool {
        isVoiceRecording
    }

    var hasTopAccessoryContent: Bool {
        showsComposerAttachments
            || showsMentionedFiles
            || showsMentionedPlugins
            || showsSubagentsSelection
            || showsPlanModeSelection
            || showsReviewSelection
    }

    // Tracks composer content that can make a follow-up send meaningful while a turn is running.
    func hasSendableContent(input: String) -> Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !composerAttachments.isEmpty
            || !composerMentionedFiles.isEmpty
            || !composerMentionedSkills.isEmpty
            || !composerMentionedPlugins.isEmpty
            || composerReviewSelection != nil
            || isSubagentsSelectionArmed
            || isPlanModeArmed
    }

    var topInputPadding: CGFloat {
        hasTopAccessoryContent ? 6 : 10
    }
}
