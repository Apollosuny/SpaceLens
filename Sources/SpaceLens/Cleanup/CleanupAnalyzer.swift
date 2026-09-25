import Foundation

/// One folder or file a rule matched, with the space it would free. Items nested in another rule's
/// item (Homebrew's cache inside the app caches, a backup inside app data) are only counted by the
/// innermost one, so sizes add up across the report.
struct CleanupItem: Sendable {
    let node: FileNode
    let logicalSize: Int64
    let allocatedSize: Int64

    func size(for metric: SizeMetric) -> Int64 {
        metric == .allocatedSize ? allocatedSize : logicalSize
    }
}

/// A rule and everything it matched in the scan, largest item first.
struct CleanupFinding: Identifiable, Sendable {
    let rule: CleanupRule
    let items: [CleanupItem]
    let logicalSize: Int64
    let allocatedSize: Int64

    var id: String { rule.id }

    func size(for metric: SizeMetric) -> Int64 {
        metric == .allocatedSize ? allocatedSize : logicalSize
    }
}

/// What the cleanup rules say about one node.
struct CleanupVerdict: Sendable {
    enum Scope: Sendable {
        /// The node is an item of the rule.
        case item
        /// The node is a folder whose entries are the rule's items (such as `~/Library/Caches`).
        case container
        /// The node lies inside `item`.
        case inside(item: FileNode)
    }

    let rule: CleanupRule
    let scope: Scope
}

/// The outcome of applying a ruleset to a scanned tree.
struct CleanupReport: Sendable {
    /// Sorted by risk, then by physical size.
    let findings: [CleanupFinding]
    private let ruleByItem: [ObjectIdentifier: CleanupRule]
    private let ruleByContainer: [ObjectIdentifier: CleanupRule]

    init(findings: [CleanupFinding], ruleByItem: [ObjectIdentifier: CleanupRule], ruleByContainer: [ObjectIdentifier: CleanupRule]) {
        self.findings = findings
        self.ruleByItem = ruleByItem
        self.ruleByContainer = ruleByContainer
    }

    func findings(for risk: CleanupRisk) -> [CleanupFinding] {
        findings.filter { $0.rule.risk == risk }
    }

    func totalSize(for risk: CleanupRisk, metric: SizeMetric) -> Int64 {
        findings(for: risk).reduce(0) { $0 + $1.size(for: metric) }
    }

    /// The rule covering `node`: its own item, the container it is, or the nearest item it lies in.
    func verdict(for node: FileNode) -> CleanupVerdict? {
        if let rule = ruleByItem[ObjectIdentifier(node)] { return CleanupVerdict(rule: rule, scope: .item) }
        if let rule = ruleByContainer[ObjectIdentifier(node)] { return CleanupVerdict(rule: rule, scope: .container) }
        var ancestor = node.parent
        while let current = ancestor {
            if let rule = ruleByItem[ObjectIdentifier(current)] {
                return CleanupVerdict(rule: rule, scope: .inside(item: current))
            }
            ancestor = current.parent
        }
        return nil
    }
}

/// Applies a `CleanupRuleset` to a scanned tree. Pure and synchronous; run it off the main actor.
struct CleanupAnalyzer: Sendable {
    let ruleset: CleanupRuleset
    /// The reference time for age rules.
    let now: Date

    init(ruleset: CleanupRuleset = .default(), now: Date = .now) {
        self.ruleset = ruleset
        self.now = now
    }

    /// Returns nil when the surrounding task is cancelled.
    func analyze(_ root: FileNode) -> CleanupReport? {
        var claims = Claims()
        claimPaths(in: root, claims: &claims)
        guard matchFilePatterns(in: root, claims: &claims) else { return nil }
        return makeReport(from: claims)
    }

    // MARK: - Path rules

    private struct Claims {
        /// Items in the order they were claimed.
        var items: [(node: FileNode, rule: CleanupRule)] = []
        var ruleByItem: [ObjectIdentifier: CleanupRule] = [:]
        var ruleByContainer: [ObjectIdentifier: CleanupRule] = [:]

        func isClaimed(_ node: FileNode) -> Bool { ruleByItem[ObjectIdentifier(node)] != nil }

        mutating func claim(_ node: FileNode, for rule: CleanupRule) {
            guard !isClaimed(node) else { return }
            items.append((node, rule))
            ruleByItem[ObjectIdentifier(node)] = rule
        }
    }

    /// Claims the items of `.item` and `.contents` matchers, deepest path first, so the most specific rule
    /// owns a folder (Homebrew's cache before the app caches around it).
    private func claimPaths(in root: FileNode, claims: inout Claims) {
        let rootPath = Self.normalized(root.path)
        let pathMatchers: [(path: String, matcher: CleanupMatcher, rule: CleanupRule)] = ruleset.rules.flatMap { rule in
            rule.matchers.compactMap { matcher -> (String, CleanupMatcher, CleanupRule)? in
                switch matcher {
                case .item(let path), .contents(of: let path, minAgeDays: _): (Self.normalized(path), matcher, rule)
                case .files: nil
                }
            }
        }
        let deepestFirst = pathMatchers.enumerated().sorted { lhs, rhs in
            let lhsDepth = lhs.element.path.split(separator: "/").count
            let rhsDepth = rhs.element.path.split(separator: "/").count
            return lhsDepth != rhsDepth ? lhsDepth > rhsDepth : lhs.offset < rhs.offset
        }.map(\.element)

        for (path, matcher, rule) in deepestFirst {
            if Self.isAncestor(path, of: rootPath) {
                // The whole scan lies inside the matched folder (or inside one of its entries).
                switch matcher {
                case .item, .contents(of: _, minAgeDays: nil): claims.claim(root, for: rule)
                default: break
                }
                continue
            }
            guard let node = Self.node(at: path, in: root, rootPath: rootPath) else { continue }
            switch matcher {
            case .item:
                claims.claim(node, for: rule)
            case .contents(of: _, let minAgeDays):
                if claims.ruleByContainer[ObjectIdentifier(node)] == nil {
                    claims.ruleByContainer[ObjectIdentifier(node)] = rule
                }
                for child in node.children where isOldEnough(child, minAgeDays: minAgeDays) {
                    claims.claim(child, for: rule)
                }
            case .files:
                break
            }
        }
    }

