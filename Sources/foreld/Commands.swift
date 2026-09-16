import Foundation
import ForelCore
import Yams

enum Foreld {
    /// The app's database, so the GUI can open the same rules if it is ever wanted again.
    static let defaultDatabase = "~/Library/Application Support/com.lab421.forel/forel.db"

    static func main(_ argv: [String]) throws {
        let args = Arguments(argv)
        guard let command = args.positional.first else { usage() }
        let dbPath = expandPath(args.options["db"] ?? ProcessInfo.processInfo.environment["FOREL_DB"] ?? defaultDatabase)
        let operand = args.positional.dropFirst().first

        switch command {
        case "apply":
            guard let file = operand else { usage() }
            try apply(file: file, dbPath: dbPath)
        case "run":
            try run(dbPath: dbPath, force: args.flags.contains("force"))
        case "dry-run":
            guard let file = operand else { usage() }
            try dryRun(path: file, dbPath: dbPath)
        case "undo":
            guard let batch = operand else { usage() }
            try undo(batchId: batch, dbPath: dbPath)
        case "status":
            try status(dbPath: dbPath)
        case "dump":
            try dump(dbPath: dbPath)
        case "history":
            try history(dbPath: dbPath, limit: Int(args.options["limit"] ?? "") ?? 20)
        default:
            usage()
        }
    }

    // MARK: - apply

    /// Make the database match the file: folders by path, rules by name within
    /// a folder, priority = order in the file, anything absent from the file
    /// deleted. Validated up front so a bad file changes nothing.
    static func apply(file: String, dbPath: String) throws {
        let spec = try RulesLoader.load(file)

        var problems: [String] = []
        for folder in spec.folders {
            var seen: Set<String> = []
            for rule in folder.rules ?? [] {
                if !seen.insert(rule.name).inserted {
                    problems.append("\(folder.path): two rules named \"\(rule.name)\"")
                }
                let probe = RulesLoader.makeRule(rule, folderId: "probe", id: "probe", priority: 0)
                if probe.actions.isEmpty { problems.append("\(rule.name): no actions") }
                for issue in RuleValidator.validate(probe.conditions) + RuleValidator.validate(probe.actions) {
                    problems.append("\(rule.name): \(issue.message)")
                }
            }
        }
        if !problems.isEmpty {
            for problem in problems { out("  ✗ \(problem)") }
            fail("\(problems.count) problem(s) in \(file); nothing applied", code: 2)
        }

        let db = try openDatabase(dbPath)
        var report: [String] = []
        try db.withLock { db in
            let existingFolders = try db.listFolders()
            var keptFolderIds: [String] = []

            for folderSpec in spec.folders {
                let path = expandPath(folderSpec.path)
                let folder: WatchedFolder
                if let existing = existingFolders.first(where: { expandPath($0.path) == path }) {
                    folder = existing
                } else {
                    folder = WatchedFolder(path: path)
                    try db.insertFolder(folder)
                    report.append("+ folder \(path)")
                }
                keptFolderIds.append(folder.id)

                let existingRules = try db.listRules(folderId: folder.id)
                var keptRuleIds: [String] = []
                for (index, ruleSpec) in (folderSpec.rules ?? []).enumerated() {
                    let existing = existingRules.first { $0.name == ruleSpec.name }
                    let rule = RulesLoader.makeRule(
                        ruleSpec, folderId: folder.id, id: existing?.id ?? UUID().uuidString, priority: Int64(index)
                    )
                    if existing != nil {
                        try db.updateRule(rule)
                    } else {
                        try db.insertRule(rule)
                        // insertRule assigns the next free priority; pin it to the file's order.
                        try db.updateRule(rule)
                        report.append("+ rule \(ruleSpec.name)")
                    }
                    keptRuleIds.append(rule.id)
                }
                for stale in existingRules where !keptRuleIds.contains(stale.id) {
                    try db.deleteRule(stale.id)
                    report.append("- rule \(stale.name)")
                }
            }

            for stale in existingFolders where !keptFolderIds.contains(stale.id) {
                try db.deleteFolder(stale.id)
                report.append("- folder \(stale.path)")
            }
            try db.reorderFolders(keptFolderIds)
        }

        for line in report { out(line) }
        let ruleCount = spec.folders.reduce(0) { $0 + ($1.rules?.count ?? 0) }
        out("applied \(file): \(spec.folders.count) folder(s), \(ruleCount) rule(s) → \(dbPath)")
        if guiIsRunning() {
            out("note: Forel.app is running; its watcher already uses these rules, its window shows them after you switch folders or relaunch")
        }
    }

