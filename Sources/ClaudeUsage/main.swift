import AppKit
import UsageCore

if CommandLine.arguments.contains("--diagnose") || CommandLine.arguments.contains("--discover") || CommandLine.arguments.contains("--analytics") {
    let discoverOnly = CommandLine.arguments.contains("--discover")
    Task {
        let profiles: [Profile]
        do { profiles = try ProfileStore.load() }
        catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
        if CommandLine.arguments.contains("--analytics") {
            let since = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date()))!
            let args = CommandLine.arguments
            var through = Date()
            if let index = args.firstIndex(of: "--through"), args.indices.contains(index + 1), let date = UsageSnapshot.parseDate(args[index + 1]) { through = date }
            let fixed = through
            let result = await Task.detached { SessionAnalytics.scan(profiles: profiles, since: since, now: fixed) }.value
            print("Recorded local tokens: \(result.totals.total); sessions: \(result.sessions.count); partial: \(result.truncated); files: \(result.scannedFiles)/\(result.eligibleFiles); bytes: \(result.scannedBytes)")
            print("Input: \(result.totals.input); output: \(result.totals.output); cache read: \(result.totals.cacheRead); cache write: \(result.totals.cacheWrite)")
            for profile in result.profiles { print("\(profile.command): \(profile.tokens.total) tokens") }
            exit(0)
        }
        for profile in profiles {
            if discoverOnly {
                print("\(profile.command) | \(profile.configDirectory) | \(profile.discoveryNote ?? (profile.isVertex ? "Vertex" : "subscription"))")
            } else {
                let result = await Task.detached { await readAccount(profile) }.value
                let windows = result.snapshot?.windows.map { "\($0.title)=\(Int($0.percent))%" }.joined(separator: ", ")
                print("\(profile.command): \(windows ?? result.error?.localizedDescription ?? "Unavailable")")
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        exit(0)
    }
    RunLoop.main.run()
} else {
    let app = NSApplication.shared
    let delegate = MainActor.assumeIsolated { AppDelegate() }
    app.delegate = delegate
    app.run()
}
