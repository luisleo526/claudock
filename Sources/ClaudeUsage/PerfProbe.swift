import AppKit
import QuartzCore

/// Opt-in scroll-performance probe. Set `CLAUDOCK_PERF_LOG=/path/perf.jsonl` (or pass
/// `--perf-log /path/perf.jsonl`) to record frame intervals, long main run-loop busy
/// spans, and view-body counters as JSON lines. `--perf-scenario scroll` additionally
/// drives the demo UI (see `PerfScenario`). Off by default: every entry point returns
/// after one cached check and nothing is allocated.
enum PerfProbe {
    static let path = option("--perf-log", environment: "CLAUDOCK_PERF_LOG")
    static let scenario = option("--perf-scenario", environment: "CLAUDOCK_PERF_SCENARIO")
    static let snapshotDirectory = option("--perf-snapshots", environment: "CLAUDOCK_PERF_SNAPSHOTS")
    static let isEnabled = path != nil

    @MainActor static func start() {
        if let path, PerfRecorder.shared == nil { PerfRecorder.shared = PerfRecorder(path: path) }
        if let scenario { PerfScenario.run(scenario) }
    }

    /// Counts view-body and row evaluations; call as `let _ = PerfProbe.count("name")`.
    @MainActor @inline(__always) static func count(_ name: StaticString) {
        guard isEnabled else { return }
        PerfRecorder.shared?.count(name.description)
    }

    private static func option(_ flag: String, environment key: String) -> String? {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) { return arguments[index + 1] }
        return ProcessInfo.processInfo.environment[key].flatMap { $0.isEmpty ? nil : $0 }
    }
}

@MainActor final class PerfRecorder: NSObject {
    static var shared: PerfRecorder?

    private let handle: FileHandle
    private let writer = DispatchQueue(label: "Claudock.PerfProbe")
    private var buffer = ""
    private var counts: [String: Int] = [:]
    private var countsChanged = false
    private var displayLink: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0
    private var ticker: Timer?
    private var lastTick: CFTimeInterval = 0
    private var observer: CFRunLoopObserver?
    private var lastActivity: CFTimeInterval = 0
    private var lastActivityWasWaiting = true
    private var lastActivityCPU: UInt64 = 0
    private var flushTimer: Timer?
    private var terminationSignal: DispatchSourceSignal?
    private var activity: NSObjectProtocol?
    private var finished = false

