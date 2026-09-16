// foreld — headless Forel. Same ForelCore engine, watcher and SQLite database
// as the app; rules come from a YAML file and the process runs under launchd.
import Foundation

do {
    try Foreld.main(Array(CommandLine.arguments.dropFirst()))
} catch {
    fail("\(error)")
}
