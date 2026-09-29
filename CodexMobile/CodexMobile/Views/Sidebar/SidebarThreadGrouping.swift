// FILE: SidebarThreadGrouping.swift
// Purpose: Produces the global Activity list or sidebar groups by native Codex
//          section, project path (`cwd`), and rootless chat scope while excluding
//          archived chats.
// Layer: View Helper
// Exports: SidebarTaskViewMode, SidebarThreadGroupKind, SidebarContentScope, SidebarThreadGroup,
//          SidebarThreadGrouping

import Foundation

enum SidebarTaskViewMode: String, CaseIterable, Identifiable {
    case activity
    case projects

    var id: String { rawValue }

    var title: String {
        switch self {
        case .activity: return "Activity"
        case .projects: return "Projects"
        }
    }

    var iconSystemName: String {
        switch self {
        case .activity: return "bell.badge"
        case .projects: return "folder"
        }
    }
}

enum SidebarThreadGroupKind: Equatable {
    case pinned
    case section
    case project
    case chat
}

enum SidebarContentScope: String, CaseIterable, Hashable, Identifiable {
    case projects
    case chats
    case automations

    var id: String { rawValue }

    var title: String {
        switch self {
        case .projects:
            return "Projects"
        case .chats:
            return "Chats"
        case .automations:
            return "Automations"
        }
    }
}

enum SidebarProjectSource: String, CaseIterable, Hashable, Identifiable {
    case configuredProjects
    case recentThreadProjects

    static let storageKey = "sidebar.projectSource"
    static let defaultSource: SidebarProjectSource = .configuredProjects

    var id: String { rawValue }

    var title: String {
        switch self {
        case .configuredProjects:
            return "Configured Projects"
        case .recentThreadProjects:
            return "Recent Thread Projects"
        }
    }
}

enum SidebarThreadGroupingScope: Equatable {
    case all
    case projects
    case chats
    case section(String)
}

struct SidebarProjectChoice: Identifiable, Equatable {
    let id: String
    let label: String
    let iconSystemName: String
    let projectPath: String
    let sortDate: Date
}

struct SidebarThreadGroup: Identifiable {
    let id: String
    let label: String
    let kind: SidebarThreadGroupKind
    let sortDate: Date
    let projectPath: String?
    let threads: [CodexThread]
    let parentSectionID: String?
    var includesDescendantProjectPaths: Bool

    init(
        id: String,
        label: String,
        kind: SidebarThreadGroupKind,
        sortDate: Date,
        projectPath: String?,
        threads: [CodexThread],
        parentSectionID: String? = nil,
        includesDescendantProjectPaths: Bool = false
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.sortDate = sortDate
        self.projectPath = projectPath
        self.threads = threads
        self.parentSectionID = parentSectionID
        self.includesDescendantProjectPaths = includesDescendantProjectPaths
    }

    var iconSystemName: String {
        switch kind {
        case .pinned:
            return "pin"
        case .section:
            return "rectangle.3.group"
        case .project:
            return CodexThread.projectIconSystemName(for: projectPath)
        case .chat:
            return "bubble.left.and.bubble.right"
        }
    }

    func contains(_ thread: CodexThread) -> Bool {
        threads.contains(where: { $0.id == thread.id })
    }
}

enum SidebarThreadGrouping {
    // Activity spans all projects and rootless chats, independently of the
    // Projects/Chats scope used by the grouped presentation.
    static func activityThreads(
        from threads: [CodexThread],
        runBadgeStateByThreadID: [String: CodexThreadRunBadgeState]
    ) -> [CodexThread] {
        sortThreadsByRecentActivity(
            threads.filter { $0.syncState != .archivedLocal },
            runBadgeStateByThreadID: runBadgeStateByThreadID,
            viewMode: .activity
        )
    }

    // Sidebar grouping never depends on the arbitrary metadata dictionary that
    // the app-server can attach to a thread. Hashing the whole CodexThread
    // during every sync therefore made large metadata payloads part of the
    // scrolling hot path. Keep this projection limited to fields that affect
    // filtering, ordering, hierarchy, row labels, or project membership.
    static func threadFingerprint(_ thread: CodexThread) -> Int {
        var hasher = Hasher()
        hasher.combine(thread.id)
        hasher.combine(thread.title)
        hasher.combine(thread.name)
        hasher.combine(thread.preview)
        hasher.combine(thread.createdAt)
        hasher.combine(thread.updatedAt)
        hasher.combine(thread.section)
        hasher.combine(thread.sectionEnteredAt)
        hasher.combine(thread.cwd)
        hasher.combine(thread.worktreeOriginPath)
        hasher.combine(thread.forkedFromThreadId)
        hasher.combine(thread.threadSource)
        hasher.combine(thread.parentThreadId)
        hasher.combine(thread.agentId)
        hasher.combine(thread.agentNickname)
        hasher.combine(thread.agentRole)
        hasher.combine(thread.model)
        hasher.combine(thread.modelProvider)
        hasher.combine(thread.goalStatus)
        hasher.combine(thread.reasoningEffort)
        hasher.combine(thread.serviceTier)
        hasher.combine(thread.runtimeSettingsRevision)
        hasher.combine(thread.runtimeSettingsUpdatedAt)
        hasher.combine(thread.runtimeSettingsSource)
        hasher.combine(thread.syncState)
        return hasher.finalize()
    }

    static func threadsFingerprint(_ threads: [CodexThread]) -> Int {
        var hasher = Hasher()
        hasher.combine(threads.count)
        for thread in threads {
            hasher.combine(threadFingerprint(thread))
        }
        return hasher.finalize()
    }

