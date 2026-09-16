import Foundation

/// Unbuffered so launchd's log file receives each line as it happens.
func out(_ message: String) {
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
}

func log(_ message: String) {
    out("\(timestamp()) \(message)")
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("foreld: " + message + "\n").utf8))
    exit(code)
}

private func timestamp() -> String {
    Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current))
}

/// `~`, `..` and symlinks resolved to the kernel's path (`realpath(3)`), which
/// is what FSEvents reports and what the watcher's prefix match compares
/// against. Foundation's own resolvers strip `/private` (turning
/// `/private/tmp/x` into `/tmp/x`) and a folder stored that way never sees an
/// event. Paths that do not exist yet fall back to the standardised form.
func expandPath(_ path: String) -> String {
    let expanded = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    guard let real = realpath(expanded, nil) else { return expanded }
    defer { free(real) }
    return String(cString: real)
}

/// Minimal argv handling: positionals, `--flag`, and `--key value` for the
/// few options that take a value.
struct Arguments {
    private(set) var positional: [String] = []
    private(set) var options: [String: String] = [:]
    private(set) var flags: Set<String> = []

    private static let valued: Set<String> = ["db", "limit"]

    init(_ argv: [String]) {
        var index = 0
        while index < argv.count {
            let argument = argv[index]
            if argument.hasPrefix("--") {
                let name = String(argument.dropFirst(2))
                if Self.valued.contains(name), index + 1 < argv.count {
                    options[name] = argv[index + 1]
                    index += 2
                    continue
                }
                flags.insert(name)
            } else {
                positional.append(argument)
            }
            index += 1
        }
    }
}
