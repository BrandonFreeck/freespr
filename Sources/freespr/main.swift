import Foundation

// Entry point. Top-level code is the executable's `main` (SwiftPM convention for a
// file literally named main.swift). All real work routes through CLI.dispatch.
exit(CLI.dispatch(Array(CommandLine.arguments.dropFirst())))