    // MARK: - run

    static func run(dbPath: String, force: Bool) throws {
        if guiIsRunning(), !force {
            fail("Forel.app is running and would act on the same events; quit it (and turn off its Launch at Login) or pass --force", code: 3)
        }
        let db = try openDatabase(dbPath)
        let coordinator = WatcherCoordinator(db: db)
        coordinator.onRuleMatched = { rule, path in
            log("match \"\(rule)\" \(path)")
        }
        coordinator.onActivity = { summary in
            log("did \(summary.actionCount) action(s) on \(summary.fileCount) file(s) via \(summary.ruleNames.joined(separator: ", "))")
        }

        let folders = try db.withLock { try $0.listFolders() }.filter(\.enabled)
        if folders.isEmpty {
            log("no watched folders in \(dbPath); run `foreld apply <rules.yml>` first")
        }
        for folder in folders {
            coordinator.add(folder.path)
            let rules = try db.withLock { try $0.listRules(folderId: folder.id) }
            log("watching \(folder.path) (\(rules.count) rule(s))")
        }
        log("foreld ready, db \(dbPath)")
        installSignalHandlers()
        withExtendedLifetime(coordinator) {
            dispatchMain()
        }
    }

    nonisolated(unsafe) private static var signalSources: [DispatchSourceSignal] = []

    private static func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                log("received signal \(sig), stopping")
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - dry-run

    static func dryRun(path: String, dbPath: String) throws {
        let file = expandPath(path)
        let db = try openDatabase(dbPath)
        guard let folder = try db.withLock({ try $0.folderForPath(file) }) else {
            fail("\(file) is not inside an enabled watched folder", code: 4)
        }
        let rules = try db.withLock { try $0.listRules(folderId: folder.id) }
        guard let depth = RuleEngine.pathDepth(root: folder.path, path: file) else {
            fail("could not place \(file) under \(folder.path)")
        }
        guard let preview = RuleEngine.previewFile(path: file, depth: depth, rules: rules) else {
            out("\(file): a system file, Forel ignores it")
            return
        }
        out("\(preview.name) in \(folder.path), depth \(depth), \(preview.rules.count) rule(s) in scope")
        for rule in preview.rules {
            out("rule \"\(rule.ruleName)\"")
            for condition in rule.conditions {
                let detail = condition.detail.map { "  (\($0))" } ?? ""
                out("  \(condition.matched ? "✓" : "✗") \(condition.kind.rawValue) \(condition.operator_.rawValue) \"\(condition.value)\"\(detail)")
            }
            for action in rule.actions {
                let target = action.targetPath.map { " → \($0)" } ?? ""
                out("  → \(action.kind.rawValue): \(action.description) [\(action.status)]\(target)")
            }
        }
    }

    // MARK: - undo

    /// Newest first, with the app's own safety check: an entry is skipped when
    /// the file has changed since Forel touched it, when two entries would
    /// restore to the same place, or when an enabled rule would act on the
    /// file again the moment it is back (the watcher would just redo the move).
    static func undo(batchId: String, dbPath: String) throws {
        let db = try openDatabase(dbPath)
        let entries = try db.withLock { try $0.listHistoryBatch(batchId) }
        let reversible = entries.filter { $0.status == .applied && $0.reversible }
        if reversible.isEmpty {
            out("nothing reversible in batch \(batchId) (\(entries.count) entries)")
            return
        }
        let colliding = UndoChecker.collidingRestoreTargets(reversible)
        var failures = 0
        for entry in reversible.reversed() {
            if colliding.contains(entry.id) {
                failures += 1
                out("✗ \(entry.originalPath): another entry in this batch restores to the same place")
                continue
            }
            let context = try db.withLock { db -> (rules: [Rule], root: String?) in
                guard let folder = try db.folderForPath(entry.originalPath), folder.enabled else { return ([], nil) }
                return (try db.listRules(folderId: folder.id).filter(\.enabled), folder.path)
            }
            switch UndoChecker.evaluate(entry, activeRules: context.rules, watchedRoot: context.root) {
            case .safe:
                do {
                    try ActionExecutor.revert(Undo.fromJSON(entry.undo))
                    try db.withLock { try $0.markHistoryUndone(entry.id) }
                    out("↩ \(entry.actionKind.rawValue) \(entry.resultPath) → \(entry.originalPath)")
                } catch {
                    failures += 1
                    out("✗ \(entry.originalPath): \(error)")
                }
            case .unsafe(let reason):
                failures += 1
                out("✗ \(entry.originalPath): \(reason)")
            default:
                failures += 1
                out("✗ \(entry.originalPath): undo checker returned an unknown verdict")
            }
        }
        if failures > 0 {
            fail("\(failures) of \(reversible.count) not undone; disable or edit the rule in rules.yml, apply, and retry", code: 5)
        }
    }