    static func makeGroups(
        from threads: [CodexThread],
        pinnedThreadIDs: [String] = [],
        sections: [CodexThreadSection] = [],
        sectionThreadIDsBySection: [String: [String]] = [:],
        sectionProjectChoicesBySection: [String: [SidebarProjectChoice]] = [:],
        scope: SidebarThreadGroupingScope = .all,
        projectlessRootPaths: [String] = [],
        projectSource: SidebarProjectSource = .recentThreadProjects,
        configuredProjectChoices: [SidebarProjectChoice] = [],
        runBadgeStateByThreadID: [String: CodexThreadRunBadgeState] = [:],
        now _: Date = Date(),
        calendar _: Calendar = .current
    ) -> [SidebarThreadGroup] {
        var groups: [SidebarThreadGroup] = []
        let sectionProjectPathsBySection = sectionProjectPaths(
            from: sectionProjectChoicesBySection
        )
        let scopedThreads = threadsForScope(
            scope,
            from: threads,
            projectlessRootPaths: projectlessRootPaths,
            sectionThreadIDsBySection: sectionThreadIDsBySection,
            sectionProjectPathsBySection: sectionProjectPathsBySection
        )
        let pinnedThreads = collectPinnedThreads(from: scopedThreads, pinnedRootThreadIDs: pinnedThreadIDs)
        let pinnedThreadIDSet = Set(pinnedThreads.map(\.id))

        if let firstPinned = pinnedThreads.first {
            groups.append(
                SidebarThreadGroup(
                    id: "pinned",
                    label: "Pinned",
                    kind: .pinned,
                    sortDate: firstPinned.updatedAt ?? firstPinned.createdAt ?? .distantPast,
                    projectPath: nil,
                    threads: pinnedThreads
                )
            )
        }

        switch scope {
        case .all, .projects:
            groups.append(contentsOf: makeSectionGroups(
                from: scopedThreads,
                sections: sections,
                threadIDsBySection: sectionThreadIDsBySection,
                sectionProjectPathsBySection: sectionProjectPathsBySection,
                sectionProjectChoicesBySection: sectionProjectChoicesBySection,
                projectlessRootPaths: projectlessRootPaths,
                excludingPinnedThreadIDs: pinnedThreadIDSet,
                runBadgeStateByThreadID: runBadgeStateByThreadID
            ))
        case .chats, .section:
            // Rootless Chats stays separate from native Codex sections. A selected
            // native section is rendered as its project buckets in the switch below.
            break
        }

        switch scope {
        case .all:
            let unsectionedThreads = unsectionedThreads(
                from: scopedThreads,
                sectionThreadIDsBySection: sectionThreadIDsBySection,
                sectionProjectPathsBySection: sectionProjectPathsBySection
            )
            let projectThreads = threadsForScope(.projects, from: unsectionedThreads, projectlessRootPaths: projectlessRootPaths)
            let chatThreads = threadsForScope(.chats, from: unsectionedThreads, projectlessRootPaths: projectlessRootPaths)
            groups.append(contentsOf: makeProjectGroups(
                from: projectThreads,
                excludingPinnedThreadIDs: pinnedThreadIDSet,
                projectSource: projectSource,
                configuredProjectChoices: configuredProjectChoices,
                runBadgeStateByThreadID: runBadgeStateByThreadID
            ))
            if let chatGroup = makeRootlessChatGroup(
                from: chatThreads,
                excludingPinnedThreadIDs: pinnedThreadIDSet,
                runBadgeStateByThreadID: runBadgeStateByThreadID
            ) {
                groups.append(chatGroup)
            }
        case .projects:
            let unsectionedThreads = unsectionedThreads(
                from: scopedThreads,
                sectionThreadIDsBySection: sectionThreadIDsBySection,
                sectionProjectPathsBySection: sectionProjectPathsBySection
            )
            groups.append(contentsOf: makeProjectGroups(
                from: unsectionedThreads,
                excludingPinnedThreadIDs: pinnedThreadIDSet,
                projectSource: projectSource,
                configuredProjectChoices: configuredProjectChoices,
                runBadgeStateByThreadID: runBadgeStateByThreadID
            ))
        case .chats:
            if let chatGroup = makeRootlessChatGroup(
                from: scopedThreads,
                excludingPinnedThreadIDs: pinnedThreadIDSet,
                runBadgeStateByThreadID: runBadgeStateByThreadID
            ) {
                groups.append(chatGroup)
            }
        case .section:
            let sectionID: String
            if case let .section(selectedSectionID) = scope {
                sectionID = selectedSectionID
            } else {
                sectionID = ""
            }
            let projectThreads = threadsForScope(
                .projects,
                from: scopedThreads,
                projectlessRootPaths: projectlessRootPaths,
                sectionThreadIDsBySection: sectionThreadIDsBySection,
                sectionProjectPathsBySection: sectionProjectPathsBySection
            )
            groups.append(contentsOf: makeProjectGroups(
                from: projectThreads,
                excludingPinnedThreadIDs: pinnedThreadIDSet,
                projectSource: .configuredProjects,
                configuredProjectChoices: sectionProjectChoicesBySection[sectionID] ?? [],
                runBadgeStateByThreadID: runBadgeStateByThreadID
            ))
            if let chatGroup = makeRootlessChatGroup(
                from: threadsForScope(
                    .chats,
                    from: scopedThreads,
                    projectlessRootPaths: projectlessRootPaths,
                    sectionThreadIDsBySection: sectionThreadIDsBySection,
                    sectionProjectPathsBySection: sectionProjectPathsBySection
                ),
                excludingPinnedThreadIDs: pinnedThreadIDSet,
                runBadgeStateByThreadID: runBadgeStateByThreadID
            ) {
                groups.append(chatGroup)
            }
        }

        return groups
    }