    init?(path: String) {
        guard FileManager.default.createFile(atPath: path, contents: nil),
              let handle = FileHandle(forWritingAtPath: path) else { return nil }
        self.handle = handle
        super.init()
        // Keep App Nap from throttling timers while a measurement runs.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Claudock performance probe")
        let screen = NSScreen.main
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        let displays = NSScreen.screens.map { #"{"fps":\#($0.maximumFramesPerSecond),"asleep":\#(CGDisplayIsAsleep(($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0) != 0)}"# }
        append(#"{"type":"start","t":\#(Self.wall()),"pid":\#(getpid()),"fps":\#(screen?.maximumFramesPerSecond ?? 0),"locked":\#(locked),"displays":[\#(displays.joined(separator: ","))],"args":\#(Self.json(CommandLine.arguments))}"#)

        // Display-link frames need an awake display. The 60 Hz timer records the same
        // main-thread pacing when no vsync arrives (display asleep or screen locked).
        if let link = screen?.displayLink(target: self, selector: #selector(frame(_:))) {
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        let ticker = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in MainActor.assumeIsolated { PerfRecorder.shared?.tick() } }
        ticker.tolerance = 0
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker

        // Ordered last so each span ending in BeforeWaiting includes AppKit's display
        // cycle and the Core Animation commit. Spans from BeforeWaiting to AfterWaiting
        // are sleep, not work.
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.allActivities.rawValue, true, CFIndex.max) { _, activity in
            MainActor.assumeIsolated { PerfRecorder.shared?.runLoop(activity) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer

        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in MainActor.assumeIsolated { PerfRecorder.shared?.flush() } }
        RunLoop.main.add(timer, forMode: .common)
        flushTimer = timer

        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { PerfRecorder.shared?.finish() }; exit(0) }
        source.resume()
        terminationSignal = source
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PerfRecorder.shared?.finish() }
        }
    }

    func count(_ name: String) {
        counts[name, default: 0] += 1
        countsChanged = true
    }

    /// Marks carry the main thread's cumulative CPU time, so a phase's CPU load is exact.
    func mark(_ name: String, _ phase: String) {
        writeCounts()
        let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000
        append(#"{"type":"mark","t":\#(Self.wall()),"name":\#(Self.json(name)),"phase":"\#(phase)","cpu_ms":\#(String(format: "%.3f", cpu))}"#)
    }

    func note(_ message: String) {
        append(#"{"type":"note","t":\#(Self.wall()),"message":\#(Self.json(message))}"#)
    }

    @objc private func frame(_ link: CADisplayLink) {
        defer { lastFrame = link.timestamp }
        guard lastFrame > 0 else { return }
        append(#"{"type":"frame","t":\#(Self.wall()),"ms":\#(Self.ms(link.timestamp - lastFrame)),"nominal":\#(Self.ms(link.targetTimestamp - link.timestamp))}"#)
    }

    private func tick() {
        let now = CACurrentMediaTime()
        defer { lastTick = now }
        guard lastTick > 0 else { return }
        append(#"{"type":"tick","t":\#(Self.wall()),"ms":\#(Self.ms(now - lastTick))}"#)
    }

    /// Busy spans record wall and CPU time: a nested run loop in a private mode (for
    /// example AppKit's sheet animation) or blocking I/O shows as wall time with little CPU.
    private func runLoop(_ activity: CFRunLoopActivity) {
        let now = CACurrentMediaTime()
        let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        if !lastActivityWasWaiting && lastActivity > 0 && now - lastActivity >= 0.004 {
            append(#"{"type":"busy","t":\#(Self.wall()),"ms":\#(Self.ms(now - lastActivity)),"cpu_ms":\#(String(format: "%.3f", Double(cpu - lastActivityCPU) / 1_000_000))}"#)
        }
        lastActivityWasWaiting = activity == .beforeWaiting
        lastActivity = now
        lastActivityCPU = cpu
    }

    private func writeCounts() {
        guard countsChanged else { return }
        countsChanged = false
        let fields = counts.keys.sorted().map { "\(Self.json($0)):\(counts[$0] ?? 0)" }.joined(separator: ",")
        append(#"{"type":"counts","t":\#(Self.wall()),"c":{\#(fields)}}"#)
    }

    private func flush() {
        writeCounts()
        guard !buffer.isEmpty else { return }
        let data = Data(buffer.utf8)
        buffer = ""
        let handle = handle
        writer.async { handle.write(data) }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        displayLink?.invalidate(); displayLink = nil
        ticker?.invalidate(); ticker = nil
        flushTimer?.invalidate(); flushTimer = nil
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        countsChanged = true
        writeCounts()
        append(#"{"type":"stop","t":\#(Self.wall())}"#)
        flush()
        let handle = handle
        writer.sync { try? handle.synchronize(); try? handle.close() }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }

    private func append(_ line: String) {
        buffer += line
        buffer += "\n"
    }

    private static func wall() -> String { String(format: "%.4f", Date().timeIntervalSince1970) }
    private static func ms(_ seconds: CFTimeInterval) -> String { String(format: "%.3f", seconds * 1000) }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Drives the demo UI from inside the app, so it also runs while the screen is locked
/// or the display sleeps (external automation cannot reach windows then). It clicks with
/// ordinary mouse events and scrolls in 120 Hz steps at `CLAUDOCK_PERF_SPEED` points per
/// second (default 2400). The speed is open-loop: a stalled main thread makes the next
/// step jump further instead of stretching the pass. Scenario `scroll`: the Accounts list
/// top→bottom→top, then Manage profiles, each `CLAUDOCK_PERF_PASSES` times (default 3).
@MainActor enum PerfScenario {
    static func run(_ name: String) {
        guard name == "scroll" else { PerfRecorder.shared?.note("unknown scenario \(name)"); return }
        let passes = ProcessInfo.processInfo.environment["CLAUDOCK_PERF_PASSES"].flatMap(Int.init) ?? 3
        let speed = ProcessInfo.processInfo.environment["CLAUDOCK_PERF_SPEED"].flatMap(Double.init) ?? 2400
        Task { @MainActor in
            await scroll(passes: passes, speed: speed)
            PerfRecorder.shared?.finish()
            exit(0)
        }
    }

    private static func scroll(passes: Int, speed: Double) async {
        let recorder = PerfRecorder.shared
        guard let dashboard = await wait(timeout: 15, { NSApp.windows.first { $0.isVisible && !$0.isSheet && $0.title == "Claudock" } }) else {
            recorder?.note("dashboard window did not appear"); return
        }
        await sleep(2)
        // Snapshots are taken outside measured phases; rendering one blocks the main thread.
        snapshot(dashboard, name: "accounts")
        await sleep(0.5)
        recorder?.mark("accounts-idle", "begin")
        await sleep(3)
        recorder?.mark("accounts-idle", "end")
        guard let accounts = mostScrollable(in: dashboard) else { recorder?.note("accounts list not found"); return }
        recorder?.mark("accounts-scroll", "begin")
        for _ in 0..<passes {
            await scroll(accounts, toBottom: true, speed: speed)
            await scroll(accounts, toBottom: false, speed: speed)
        }
        recorder?.mark("accounts-scroll", "end")

        recorder?.mark("manager-open", "begin")
        // The footer's Manage profiles button sits 24 pt from the left edge, centered 20 pt above the bottom.
        click(NSPoint(x: 60, y: 20), in: dashboard)
        if await wait(timeout: 1, { dashboard.attachedSheet }) == nil { click(NSPoint(x: 60, y: 20), in: dashboard) }
        guard let sheet = await wait(timeout: 10, { dashboard.attachedSheet }) else { recorder?.note("Manage profiles sheet did not appear"); return }
        await sleep(3)
        recorder?.mark("manager-open", "end")
        guard let profiles = mostScrollable(in: sheet) else { recorder?.note("profile list not found"); return }
        snapshot(sheet, name: "manager")
        await sleep(0.5)
        recorder?.mark("manager-scroll", "begin")
        for _ in 0..<passes {
            await scroll(profiles, toBottom: true, speed: speed)
            await scroll(profiles, toBottom: false, speed: speed)
        }
        recorder?.mark("manager-scroll", "end")
        await sleep(1)
    }

    /// One continuous gesture from the current position to an end of the list. Moves the
    /// clip view the way NSScrollView applies each scroll-wheel delta, posting the same
    /// live-scroll notifications; this path does not depend on display refresh, so it
    /// also works while the display sleeps.
    private static func scroll(_ scrollView: NSScrollView, toBottom: Bool, speed: Double) async {
        let clip = scrollView.contentView
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        let start = CACurrentMediaTime()
        var last = start
        var settledTicks = 0
        while CACurrentMediaTime() - start < 30 {
            await sleep(1.0 / 120)
            let now = CACurrentMediaTime()
            let distance = speed * (now - last)
            last = now
            let limit = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
            var origin = clip.bounds.origin
            let target = min(max(0, origin.y + (toBottom ? distance : -distance)), limit)
            settledTicks = abs(target - origin.y) < 0.5 ? settledTicks + 1 : 0
            if settledTicks >= 12 { break }
            origin.y = target
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)
        }
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
        await sleep(0.25)
    }

    /// Clicks a point given in the window's coordinate space with ordinary mouse events.
    private static func click(_ point: NSPoint, in window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { continue }
            NSApp.sendEvent(event)
        }
    }

    private static func mostScrollable(in window: NSWindow) -> NSScrollView? {
        var found: [NSScrollView] = []
        var stack = window.contentView.map { [$0] } ?? []
        while let view = stack.popLast() {
            if let scrollView = view as? NSScrollView { found.append(scrollView) }
            stack.append(contentsOf: view.subviews)
        }
        return found.max { range($0) < range($1) }.flatMap { range($0) > 0 ? $0 : nil }
    }

    private static func range(_ scrollView: NSScrollView) -> CGFloat {
        (scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height
    }

    private static func snapshot(_ window: NSWindow, name: String) {
        guard let directory = PerfProbe.snapshotDirectory, let view = window.contentView?.superview ?? window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
    }

    private static func wait<T>(timeout: TimeInterval, _ condition: () -> T?) async -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = condition() { return value }
            await sleep(0.1)
        }
        return nil
    }

    private static func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