    private func isOldEnough(_ node: FileNode, minAgeDays: Int?) -> Bool {
        guard let minAgeDays else { return true }
        guard node.modificationTime > 0 else { return false }
        let age = now.timeIntervalSince1970 - TimeInterval(node.modificationTime)
        return age >= TimeInterval(minAgeDays) * 86_400
    }

    // MARK: - File patterns

    /// Matches file patterns everywhere except inside claimed items (which covers every protected area)
    /// and packages. Returns false when cancelled.
    private func matchFilePatterns(in root: FileNode, claims: inout Claims) -> Bool {
        let patternRules: [(pattern: CleanupFilePattern, rule: CleanupRule)] = ruleset.rules.flatMap { rule in
            rule.matchers.compactMap { matcher in
                if case .files(let pattern) = matcher { (pattern, rule) } else { nil }
            }
        }
        guard !patternRules.isEmpty, !claims.isClaimed(root) else { return true }

        var stack = [root]
        var visited = 0
        while let node = stack.popLast() {
            visited += 1
            if visited.isMultiple(of: 4096) && Task.isCancelled { return false }

            if node.isDirectory {
                if node !== root && isPackage(node) { continue }
                for child in node.children where !claims.isClaimed(child) {
                    stack.append(child)
                }
            } else if let match = patternRules.first(where: { matches(node, $0.pattern) }) {
                claims.claim(node, for: match.rule)
            }
        }
        return true
    }

    private func isPackage(_ node: FileNode) -> Bool {
        guard let fileExtension = Self.fileExtension(of: node.name) else { return false }
        return ruleset.packageExtensions.contains(fileExtension)
    }

    private func matches(_ file: FileNode, _ pattern: CleanupFilePattern) -> Bool {
        guard file.totalSize >= pattern.minSize else { return false }
        if let category = pattern.category, file.category != category { return false }
        if !pattern.extensions.isEmpty {
            guard let fileExtension = Self.fileExtension(of: file.name), pattern.extensions.contains(fileExtension) else { return false }
        }
        return true
    }

    // MARK: - Report

    private func makeReport(from claims: Claims) -> CleanupReport {
        // Exclusive sizes: each item's totals minus the items nested directly inside it.
        var logical: [ObjectIdentifier: Int64] = [:]
        var allocated: [ObjectIdentifier: Int64] = [:]
        for (node, _) in claims.items {
            logical[ObjectIdentifier(node)] = node.totalSize
            allocated[ObjectIdentifier(node)] = node.totalAllocatedSize
        }
        for (node, _) in claims.items {
            var ancestor = node.parent
            while let current = ancestor {
                let id = ObjectIdentifier(current)
                if claims.ruleByItem[id] != nil {
                    logical[id, default: 0] -= node.totalSize
                    allocated[id, default: 0] -= node.totalAllocatedSize
                    break
                }
                ancestor = current.parent
            }
        }

        var itemsByRule: [String: [CleanupItem]] = [:]
        for (node, rule) in claims.items {
            let id = ObjectIdentifier(node)
            let item = CleanupItem(node: node, logicalSize: max(0, logical[id] ?? 0), allocatedSize: max(0, allocated[id] ?? 0))
            guard item.logicalSize > 0 || item.allocatedSize > 0 else { continue }
            itemsByRule[rule.id, default: []].append(item)
        }

        let findings = ruleset.rules.compactMap { rule -> CleanupFinding? in
            guard let items = itemsByRule[rule.id], !items.isEmpty else { return nil }
            return CleanupFinding(
                rule: rule,
                items: items.sorted { $0.allocatedSize > $1.allocatedSize },
                logicalSize: items.reduce(0) { $0 + $1.logicalSize },
                allocatedSize: items.reduce(0) { $0 + $1.allocatedSize }
            )
        }
        .sorted { $0.rule.risk != $1.rule.risk ? $0.rule.risk < $1.rule.risk : $0.allocatedSize > $1.allocatedSize }

        return CleanupReport(findings: findings, ruleByItem: claims.ruleByItem, ruleByContainer: claims.ruleByContainer)
    }

    // MARK: - Paths

    private static func normalized(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Whether `path` is a proper ancestor of `descendant`.
    private static func isAncestor(_ path: String, of descendant: String) -> Bool {
        guard path != descendant else { return false }
        return path == "/" || descendant.hasPrefix(path + "/")
    }

    /// The node at absolute `path` when it lies at or below the scan root.
    private static func node(at path: String, in root: FileNode, rootPath: String) -> FileNode? {
        if path == rootPath { return root }
        guard isAncestor(rootPath, of: path) else { return nil }
        let relative = path.dropFirst(rootPath == "/" ? 1 : rootPath.count + 1)
        var node = root
        for component in relative.split(separator: "/") {
            guard let child = node.children.first(where: { $0.name == component }) else { return nil }
            node = child
        }
        return node
    }

    private static func fileExtension(of name: String) -> String? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let fileExtension = name[name.index(after: dot)...]
        return fileExtension.isEmpty ? nil : fileExtension.lowercased()
    }
}