    // Native Codex keeps Pinned as a section, but the sidebar renders it in its
    // own leading group. Preserve the runtime order for all other sections.
    static func selectableSections(_ sections: [CodexThreadSection]) -> [CodexThreadSection] {
        var seenIDs: Set<String> = []
        return sections.filter { section in
            let sectionID = section.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let sectionName = section.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sectionID.isEmpty,
                  !sectionName.isEmpty,
                  sectionName.localizedCaseInsensitiveCompare("Pinned") != .orderedSame,
                  seenIDs.insert(section.id).inserted else {
                return false
            }

            return true
        }
    }

    private static func makeSectionGroups(
        from threads: [CodexThread],
        sections: [CodexThreadSection],
        threadIDsBySection: [String: [String]],
        sectionProjectPathsBySection: [String: [String]],
        sectionProjectChoicesBySection: [String: [SidebarProjectChoice]],
        projectlessRootPaths: [String],
        excludingPinnedThreadIDs pinnedThreadIDs: Set<String>,
        runBadgeStateByThreadID: [String: CodexThreadRunBadgeState]
    ) -> [SidebarThreadGroup] {
        var knownSectionsByID: [String: CodexThreadSection] = [:]
        let sectionMembership = threadIDsBySection.mapValues(Set.init)
        for section in selectableSections(sections) {
            knownSectionsByID[section.id] = section
        }
        for section in selectableSections(threads.compactMap(\.section)) {
            knownSectionsByID[section.id] = section
        }

        let sortedSections = knownSectionsByID.values.sorted { lhs, rhs in
            let lhsThreads = threads.filter {
                threadBelongsToSection(
                    $0,
                    sectionID: lhs.id,
                    sectionMembership: sectionMembership[lhs.id],
                    hasAuthoritativeMembership: threadIDsBySection[lhs.id] != nil,
                    sectionProjectPaths: sectionProjectPathsBySection[lhs.id] ?? []
                ) && !pinnedThreadIDs.contains($0.id)
            }
            let rhsThreads = threads.filter {
                threadBelongsToSection(
                    $0,
                    sectionID: rhs.id,
                    sectionMembership: sectionMembership[rhs.id],
                    hasAuthoritativeMembership: threadIDsBySection[rhs.id] != nil,
                    sectionProjectPaths: sectionProjectPathsBySection[rhs.id] ?? []
                ) && !pinnedThreadIDs.contains($0.id)
            }
            let lhsSortDate = lhsThreads.first?.updatedAt ?? lhsThreads.first?.createdAt ?? .distantPast
            let rhsSortDate = rhsThreads.first?.updatedAt ?? rhsThreads.first?.createdAt ?? .distantPast
            if lhsSortDate != rhsSortDate { return lhsSortDate > rhsSortDate }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        return sortedSections.flatMap { section in
            let matchingThreads = threads.filter {
                threadBelongsToSection(
                    $0,
                    sectionID: section.id,
                    sectionMembership: sectionMembership[section.id],
                    hasAuthoritativeMembership: threadIDsBySection[section.id] != nil,
                    sectionProjectPaths: sectionProjectPathsBySection[section.id] ?? []
                ) && !pinnedThreadIDs.contains($0.id)
            }
            let threadsByID = Dictionary(uniqueKeysWithValues: matchingThreads.map { ($0.id, $0) })
            let nativeOrderedThreads = (threadIDsBySection[section.id] ?? []).compactMap { threadsByID[$0] }
            let nativeOrderedThreadIDs = Set(nativeOrderedThreads.map(\.id))
            let remainingThreads = sortThreadsByRecentActivity(
                matchingThreads.filter { !nativeOrderedThreadIDs.contains($0.id) },
                runBadgeStateByThreadID: runBadgeStateByThreadID
            )
            let sectionThreads = nativeOrderedThreads + remainingThreads
            let sectionGroup = SidebarThreadGroup(
                id: "section:\(section.id)",
                label: section.name,
                kind: .section,
                sortDate: sectionThreads.first?.updatedAt ?? sectionThreads.first?.createdAt ?? .distantPast,
                projectPath: nil,
                threads: sectionThreads
            )

            let projectGroups = makeProjectGroups(
                from: threadsForScope(
                    .projects,
                    from: sectionThreads,
                    projectlessRootPaths: projectlessRootPaths,
                    sectionThreadIDsBySection: threadIDsBySection,
                    sectionProjectPathsBySection: sectionProjectPathsBySection
                ),
                projectSource: .configuredProjects,
                configuredProjectChoices: sectionProjectChoicesBySection[section.id] ?? [],
                runBadgeStateByThreadID: runBadgeStateByThreadID
            ).map { group in
                SidebarThreadGroup(
                    id: "section:\(section.id)/\(group.id)",
                    label: group.label,
                    kind: group.kind,
                    sortDate: group.sortDate,
                    projectPath: group.projectPath,
                    threads: group.threads,
                    parentSectionID: section.id,
                    includesDescendantProjectPaths: group.includesDescendantProjectPaths
                )
            }

            let chatGroup = makeRootlessChatGroup(
                from: threadsForScope(
                    .chats,
                    from: sectionThreads,
                    projectlessRootPaths: projectlessRootPaths,
                    sectionThreadIDsBySection: threadIDsBySection,
                    sectionProjectPathsBySection: sectionProjectPathsBySection
                ),
                excludingPinnedThreadIDs: [],
                runBadgeStateByThreadID: runBadgeStateByThreadID
            ).map { group in
                SidebarThreadGroup(
                    id: "section:\(section.id)/\(group.id)",
                    label: group.label,
                    kind: group.kind,
                    sortDate: group.sortDate,
                    projectPath: group.projectPath,
                    threads: group.threads,
                    parentSectionID: section.id,
                    includesDescendantProjectPaths: group.includesDescendantProjectPaths
                )
            }

            return [sectionGroup] + projectGroups + (chatGroup.map { [$0] } ?? [])
        }
    }

    // Keeps the UI picker from leaking project chats into rootless Chats and vice versa.
    static func threadsForScope(
        _ scope: SidebarThreadGroupingScope,
        from threads: [CodexThread],
        projectlessRootPaths: [String] = [],
        sectionThreadIDsBySection: [String: [String]] = [:],
        sectionProjectPathsBySection: [String: [String]] = [:]
    ) -> [CodexThread] {
        switch scope {
        case .all:
            return threads
        case .projects:
            return threads.filter { !isRootlessChatThread($0, projectlessRootPaths: projectlessRootPaths) }
        case .chats:
            return threads.filter { isRootlessChatThread($0, projectlessRootPaths: projectlessRootPaths) }
        case let .section(sectionID):
            let sectionMembership = sectionThreadIDsBySection[sectionID].map(Set.init)
            return threads.filter {
                threadBelongsToSection(
                    $0,
                    sectionID: sectionID,
                    sectionMembership: sectionMembership,
                    hasAuthoritativeMembership: sectionThreadIDsBySection[sectionID] != nil,
                    sectionProjectPaths: sectionProjectPathsBySection[sectionID] ?? []
                )
            }
        }
    }

    private static func unsectionedThreads(
        from threads: [CodexThread],
        sectionThreadIDsBySection: [String: [String]],
        sectionProjectPathsBySection: [String: [String]]
    ) -> [CodexThread] {
        let sectionMembership = sectionThreadIDsBySection.mapValues(Set.init)
        return threads.filter { thread in
            if let sectionID = thread.section?.id,
               sectionThreadIDsBySection[sectionID] == nil {
                return false
            }

            return !sectionThreadIDsBySection.keys.contains(where: { sectionID in
                threadBelongsToSection(
                    thread,
                    sectionID: sectionID,
                    sectionMembership: sectionMembership[sectionID],
                    hasAuthoritativeMembership: sectionThreadIDsBySection[sectionID] != nil,
                    sectionProjectPaths: sectionProjectPathsBySection[sectionID] ?? []
                )
            })
        }
    }

    // The section-specific thread/list response is authoritative. Regular
    // thread/list responses can omit section metadata, so grouping must use the
    // membership map whenever it has a key for the section and only fall back to
    // the per-thread field for older servers without that map.
    private static func threadBelongsToSection(
        _ thread: CodexThread,
        sectionID: String,
        sectionMembership: Set<String>?,
        hasAuthoritativeMembership: Bool,
        sectionProjectPaths: [String]
    ) -> Bool {
        if threadProjectPathMatchesAny(thread, projectPaths: sectionProjectPaths) {
            return true
        }

        if hasAuthoritativeMembership {
            return sectionMembership?.contains(thread.id) == true
        }

        return thread.section?.id == sectionID
    }

    static func sectionProjectPaths(
        from choicesBySection: [String: [SidebarProjectChoice]]
    ) -> [String: [String]] {
        choicesBySection.mapValues { choices in
            var seenPaths: Set<String> = []
            return choices.compactMap { choice in
                guard let path = CodexThread.normalizedFilesystemProjectPath(choice.projectPath),
                      seenPaths.insert(path).inserted else {
                    return nil
                }
                return path
            }
        }
    }

    private static func threadProjectPathMatchesAny(
        _ thread: CodexThread,
        projectPaths: [String]
    ) -> Bool {
        guard let threadPath = thread.projectGroupPath,
              !projectPaths.isEmpty else {
            return false
        }

        let threadComponents = projectPathComponents(threadPath)
        return projectPaths.contains { projectPath in
            let projectComponents = projectPathComponents(projectPath)
            return isPathComponents(threadComponents, sameOrDescendantOf: projectComponents)
        }
    }

    // Projectless chats still receive generated host-side working directories,
    // so rootless detection cannot rely on cwd == nil alone.
    static func isRootlessChatThread(
        _ thread: CodexThread,
        projectlessRootPaths: [String] = []
    ) -> Bool {
        thread.normalizedProjectPath == nil
            || isBareUserHomePath(thread.normalizedProjectPath)
            || isUnderProjectlessRoot(thread.normalizedProjectPath, roots: projectlessRootPaths)
            || isGeneratedCodexProjectlessPath(thread.normalizedProjectPath)
    }

    // Reuses the sidebar project grouping rules for places like the New Chat chooser.
    static func makeProjectChoices(
        from threads: [CodexThread],
        projectlessRootPaths: [String] = [],
        projectSource: SidebarProjectSource = .recentThreadProjects,
        configuredProjectChoices: [SidebarProjectChoice] = []
    ) -> [SidebarProjectChoice] {
        makeProjectGroups(from: threadsForScope(
            .projects,
            from: threads,
            projectlessRootPaths: projectlessRootPaths
        ), projectSource: projectSource, configuredProjectChoices: configuredProjectChoices).compactMap { group in
            guard let projectPath = group.projectPath else {
                return nil
            }

            return SidebarProjectChoice(
                id: group.id,
                label: group.label,
                iconSystemName: group.iconSystemName,
                projectPath: projectPath,
                sortDate: group.sortDate
            )
        }
    }

    // Resolves all live thread ids that belong to the tapped project, even if the visible group is filtered.
    static func liveThreadIDsForProjectGroup(_ group: SidebarThreadGroup, in threads: [CodexThread]) -> [String] {
        guard group.kind == .project else {
            return []
        }

        return sortThreadsByRecentActivity(
            threads.filter { thread in
                thread.syncState != .archivedLocal && threadBelongsToProjectGroup(thread, group)
            }
        ).map(\.id)
    }

    // Includes archived and pinned chats so local project removal fully hides the project on this device.
    static func allThreadIDsForProjectGroup(_ group: SidebarThreadGroup, in threads: [CodexThread]) -> [String] {
        guard group.kind == .project else {
            return []
        }

        return sortThreadsByRecentActivity(
            threads.filter { thread in
                threadBelongsToProjectGroup(thread, group)
            }
        ).map(\.id)
    }

    // The group speaks for the project, not for whichever chat happens to sort first: a worktree
    // chat at the top must still show the source project's name, icon, and new-chat target.
    private static func makeProjectGroup(
        projectKey: String,
        projectPath: String?,
        threads: [CodexThread],
        runBadgeStateByThreadID: [String: CodexThreadRunBadgeState]
    ) -> SidebarThreadGroup {
        let sortedThreads = sortThreadsByRecentActivity(
            threads,
            runBadgeStateByThreadID: runBadgeStateByThreadID
        )
        // The first thread can be an old chat lifted by its run state, so the group's
        // recency comes from the newest activity anywhere in the group instead.
        let sortDate = threads
            .compactMap { $0.updatedAt ?? $0.createdAt }
            .max() ?? .distantPast
        return SidebarThreadGroup(
            id: "project:\(projectKey)",
            label: CodexThread.projectDisplayLabel(for: projectPath),
            kind: .project,
            sortDate: sortDate,
            projectPath: projectPath,
            threads: sortedThreads
        )
    }

    private static func makeConfiguredProjectGroup(
        projectPath: String,
        label: String,
        sortDate: Date,
        threads: [CodexThread],
        runBadgeStateByThreadID: [String: CodexThreadRunBadgeState]
    ) -> SidebarThreadGroup {
        let sortedThreads = sortThreadsByRecentActivity(
            threads,
            runBadgeStateByThreadID: runBadgeStateByThreadID
        )
        let latestThreadDate = threads
            .compactMap { $0.updatedAt ?? $0.createdAt }
            .max()
        return SidebarThreadGroup(
            id: projectGroupID(forProjectPath: projectPath),
            label: configuredProjectLabel(label, projectPath: projectPath),
            kind: .project,
            sortDate: latestThreadDate ?? sortDate,
            projectPath: projectPath,
            threads: sortedThreads,
            includesDescendantProjectPaths: true
        )
    }

    private static func makeRootlessChatGroup(
        from threads: [CodexThread],
        excludingPinnedThreadIDs pinnedThreadIDs: Set<String>,
        runBadgeStateByThreadID: [String: CodexThreadRunBadgeState]
    ) -> SidebarThreadGroup? {
        let liveThreads = threads.filter {
            $0.syncState != .archivedLocal && !pinnedThreadIDs.contains($0.id)
        }
        let sortedThreads = sortThreadsByRecentActivity(
            liveThreads,
            runBadgeStateByThreadID: runBadgeStateByThreadID
        )
        guard !sortedThreads.isEmpty else {
            return nil
        }

        return SidebarThreadGroup(
            id: "chats:rootless",
            label: "Chats",
            kind: .chat,
            sortDate: liveThreads
                .compactMap { $0.updatedAt ?? $0.createdAt }
                .max() ?? .distantPast,
            projectPath: nil,
            threads: sortedThreads
        )
    }

    private static func isUnderProjectlessRoot(_ rawPath: String?, roots: [String]) -> Bool {
        guard let normalizedPath = CodexThread.normalizedFilesystemProjectPath(rawPath) else {
            return false
        }
        let pathComponents = projectPathComponents(normalizedPath)
        guard !pathComponents.isEmpty else {
            return false
        }

        return roots.contains { root in
            guard let normalizedRoot = CodexThread.normalizedFilesystemProjectPath(root) else {
                return false
            }
            let rootComponents = projectPathComponents(normalizedRoot)
            guard !rootComponents.isEmpty, pathComponents.count >= rootComponents.count else {
                return false
            }

            return pathComponents.prefix(rootComponents.count).elementsEqual(rootComponents) {
                $0.localizedCaseInsensitiveCompare($1) == .orderedSame
            }
        }
    }

    private static func isGeneratedCodexProjectlessPath(_ rawPath: String?) -> Bool {
        guard let normalizedPath = CodexThread.normalizedFilesystemProjectPath(rawPath) else {
            return false
        }

        let pathComponents = projectPathComponents(normalizedPath)
        return isGeneratedDocumentsCodexPath(pathComponents)
            || isCodexHomeThreadsPath(pathComponents)
    }

    private static func isBareUserHomePath(_ rawPath: String?) -> Bool {
        guard let normalizedPath = CodexThread.normalizedFilesystemProjectPath(rawPath) else {
            return false
        }

        if normalizedPath == "~/" {
            return true
        }

        let pathComponents = projectPathComponents(normalizedPath)
        if pathComponents.count == 2,
           isCaseInsensitive(pathComponents[0], equalTo: "Users")
            || isCaseInsensitive(pathComponents[0], equalTo: "home") {
            return !pathComponents[1].isEmpty
        }

        if pathComponents.count == 3,
           pathComponents[0].hasSuffix(":"),
           isCaseInsensitive(pathComponents[1], equalTo: "Users") {
            return !pathComponents[2].isEmpty
        }

        return false
    }

    private static func isGeneratedDocumentsCodexPath(_ components: [String]) -> Bool {
        for index in components.indices {
            let dateIndex = index + 2
            let slugIndex = index + 3
            guard components[index] == "Documents",
                  components.indices.contains(dateIndex),
                  components.indices.contains(slugIndex),
                  components[index + 1] == "Codex",
                  isISODateFolderName(components[dateIndex]),
                  !components[slugIndex].isEmpty else {
                continue
            }
            return true
        }

        return false
    }

    private static func isCodexHomeThreadsPath(_ components: [String]) -> Bool {
        for index in components.indices {
            let childIndex = index + 2
            guard components[index] == ".codex",
                  components.indices.contains(childIndex),
                  components[index + 1] == "threads",
                  !components[childIndex].isEmpty else {
                continue
            }
            return true
        }

        return false
    }

    private static func projectPathComponents(_ path: String) -> [String] {
        path
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map(String.init)
    }

    private static func isCaseInsensitive(_ lhs: String, equalTo rhs: String) -> Bool {
        lhs.localizedCaseInsensitiveCompare(rhs) == .orderedSame
    }

    private static func isISODateFolderName(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard scalars.count == 10,
              scalars[4].value == 45,
              scalars[7].value == 45 else {
            return false
        }

        return scalars.enumerated().allSatisfy { index, scalar in
            if index == 4 || index == 7 {
                return true
            }
            return CharacterSet.decimalDigits.contains(scalar)
        }
    }

    // Keeps project-derived UI consistent by centralizing the live-thread → project bucket mapping.
    private static func makeProjectGroups(
        from threads: [CodexThread],
        excludingPinnedThreadIDs pinnedThreadIDs: Set<String> = [],
        projectSource: SidebarProjectSource = .recentThreadProjects,
        configuredProjectChoices: [SidebarProjectChoice] = [],
        runBadgeStateByThreadID: [String: CodexThreadRunBadgeState] = [:]
    ) -> [SidebarThreadGroup] {
        var liveThreadsByProject: [String: [CodexThread]] = [:]
        var projectPathByGroupKey: [String: String] = [:]
        var recentThreadsByProject: [String: [CodexThread]] = [:]
        var recentProjectPathByGroupKey: [String: String] = [:]
        let configuredProjectScopes = normalizedConfiguredProjectScopes(configuredProjectChoices)

        for thread in threads where thread.syncState != .archivedLocal {
            guard !pinnedThreadIDs.contains(thread.id) else {
                continue
            }

            if projectSource == .configuredProjects {
                if let configuredProjectScope = configuredProjectScope(
                    containing: thread.projectGroupKey,
                    scopes: configuredProjectScopes
                ) {
                    liveThreadsByProject[configuredProjectScope.projectPath, default: []].append(thread)
                } else {
                    // Configured roots can be unavailable on older bridges or
                    // simply omit a repository. Keep those chats in their
                    // normal project groups instead of hiding them.
                    recentThreadsByProject[thread.projectGroupKey, default: []].append(thread)
                    if let projectGroupPath = thread.projectGroupPath {
                        recentProjectPathByGroupKey[thread.projectGroupKey] = projectGroupPath
                    }
                }
            } else {
                liveThreadsByProject[thread.projectGroupKey, default: []].append(thread)
                if let projectGroupPath = thread.projectGroupPath {
                    projectPathByGroupKey[thread.projectGroupKey] = projectGroupPath
                }
            }
        }

        var groupsByID: [String: SidebarThreadGroup]
        if projectSource == .configuredProjects {
            groupsByID = Dictionary(uniqueKeysWithValues: configuredProjectScopes.compactMap { scope in
                guard let projectThreads = liveThreadsByProject[scope.projectPath] else {
                    return nil
                }
                let group = makeConfiguredProjectGroup(
                    projectPath: scope.projectPath,
                    label: scope.choice.label,
                    sortDate: scope.choice.sortDate,
                    threads: projectThreads,
                    runBadgeStateByThreadID: runBadgeStateByThreadID
                )
                return (group.id, group)
            })
        } else {
            groupsByID = Dictionary(uniqueKeysWithValues: liveThreadsByProject.map { projectKey, projectThreads in
                let group = makeProjectGroup(
                    projectKey: projectKey,
                    projectPath: projectPathByGroupKey[projectKey],
                    threads: projectThreads,
                    runBadgeStateByThreadID: runBadgeStateByThreadID
                )
                return (group.id, group)
            })
        }

        if projectSource == .configuredProjects {
            for (projectKey, projectThreads) in recentThreadsByProject {
                let group = makeProjectGroup(
                    projectKey: projectKey,
                    projectPath: recentProjectPathByGroupKey[projectKey],
                    threads: projectThreads,
                    runBadgeStateByThreadID: runBadgeStateByThreadID
                )
                groupsByID[group.id] = group
            }

            for choice in configuredProjectChoices {
                guard let projectPath = CodexThread.normalizedFilesystemProjectPath(choice.projectPath) else {
                    continue
                }
                let groupID = projectGroupID(forProjectPath: projectPath)
                guard groupsByID[groupID] == nil else {
                    continue
                }

                groupsByID[groupID] = SidebarThreadGroup(
                    id: groupID,
                    label: configuredProjectLabel(choice.label, projectPath: projectPath),
                    kind: .project,
                    sortDate: choice.sortDate,
                    projectPath: projectPath,
                    threads: [],
                    includesDescendantProjectPaths: true
                )
            }
        }

        if projectSource == .configuredProjects {
            // Codex Desktop supplies configuredProjectChoices in its sidebar
            // itemKeys order. Use that explicit order for every configured
            // group, including empty projects; activity is only a fallback
            // for groups that cannot be matched to a configured choice.
            let configuredOrderByGroupID = Dictionary(uniqueKeysWithValues: configuredProjectScopes.map {
                (projectGroupID(forProjectPath: $0.projectPath), $0.order)
            })
            return groupsByID.values.sorted { lhs, rhs in
                let lhsOrder = configuredOrderByGroupID[lhs.id] ?? Int.max
                let rhsOrder = configuredOrderByGroupID[rhs.id] ?? Int.max
                if lhsOrder != rhsOrder {
                    return lhsOrder < rhsOrder
                }

                return compareProjectGroupsByRecentActivity(lhs, rhs, runBadgeStateByThreadID: runBadgeStateByThreadID)
            }
        }

        return groupsByID.values.sorted { lhs, rhs in
            compareProjectGroupsByRecentActivity(lhs, rhs, runBadgeStateByThreadID: runBadgeStateByThreadID)
        }
    }

    private struct ConfiguredProjectScope {
        let choice: SidebarProjectChoice
        let order: Int
        let projectPath: String
        let pathComponents: [String]
    }

    private static func normalizedConfiguredProjectScopes(_ choices: [SidebarProjectChoice]) -> [ConfiguredProjectScope] {
        var seenProjectPaths: Set<String> = []
        return choices.enumerated().compactMap { order, choice in
            guard let projectPath = CodexThread.normalizedFilesystemProjectPath(choice.projectPath),
                  seenProjectPaths.insert(projectPath).inserted else {
                return nil
            }

            return ConfiguredProjectScope(
                choice: choice,
                order: order,
                projectPath: projectPath,
                pathComponents: projectPathComponents(projectPath)
            )
        }
    }

    private static func configuredProjectScope(
        containing rawProjectPath: String,
        scopes: [ConfiguredProjectScope]
    ) -> ConfiguredProjectScope? {
        guard let normalizedProjectPath = CodexThread.normalizedFilesystemProjectPath(rawProjectPath) else {
            return nil
        }
        let pathComponents = projectPathComponents(normalizedProjectPath)

        let directMatches = scopes.filter {
            isPathComponents(pathComponents, sameOrDescendantOf: $0.pathComponents)
        }
        if let directMatch = mostSpecificConfiguredProjectScope(from: directMatches) {
            return directMatch
        }

        guard let worktreeTailComponents = codexManagedWorktreeTailComponents(pathComponents) else {
            return nil
        }

        return mostSpecificConfiguredProjectScope(from: scopes.filter {
            pathTailComponents(worktreeTailComponents, matchSuffixOf: $0.pathComponents)
        })
    }

    private static func mostSpecificConfiguredProjectScope(
        from scopes: [ConfiguredProjectScope]
    ) -> ConfiguredProjectScope? {
        scopes
            .sorted { lhs, rhs in
                if lhs.pathComponents.count != rhs.pathComponents.count {
                    return lhs.pathComponents.count > rhs.pathComponents.count
                }
                return lhs.order < rhs.order
            }
            .first
    }

    private static func isPathComponents(
        _ pathComponents: [String],
        sameOrDescendantOf rootComponents: [String]
    ) -> Bool {
        guard !rootComponents.isEmpty, pathComponents.count >= rootComponents.count else {
            return false
        }

        return pathComponents.prefix(rootComponents.count).elementsEqual(rootComponents) {
            $0.localizedCaseInsensitiveCompare($1) == .orderedSame
        }
    }

    private static func compareProjectGroupsByRecentActivity(
        _ lhs: SidebarThreadGroup,
        _ rhs: SidebarThreadGroup,
        runBadgeStateByThreadID: [String: CodexThreadRunBadgeState] = [:]
    ) -> Bool {
        // A project whose chat is running (or waiting on the user) outranks purely
        // newer projects: threads are already tier-sorted, so each group's urgency
        // is whatever its first thread carries.
        let lhsTier = sidebarActivityTier(of: lhs.threads.first, in: runBadgeStateByThreadID)
        let rhsTier = sidebarActivityTier(of: rhs.threads.first, in: runBadgeStateByThreadID)
        if lhsTier != rhsTier {
            return lhsTier < rhsTier
        }

        if lhs.sortDate != rhs.sortDate {
            return lhs.sortDate > rhs.sortDate
        }

        if lhs.label != rhs.label {
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }

        return lhs.id < rhs.id
    }

    private static func threadBelongsToProjectGroup(_ thread: CodexThread, _ group: SidebarThreadGroup) -> Bool {
        guard group.kind == .project else {
            return false
        }
        if let parentSectionID = group.parentSectionID,
           thread.section?.id != parentSectionID,
           !group.threads.contains(where: { $0.id == thread.id }) {
            return false
        }

        let unscopedGroupID: String
        if let parentSectionID = group.parentSectionID {
            let sectionPrefix = "section:\(parentSectionID)/"
            unscopedGroupID = group.id.hasPrefix(sectionPrefix)
                ? String(group.id.dropFirst(sectionPrefix.count))
                : group.id
        } else {
            unscopedGroupID = group.id
        }

        guard group.includesDescendantProjectPaths,
              let projectPath = group.projectPath,
              let normalizedProjectPath = CodexThread.normalizedFilesystemProjectPath(projectPath),
              let normalizedThreadPath = CodexThread.normalizedFilesystemProjectPath(thread.projectGroupPath) else {
            return projectGroupID(for: thread) == unscopedGroupID
        }

        let normalizedThreadPathComponents = projectPathComponents(normalizedThreadPath)
        let normalizedProjectPathComponents = projectPathComponents(normalizedProjectPath)
        if isPathComponents(
            normalizedThreadPathComponents,
            sameOrDescendantOf: normalizedProjectPathComponents
        ) {
            return true
        }

        guard let worktreeTailComponents = codexManagedWorktreeTailComponents(normalizedThreadPathComponents) else {
            return false
        }

        return pathTailComponents(worktreeTailComponents, matchSuffixOf: normalizedProjectPathComponents)
    }

    private static func configuredProjectLabel(_ rawLabel: String, projectPath: String) -> String {
        let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty {
            return label
        }

        return CodexThread.projectDisplayLabel(for: projectPath)
    }

    private static func projectGroupID(forProjectPath projectPath: String) -> String {
        "project:\(projectPath)"
    }

    private static func projectGroupID(for thread: CodexThread) -> String {
        "project:\(thread.projectGroupKey)"
    }

    private static func codexManagedWorktreeTailComponents(_ components: [String]) -> [String]? {
        guard let worktreesIndex = components.firstIndex(of: "worktrees"),
              worktreesIndex > 0,
              components[worktreesIndex - 1] == ".codex" else {
            return nil
        }

        let tailStartIndex = components.index(worktreesIndex, offsetBy: 2)
        guard components.indices.contains(tailStartIndex) else {
            return nil
        }

        let tailComponents = Array(components[tailStartIndex...])
        return tailComponents.isEmpty ? nil : tailComponents
    }

    private static func pathTailComponents(
        _ tailComponents: [String],
        matchSuffixOf fullComponents: [String]
    ) -> Bool {
        guard !tailComponents.isEmpty, fullComponents.count >= tailComponents.count else {
            return false
        }

        return fullComponents.suffix(tailComponents.count).elementsEqual(tailComponents) {
            $0.localizedCaseInsensitiveCompare($1) == .orderedSame
        }
    }

    // Keeps pinned roots and their descendants together so sidebar trees do not split across sections.
    private static func collectPinnedThreads(
        from threads: [CodexThread],
        pinnedRootThreadIDs: [String]
    ) -> [CodexThread] {
        let liveThreads = threads.filter { $0.syncState != .archivedLocal }
        let threadsByID = Dictionary(uniqueKeysWithValues: liveThreads.map { ($0.id, $0) })
        let childrenByParentID = liveThreads.reduce(into: [String: [CodexThread]]()) { partialResult, thread in
            guard let parentThreadID = thread.parentThreadId else {
                return
            }
            partialResult[parentThreadID, default: []].append(thread)
        }
        var pinnedThreads: [CodexThread] = []
        var visitedThreadIDs: Set<String> = []

        for rootThreadID in pinnedRootThreadIDs {
            guard let rootThread = threadsByID[rootThreadID], !rootThread.isSubagent else {
                continue
            }

            appendPinnedSubtree(
                rootThread,
                childrenByParentID: childrenByParentID,
                into: &pinnedThreads,
                visitedThreadIDs: &visitedThreadIDs
            )
        }

        return pinnedThreads
    }

    private static func appendPinnedSubtree(
        _ thread: CodexThread,
        childrenByParentID: [String: [CodexThread]],
        into pinnedThreads: inout [CodexThread],
        visitedThreadIDs: inout Set<String>
    ) {
        guard visitedThreadIDs.insert(thread.id).inserted else {
            return
        }

        pinnedThreads.append(thread)

        for childThread in childrenByParentID[thread.id] ?? [] {
            appendPinnedSubtree(
                childThread,
                childrenByParentID: childrenByParentID,
                into: &pinnedThreads,
                visitedThreadIDs: &visitedThreadIDs
            )
        }
    }

    private static func sortThreadsByRecentActivity(
        _ threads: [CodexThread],
        runBadgeStateByThreadID: [String: CodexThreadRunBadgeState] = [:],
        viewMode: SidebarTaskViewMode = .projects
    ) -> [CodexThread] {
        threads.sorted { lhs, rhs in
            // Recency alone buries the chats the user cares about most: an orchestrating
            // run can sit idle for an hour while the worktree runs it spawned keep
            // writing, so the still-running chat would sink below its own children.
            let lhsTier = sidebarActivityTier(of: lhs, in: runBadgeStateByThreadID, viewMode: viewMode)
            let rhsTier = sidebarActivityTier(of: rhs, in: runBadgeStateByThreadID, viewMode: viewMode)
            if lhsTier != rhsTier {
                return lhsTier < rhsTier
            }
            let lhsDate = lhs.updatedAt ?? lhs.createdAt ?? .distantPast
            let rhsDate = rhs.updatedAt ?? rhs.createdAt ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return lhs.id < rhs.id
        }
    }

    // Activity puts waiting and unread work first; Projects keeps its existing
    // active-first ordering. Recency breaks ties within each tier.
    private static func sidebarActivityTier(
        of thread: CodexThread?,
        in runBadgeStateByThreadID: [String: CodexThreadRunBadgeState],
        viewMode: SidebarTaskViewMode = .projects
    ) -> Int {
        if viewMode == .activity {
            switch thread.flatMap({ runBadgeStateByThreadID[$0.id] }) {
            case .waitingOnUser: return 0
            case .ready, .failed: return 1
            case .running: return 2
            default: return 3
            }
        }
        guard let thread, let badgeState = runBadgeStateByThreadID[thread.id] else {
            return 2
        }

        switch badgeState {
        case .running, .waitingOnUser:
            return 0
        case .ready, .failed:
            return 1
        case .goalActive, .goalAttention:
            return 2
        }
    }

}
