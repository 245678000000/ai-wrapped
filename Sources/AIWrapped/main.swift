import AppKit
import SwiftUI

let args = CommandLine.arguments

func argValue(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

if args.contains("--dump") {
    CLI.dump(year: argValue("--year").flatMap(Int.init))
    exit(0)
}

if let dir = argValue("--snapshot") {
    MainActor.assumeIsolated { CLI.snapshot(to: dir, year: argValue("--year").flatMap(Int.init)) }
    exit(0)
}

if let path = argValue("--icon") {
    MainActor.assumeIsolated { CLI.renderIcon(to: path) }
    exit(0)
}

AIWrappedApp.main()