    // MARK: - dump

    /// The database as rules.yml would express it, so rules edited in the GUI
    /// can be folded back into the file. Ids are not emitted; apply matches by name.
    static func dump(dbPath: String) throws {
        let db = try openDatabase(dbPath)
        let folders = try db.withLock { try $0.listFolders() }
        var document = RulesDocument(folders: [])
        for folder in folders {
            let rules = try db.withLock { try $0.listRules(folderId: folder.id) }
            let rulesOut = rules.map { rule in
                RuleOut(
                    name: rule.name,
                    enabled: rule.enabled ? nil : false,
                    match: rule.conditionMatch == .any ? "any" : nil,
                    depth: rule.recursionDepth == 0 ? nil : (rule.recursionDepth ?? -1),
                    conditions: rule.conditions.map {
                        ConditionOut(kind: $0.kind.rawValue, op: $0.`operator`.rawValue, value: $0.value)
                    },
                    actions: rule.actions.sorted { $0.position < $1.position }.map {
                        ActionOut(kind: $0.kind.rawValue, params: $0.params)
                    }
                )
            }
            document.folders.append(FolderOut(path: (folder.path as NSString).abbreviatingWithTildeInPath, rules: rulesOut))
        }
        out(try YAMLEncoder().encode(document))
    }

    // MARK: - status / history

    static func status(dbPath: String) throws {
        let db = try openDatabase(dbPath)
        let folders = try db.withLock { try $0.listFolders() }
        out("db  \(dbPath)")
        out("gui \(guiIsRunning() ? "Forel.app is running" : "Forel.app not running")")
        for folder in folders {
            let rules = try db.withLock { try $0.listRules(folderId: folder.id) }
            out("\(folder.enabled ? "●" : "○") \(folder.path)")
            for rule in rules {
                let depth = rule.recursionDepth.map { String($0) } ?? "∞"
                out("    \(rule.enabled ? "●" : "○") \(rule.name)  [\(rule.conditionMatch.rawValue), depth \(depth), \(rule.conditions.count) condition(s), \(rule.actions.count) action(s)]")
            }
        }
    }

    static func history(dbPath: String, limit: Int) throws {
        let db = try openDatabase(dbPath)
        let entries = try db.withLock { try $0.listHistory(limit: limit) }
        for entry in entries {
            let moved = entry.resultPath != entry.originalPath ? " → \(entry.resultPath)" : ""
            out("\(entry.createdAt) \(entry.status.rawValue) \(entry.actionKind.rawValue) \"\(entry.ruleName)\" \(entry.originalPath)\(moved)  batch \(entry.batchId)")
        }
    }

    // MARK: - helpers

    private static func openDatabase(_ path: String) throws -> Database {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        return try Database(path: path)
    }

    /// The GUI binary is `ForelApp`; both processes acting on one event would double every action.
    static func guiIsRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "ForelApp"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func usage() -> Never {
        out("""
        foreld — headless Forel

          foreld apply <rules.yml>     make the database match the file (validated first; idempotent)
          foreld run [--force]         watch the enabled folders until killed; refuses while Forel.app runs
          foreld dry-run <file>        which rules would fire on one file, and what they would do
          foreld undo <batch-id>       revert one history batch (ids in `history`)
          foreld status                folders and rules currently in the database
          foreld dump                  the database as rules.yml (fold GUI edits back into the file)
          foreld history [--limit N]   recent actions

        options: --db <path>, or FOREL_DB in the environment; default \(defaultDatabase)
        """)
        exit(64)
    }
}
