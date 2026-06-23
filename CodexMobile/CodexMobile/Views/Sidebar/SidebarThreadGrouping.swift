// FILE: SidebarThreadGrouping.swift
// Purpose: Produces sidebar thread groups by project path (`cwd`) or rootless
//          chat scope while excluding archived chats.
// Layer: View Helper
// Exports: SidebarThreadGroupKind, SidebarContentScope, SidebarThreadGroup,
//          SidebarThreadGrouping

import Foundation

enum SidebarThreadGroupKind: Equatable {
    case pinned
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

enum SidebarThreadGroupingScope {
    case all
    case projects
    case chats
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
    var includesDescendantProjectPaths = false

    var iconSystemName: String {
        switch kind {
        case .pinned:
            return "pin"
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
    static func makeGroups(
        from threads: [CodexThread],
        pinnedThreadIDs: [String] = [],
        scope: SidebarThreadGroupingScope = .all,
        projectlessRootPaths: [String] = [],
        projectSource: SidebarProjectSource = .recentThreadProjects,
        configuredProjectChoices: [SidebarProjectChoice] = [],
        now _: Date = Date(),
        calendar _: Calendar = .current
    ) -> [SidebarThreadGroup] {
        var groups: [SidebarThreadGroup] = []
        let scopedThreads = threadsForScope(scope, from: threads, projectlessRootPaths: projectlessRootPaths)
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
        case .all:
            let projectThreads = threadsForScope(.projects, from: scopedThreads, projectlessRootPaths: projectlessRootPaths)
            let chatThreads = threadsForScope(.chats, from: scopedThreads, projectlessRootPaths: projectlessRootPaths)
            groups.append(contentsOf: makeProjectGroups(
                from: projectThreads,
                excludingPinnedThreadIDs: pinnedThreadIDSet,
                projectSource: projectSource,
                configuredProjectChoices: configuredProjectChoices
            ))
            if let chatGroup = makeRootlessChatGroup(from: chatThreads, excludingPinnedThreadIDs: pinnedThreadIDSet) {
                groups.append(chatGroup)
            }
        case .projects:
            groups.append(contentsOf: makeProjectGroups(
                from: scopedThreads,
                excludingPinnedThreadIDs: pinnedThreadIDSet,
                projectSource: projectSource,
                configuredProjectChoices: configuredProjectChoices
            ))
        case .chats:
            if let chatGroup = makeRootlessChatGroup(from: scopedThreads, excludingPinnedThreadIDs: pinnedThreadIDSet) {
                groups.append(chatGroup)
            }
        }

        return groups
    }

    // Keeps the UI picker from leaking project chats into rootless Chats and vice versa.
    static func threadsForScope(
        _ scope: SidebarThreadGroupingScope,
        from threads: [CodexThread],
        projectlessRootPaths: [String] = []
    ) -> [CodexThread] {
        switch scope {
        case .all:
            return threads
        case .projects:
            return threads.filter { !isRootlessChatThread($0, projectlessRootPaths: projectlessRootPaths) }
        case .chats:
            return threads.filter { isRootlessChatThread($0, projectlessRootPaths: projectlessRootPaths) }
        }
    }

    // Projectless chats still receive generated host-side working directories,
    // so rootless detection cannot rely on cwd == nil alone.
    static func isRootlessChatThread(
        _ thread: CodexThread,
        projectlessRootPaths: [String] = []
    ) -> Bool {
        thread.normalizedProjectPath == nil
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

    private static func makeProjectGroup(projectKey: String, threads: [CodexThread]) -> SidebarThreadGroup {
        let sortedThreads = sortThreadsByRecentActivity(threads)
        let representativeThread = sortedThreads.first
        let sortDate = representativeThread?.updatedAt ?? representativeThread?.createdAt ?? .distantPast
        return SidebarThreadGroup(
            id: "project:\(projectKey)",
            label: representativeThread?.projectDisplayName ?? CodexThread.noProjectDisplayName,
            kind: .project,
            sortDate: sortDate,
            projectPath: representativeThread?.normalizedProjectPath,
            threads: sortedThreads
        )
    }

    private static func makeConfiguredProjectGroup(
        projectPath: String,
        label: String,
        sortDate: Date,
        threads: [CodexThread]
    ) -> SidebarThreadGroup {
        let sortedThreads = sortThreadsByRecentActivity(threads)
        let latestThread = sortedThreads.first
        return SidebarThreadGroup(
            id: projectGroupID(forProjectPath: projectPath),
            label: configuredProjectLabel(label, projectPath: projectPath),
            kind: .project,
            sortDate: latestThread?.updatedAt ?? latestThread?.createdAt ?? sortDate,
            projectPath: projectPath,
            threads: sortedThreads,
            includesDescendantProjectPaths: true
        )
    }

    private static func makeRootlessChatGroup(
        from threads: [CodexThread],
        excludingPinnedThreadIDs pinnedThreadIDs: Set<String>
    ) -> SidebarThreadGroup? {
        let liveThreads = threads.filter {
            $0.syncState != .archivedLocal && !pinnedThreadIDs.contains($0.id)
        }
        let sortedThreads = sortThreadsByRecentActivity(liveThreads)
        guard let firstThread = sortedThreads.first else {
            return nil
        }

        return SidebarThreadGroup(
            id: "chats:rootless",
            label: "Chats",
            kind: .chat,
            sortDate: firstThread.updatedAt ?? firstThread.createdAt ?? .distantPast,
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
        configuredProjectChoices: [SidebarProjectChoice] = []
    ) -> [SidebarThreadGroup] {
        var liveThreadsByProject: [String: [CodexThread]] = [:]
        let configuredProjectScopes = normalizedConfiguredProjectScopes(configuredProjectChoices)

        for thread in threads where thread.syncState != .archivedLocal {
            guard !pinnedThreadIDs.contains(thread.id) else {
                continue
            }
            if projectSource == .configuredProjects {
                guard let configuredProjectScope = configuredProjectScope(
                    containing: thread.projectKey,
                    scopes: configuredProjectScopes
                ) else {
                    continue
                }
                liveThreadsByProject[configuredProjectScope.projectPath, default: []].append(thread)
            } else {
                liveThreadsByProject[thread.projectKey, default: []].append(thread)
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
                    threads: projectThreads
                )
                return (group.id, group)
            })
        } else {
            groupsByID = Dictionary(uniqueKeysWithValues: liveThreadsByProject.map { projectKey, projectThreads in
                let group = makeProjectGroup(projectKey: projectKey, threads: projectThreads)
                return (group.id, group)
            })
        }

        if projectSource == .configuredProjects {
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
            let configuredOrderByGroupID = Dictionary(uniqueKeysWithValues: configuredProjectScopes.map {
                (projectGroupID(forProjectPath: $0.projectPath), $0.order)
            })
            return groupsByID.values.sorted { lhs, rhs in
                let lhsOrder = configuredOrderByGroupID[lhs.id] ?? Int.max
                let rhsOrder = configuredOrderByGroupID[rhs.id] ?? Int.max
                if lhsOrder != rhsOrder {
                    return lhsOrder < rhsOrder
                }

                return compareProjectGroupsByRecentActivity(lhs, rhs)
            }
        }

        return groupsByID.values.sorted { lhs, rhs in
            compareProjectGroupsByRecentActivity(lhs, rhs)
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

        return scopes
            .filter { isPathComponents(pathComponents, sameOrDescendantOf: $0.pathComponents) }
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

    private static func compareProjectGroupsByRecentActivity(_ lhs: SidebarThreadGroup, _ rhs: SidebarThreadGroup) -> Bool {
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
        guard group.includesDescendantProjectPaths,
              let projectPath = group.projectPath,
              let normalizedProjectPath = CodexThread.normalizedFilesystemProjectPath(projectPath),
              let normalizedThreadPath = CodexThread.normalizedFilesystemProjectPath(thread.projectKey) else {
            return projectGroupID(for: thread) == group.id
        }

        return isPathComponents(
            projectPathComponents(normalizedThreadPath),
            sameOrDescendantOf: projectPathComponents(normalizedProjectPath)
        )
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
        projectGroupID(forProjectPath: thread.projectKey)
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
            guard let rootThread = threadsByID[rootThreadID] else {
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

    private static func sortThreadsByRecentActivity(_ threads: [CodexThread]) -> [CodexThread] {
        threads.sorted { lhs, rhs in
            let lhsDate = lhs.updatedAt ?? lhs.createdAt ?? .distantPast
            let rhsDate = rhs.updatedAt ?? rhs.createdAt ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return lhs.id < rhs.id
        }
    }

}
