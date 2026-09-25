import AppKit
import CryptoKit
import UsageCore

if CommandLine.arguments.contains("--diagnose") || CommandLine.arguments.contains("--discover") || CommandLine.arguments.contains("--analytics") {
    let discoverOnly = CommandLine.arguments.contains("--discover")
    Task {
        var profiles: [Profile]
        do { profiles = try ProfileStore.load() }
        catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
        // --analytics --config DIR scans one fixed config folder instead, e.g. a frozen copy.
        if let index = CommandLine.arguments.firstIndex(of: "--config"), CommandLine.arguments.indices.contains(index + 1) {
            profiles = [Profile(command: "claude-config", configDirectory: CommandLine.arguments[index + 1])]
        }
        if CommandLine.arguments.contains("--analytics") {
            // Read-only: scans local session logs of the registered profiles; no Keychain or network.
            // --days N (default 7) and --repeat N (default 1) time repeated scans of one frozen window.
            let args = CommandLine.arguments
            func option(_ name: String) -> String? {
                args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            }
            let days = max(1, option("--days").flatMap(Int.init) ?? 7)
            let repeats = max(1, option("--repeat").flatMap(Int.init) ?? 1)
            let since = Calendar.current.date(byAdding: .day, value: -(days - 1), to: Calendar.current.startOfDay(for: Date()))!
            var through = Date()
            if let text = option("--through"), let date = UsageSnapshot.parseDate(text) { through = date }
            let fixed = through
            // --incremental reuses a scan cache (--cache PATH, default: the app's cache file).
            let cache = args.contains("--incremental")
                ? SessionAnalyticsCache(url: option("--cache").map { URL(fileURLWithPath: $0) } ?? SessionAnalyticsCache.defaultURL) : nil
            for run in 1...repeats {
                let meter = ScanMeter()
                let result = await Task.detached { SessionAnalytics.scan(profiles: profiles, since: since, now: fixed, cache: cache) }.value
                let usage = meter.finish()
                if run == 1 {
                    print("Recorded local tokens: \(result.totals.total); sessions: \(result.sessions.count); partial: \(result.truncated); files: \(result.scannedFiles)/\(result.eligibleFiles); bytes: \(result.scannedBytes)")
                    print("Input: \(result.totals.input); output: \(result.totals.output); cache read: \(result.totals.cacheRead); cache write: \(result.totals.cacheWrite)")
                    for profile in result.profiles { print("\(profile.command): \(profile.tokens.total) tokens") }
                }
                if args.contains("--repeat") || args.contains("--days") {
                    var dump = ""
                    Swift.dump(result, to: &dump)
                    let hash = SHA256.hash(data: Data(dump.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
                    let read = cache.map { String(format: ", read %.1f MB", Double($0.lastReadBytes) / 1_048_576) } ?? ""
                    let size = (cache?.url).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
                        .map { String(format: ", cache file %.1f MB", Double($0) / 1_048_576) } ?? ""
                    print(String(format: "scan %d (%d days): wall %.2f s, cpu %.2f s, peak footprint %.0f MB, max RSS %.0f MB%@%@, snapshot %@",
                                 run, days, usage.wall, usage.cpu, usage.peakFootprintMB, usage.maxRSSMB, read, size, hash))
                }
            }
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

/// Wall and CPU time of one scan, with the peak memory footprint sampled every 10 ms.
final class ScanMeter: @unchecked Sendable {
    private let started = Date()
    private let startedCPU = ScanMeter.cpuSeconds()
    private let lock = NSLock()
    private var peak: UInt64 = 0
    private let sampler = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))

    init() {
        sampler.schedule(deadline: .now(), repeating: .milliseconds(10))
        sampler.setEventHandler { [weak self] in self?.sample() }
        sampler.resume()
    }

    func finish() -> (wall: Double, cpu: Double, peakFootprintMB: Double, maxRSSMB: Double) {
        sampler.cancel()
        sample()
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        lock.lock(); defer { lock.unlock() }
        return (Date().timeIntervalSince(started), ScanMeter.cpuSeconds() - startedCPU,
                Double(peak) / 1_048_576, Double(usage.ru_maxrss) / 1_048_576)
    }

    private func sample() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard status == KERN_SUCCESS else { return }
        lock.lock(); peak = max(peak, info.phys_footprint); lock.unlock()
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}
