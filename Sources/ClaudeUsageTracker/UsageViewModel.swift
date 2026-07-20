import Foundation
import SwiftUI
import UserNotifications
import AppKit  // for NSWorkspace.shared.runningApplications
import os.log

@MainActor
final class UsageViewModel: ObservableObject {
    @Published var usage: MonthlyUsage?
    @Published var statsCache: StatsCache?
    @Published var lastUpdated: Date = .now
    @Published var apiUsage: UsageAPIResponse?
    @Published var apiDataSource: DataSource = .fileOnly
    @Published var statusMessage: String?

    enum DataSource { case api, fileOnly }

    /// Hint for token details toggle when no data is available
    var tokenDataHint: String? {
        let claudeDir = Self.claudeDir
        if !FileManager.default.fileExists(atPath: claudeDir + "/statusline.sh") {
            return "Re-run install.sh to set up token tracking"
        }
        if !FileManager.default.fileExists(atPath: Self.usageFilePath) {
            return "Start a Claude Code session for token data"
        }
        if usage == nil {
            return "Waiting for Claude Code session data..."
        }
        return nil
    }

    private var apiClient = UsageAPIClient()
    // Weak handle to the OAuth manager (when authed via OAuth) so failure handling
    // can distinguish a transient keychain-locked state from a real auth failure.
    private weak var oauthManager: OAuthManager?
    private var apiPollingTask: Task<Void, Never>?
    // Bumped each time a polling loop is launched. A loop only tears down shared
    // state (apiPollingTask / sleepWakeContinuation) if it still owns the current
    // generation — otherwise a stopAndReset()+start() cycle (e.g. connectOAuth)
    // would let the cancelled old loop's deferred cleanup clobber the new loop's
    // task handle (→ duplicate concurrent polling) and orphan its parked sleep.
    private var pollingGeneration = 0
    private static let activePollInterval: TimeInterval = 60   // base: 1 min between API calls (active)
    private var pollInterval: TimeInterval = activePollInterval
    private let idlePollInterval: TimeInterval = 300      // 5 min between API calls (idle)
    private let cooldownThreshold: TimeInterval = 300     // 5 min after last activity → switch to idle rate
    private let activityWindow: TimeInterval = 300        // file mtime/process age that still counts as "active" (matches cooldown)
    private let staleDataThreshold: TimeInterval = 900    // 15 min — drop API data if no successful fetch
    private let apiBackoffCap: TimeInterval = 900         // max backoff for rate limiting
    private var lastActivityTime: Date = .distantPast     // when Claude was last used
    private var lastAPISuccessTime: Date?                 // when API last returned 200
    private var lastFileUpdateTime: Date?                 // when monthly_usage.json was last successfully decoded
    private var extraTokenSnapshots: ExtraTokenSnapshots

    // Wake signal: a wake (CLI/file/process activity) resumes any continuation the
    // poll loop is parked on, interrupting the in-flight sleep so the next fetch
    // happens immediately instead of after the remaining poll interval.
    private var sleepWakeContinuation: CheckedContinuation<Void, Never>?
    private var wakePending = false   // set if a wake arrives while the loop is mid-fetch (not yet parked)

    // Velocity tracking: store recent percentage readings to estimate time-to-limit
    private struct PercentageReading {
        let value: Double
        let timestamp: Date
    }
    private var fiveHourReadings: [PercentageReading] = []
    private var weekReadings: [PercentageReading] = []
    private static let maxReadings = 20 // keep last 20 readings
    private static let minReadingInterval: TimeInterval = 30 // at least 30s between readings

    private static let log = Logger(subsystem: "com.beniamincostas.ClaudeUsageTracker", category: "UsageViewModel")

    private var usageFileWatcher: FileWatcher?
    private var statsFileWatcher: FileWatcher?
    private var countdownTimer: DispatchSourceTimer?

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()

    private static let claudeDir: String = {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.claude"
    }()
    private static let usageFilePath: String = { claudeDir + "/monthly_usage.json" }()
    private static let statsCachePath: String = { claudeDir + "/stats-cache.json" }()

    private static let consentKey = "keychainAccessApproved"

    static var hasConsent: Bool {
        UserDefaults.standard.bool(forKey: consentKey)
    }

    init() {
        self.extraTokenSnapshots = ExtraTokenSnapshots.load()

        // Only start monitoring after consent is granted
        if Self.hasConsent {
            start()
        }
    }

    /// Connect with OAuthManager — replaces Keychain-based token reading.
    func connectOAuth(_ manager: OAuthManager) {
        stopAndReset()  // #7: cancel old polling before switching token source
        oauthManager = manager
        apiClient = UsageAPIClient(oauthManager: manager)
        start()
    }

    /// Stop all monitoring and reset API client — used on logout/switch.
    func stopAndReset() {
        apiPollingTask?.cancel()
        apiPollingTask = nil
        // Resume any parked sleep so the cancelled loop unblocks and exits cleanly.
        sleepWakeContinuation?.resume()
        sleepWakeContinuation = nil
        wakePending = false
        countdownTimer?.cancel()
        countdownTimer = nil
        usageFileWatcher?.stop()
        usageFileWatcher = nil
        statsFileWatcher?.stop()
        statsFileWatcher = nil
        apiClient = UsageAPIClient()
        oauthManager = nil
        apiUsage = nil
        apiDataSource = .fileOnly
    }

    /// Begin all monitoring — call only after user consent/login is confirmed.
    func start() {
        loadUsageData()
        loadStatsCache()
        setupFileWatchers()
        setupCountdownTimer()
        startAPIPolling()
    }

    // MARK: - Rate Limit Percentage

    struct RateLimitPercentage {
        let value: Double
        let isEstimated: Bool
    }

    // MARK: - Data Loading

    func loadUsageData() {
        guard let data = FileManager.default.contents(atPath: Self.usageFilePath) else { return }
        do {
            usage = try JSONDecoder().decode(MonthlyUsage.self, from: data)
            lastUpdated = .now
            lastFileUpdateTime = .now
            checkAndNotify()
            updateExtraTokenTracking()
            recordPercentageReading()
            wakeAPIPolling() // CLI activity detected → wake up API polling
        } catch {
            // Keep previous state on parse error — surface to os_log so a half-written
            // monthly_usage.json (statusline.sh crash, atomic-rename race) is visible
            // instead of silently freezing the UI on stale data.
            Self.log.error("Failed to decode monthly_usage.json at \(Self.usageFilePath, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    func loadStatsCache() {
        guard let data = FileManager.default.contents(atPath: Self.statsCachePath) else { return }
        do {
            statsCache = try JSONDecoder().decode(StatsCache.self, from: data)
        } catch {
            Self.log.error("Failed to decode stats cache at \(Self.statsCachePath, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private func setupFileWatchers() {
        let usageWatcher = FileWatcher(filePath: Self.usageFilePath)
        usageWatcher.onChange = { [weak self] in
            Task { @MainActor in self?.loadUsageData() }
        }
        usageWatcher.start()
        usageFileWatcher = usageWatcher

        let statsWatcher = FileWatcher(filePath: Self.statsCachePath)
        statsWatcher.onChange = { [weak self] in
            Task { @MainActor in self?.loadStatsCache() }
        }
        statsWatcher.start()
        statsFileWatcher = statsWatcher
    }

    private var lastCountdownText: String = ""

    private func setupCountdownTimer() {
        // GCD timer — fires reliably even when menu bar app is in background.
        // 15s (was 10s) with wider leeway lets the scheduler batch wakeups and the
        // process nap longer; countdowns change at minute granularity so this is
        // imperceptible, and live CLI activity still wakes polling instantly via
        // FileWatcher rather than relying on this tick. (#C2)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 15, repeating: 15.0, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }

                // Detect Claude desktop app or CLI → wake API polling
                if self.isClaudeProcessRunning() {
                    self.wakeAPIPolling()
                }

                let current = "\(self.fiveHourCountdown)|\(self.weekCountdown)|\(self.timeSinceUpdate)|\(self.apiDataSource)|\(self.isAPIDataFresh)"
                if current != self.lastCountdownText {
                    self.lastCountdownText = current
                    self.objectWillChange.send()
                }
            }
        }
        timer.resume()
        countdownTimer = timer
    }

    // MARK: - Activity-Driven API Polling
    //
    // Two rates:
    //   Active — poll every `pollInterval` (60s base), when Claude activity detected
    //   Idle   — poll every `idlePollInterval` (300s), after cooldown with no activity
    //
    // The polling loop NEVER stops — it just slows down. This ensures the menu bar
    // always reflects current usage even when the 5-hour window slides passively.
    //
    // Activity triggers: FileWatcher (CLI), process check (desktop app / CLI)
    // Backoff: on 429 → double interval (60→120→240→480→max 900). On success → reset.

    private func startAPIPolling() {
        guard apiPollingTask == nil else { return }
        launchPollingLoop()
    }

    /// Single point that creates the polling task, bumping the generation so the
    /// loop can detect if it has been superseded before tearing down shared state.
    private func launchPollingLoop() {
        pollingGeneration &+= 1
        let generation = pollingGeneration
        apiPollingTask = Task {
            await self.apiPollingLoop(generation: generation)
        }
    }

    /// Wake up API polling — called when Claude activity is detected.
    /// Updates lastActivityTime so the loop uses the faster active interval, and
    /// interrupts any in-flight sleep so a fresh fetch happens immediately rather
    /// than after the remaining poll interval (up to 60s/300s of dead wait).
    func wakeAPIPolling() {
        // #2: Allow both OAuth and Keychain users to wake polling
        guard Self.hasConsent || UserDefaults.standard.string(forKey: "authMethod") == "oauth" else { return }
        lastActivityTime = .now

        // Restart loop if it was cancelled (shouldn't happen, but safety net)
        if apiPollingTask == nil {
            launchPollingLoop()
            return
        }

        // Interrupt the parked sleep so the loop fetches now. If the loop is
        // mid-fetch (no continuation parked), flag wakePending so it skips its
        // next sleep instead of waiting out a full interval.
        if let continuation = sleepWakeContinuation {
            sleepWakeContinuation = nil
            continuation.resume()
        } else {
            wakePending = true
        }
    }

    /// Sleep for `seconds`, but return early if `wakeAPIPolling()` fires.
    /// Returns when either the deadline elapses or a wake interrupts it.
    private func interruptibleSleep(seconds: TimeInterval) async {
        // A wake arrived while we were fetching — consume it and don't sleep.
        if wakePending {
            wakePending = false
            return
        }

        // Park on a continuation that wakeAPIPolling() can resume early.
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            // Explicit hop back to the main actor to resume the parked sleep.
            await MainActor.run { self.resumeSleepWake() }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // If a wake snuck in between the wakePending check and here, resume now.
            if wakePending {
                wakePending = false
                continuation.resume()
            } else {
                sleepWakeContinuation = continuation
            }
        }
        timeoutTask.cancel()
    }

    /// Resume the parked sleep continuation if present (called by the timeout task).
    private func resumeSleepWake() {
        guard let continuation = sleepWakeContinuation else { return }
        sleepWakeContinuation = nil
        continuation.resume()
    }

    // Both `apiPollingLoop` and `fetchAPIUsage` mutate `@Published` properties on
    // `self`, so they must run on the main actor. The enclosing class is already
    // `@MainActor`, but we annotate explicitly so the contract survives any future
    // call site moving off the main actor.
    @MainActor
    private func apiPollingLoop(generation: Int) async {
        while !Task.isCancelled {
            await fetchAPIUsage()

            // Use faster rate when active, slower when idle — but never stop
            let isIdle = Date.now.timeIntervalSince(lastActivityTime) > cooldownThreshold
            let baseInterval = isIdle ? idlePollInterval : pollInterval
            let jitter = Double.random(in: -15...15)
            let sleepInterval = max(15, baseInterval + jitter)
            // Interruptible: a wake (CLI/file/process activity) cuts this short so
            // the next fetch is immediate rather than up to `sleepInterval` away.
            await interruptibleSleep(seconds: sleepInterval)
        }
        // Already on the main actor — no MainActor.run hop needed.
        // Only clear shared state if no newer loop has superseded us. After a
        // stopAndReset()+start() cycle the cancelled old loop resumes here *after*
        // the new loop is already running; clearing unconditionally would drop the
        // new task handle (duplicate polling on next wake) and orphan its parked
        // sleep continuation (hang). The generation guard makes this a no-op then.
        guard generation == pollingGeneration else { return }
        self.sleepWakeContinuation = nil
        self.wakePending = false
        self.apiPollingTask = nil
    }

    @MainActor
    private func fetchAPIUsage() async {
        let result = await apiClient.fetchUsage()
        switch result {
        case .success(let response):
            apiUsage = response
            apiDataSource = .api
            lastAPISuccessTime = .now
            lastUpdated = .now
            pollInterval = Self.activePollInterval
            statusMessage = nil  // Clear any previous error
            recordPercentageReading()
            checkAndNotify()

        case .failure(let error):
            switch error {
            case .rateLimited(let retryAfter):
                // Back off from the active baseline, not from whatever a prior
                // transient (timeout/unauthorized) left in pollInterval — otherwise
                // the 429 schedule is order-dependent (#B4). Double the larger of the
                // current value and the active floor, honour any server hint, cap it.
                let serverSuggestion = retryAfter ?? 0
                let base = max(pollInterval, Self.activePollInterval)
                pollInterval = min(max(base * 2, serverSuggestion), apiBackoffCap)
                // Silent — orange dot is enough
            case .unauthorized:
                let isOAuth = UserDefaults.standard.string(forKey: "authMethod") == "oauth"
                if isOAuth {
                    // OAuth refresh handles a genuine 401; a Keychain-locked state
                    // (sleep/wake) surfaces here too, so reflect that transient
                    // condition instead of clearing the message silently (#B6).
                    statusMessage = oauthManager?.logoutReason == "keychainLocked"
                        ? "Keychain locked — unlock your Mac to resume usage updates"
                        : nil
                } else {
                    statusMessage = "Token expired — run any prompt in Claude Code to refresh, or switch to OAuth"
                }
                pollInterval = idlePollInterval
            case .noToken:
                let isOAuth = UserDefaults.standard.string(forKey: "authMethod") == "oauth"
                if isOAuth {
                    if oauthManager?.logoutReason == "keychainLocked" {
                        statusMessage = "Keychain locked — unlock your Mac to resume usage updates"
                    }
                    // Other OAuth noToken cases are handled by OAuthManager.logout()
                } else {
                    statusMessage = "Waiting for Claude Code — run 'claude' in Terminal to log in"
                }
            case .timeout:
                // Retry sooner than the active interval, but never below the loop's
                // 15s floor. Absolute assignment is fine here because the 429 branch
                // no longer reads pollInterval as its sole base (#B4).
                pollInterval = 30
            default:
                break
            }

            // Preserve last good data — only drop after staleDataThreshold of
            // consecutive failures. Guard assignments so we don't emit redundant
            // objectWillChange on every failure tick (#B7).
            let shouldDrop: Bool
            if let lastSuccess = lastAPISuccessTime {
                shouldDrop = Date.now.timeIntervalSince(lastSuccess) > staleDataThreshold
            } else {
                shouldDrop = true  // never succeeded → stay in fileOnly
            }
            if shouldDrop {
                if apiUsage != nil { apiUsage = nil }
                if apiDataSource != .fileOnly { apiDataSource = .fileOnly }
            }
        }
    }

    /// Lightweight check: is the Claude desktop app or Claude Code CLI running?
    /// Uses NSWorkspace (no subprocess) + checks for recent file activity as CLI signal.
    private func isClaudeProcessRunning() -> Bool {
        // Check Claude desktop app via NSWorkspace (fast, no subprocess)
        if NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == "com.anthropic.claude"
        }) {
            return true
        }
        // Check if monthly_usage.json was modified recently — signals active CLI.
        // Window matches `activityWindow`/`cooldownThreshold` (5 min) so the process
        // check and the active/idle interval switch agree on what "active" means;
        // a 10-min window here previously kept waking the loop after it had already
        // dropped to the idle rate, producing inconsistent latency.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: Self.usageFilePath),
           let mtime = attrs[.modificationDate] as? Date,
           Date.now.timeIntervalSince(mtime) < activityWindow {
            return true
        }
        return false
    }

    // MARK: - Current Session

    var currentSession: (id: String, session: SessionTokens)? {
        guard let sessions = usage?.sessions, !sessions.isEmpty else { return nil }
        // Prefer the session ID written by statusline.sh (always the most recent)
        if let currentId = usage?.currentSessionId, let session = sessions[currentId] {
            return (id: currentId, session: session)
        }
        // Fallback: highest output tokens
        return sessions.max(by: { $0.value.outputTokens < $1.value.outputTokens })
            .map { (id: $0.key, session: $0.value) }
    }

    // MARK: - Session Cost & Context (Claude Code v2.1 signals)

    /// Current session cost in USD. Prefers the per-session value, falling back to
    /// the top-level snapshot. `nil` when no cost has been recorded (older data or
    /// a fresh session). This is the authoritative cumulative consumption metric
    /// under the v2.1.132 context-token semantics change; it resets on `/clear`.
    var sessionCostUsd: Double? {
        if let c = currentSession?.session.costUsd, c > 0 { return c }
        if let c = usage?.sessionCostUsd, c > 0 { return c }
        return nil
    }

    var sessionCostFormatted: String? {
        guard let c = sessionCostUsd else { return nil }
        return String(format: "$%.2f", c)
    }

    /// Wall-clock duration of the current session, formatted (e.g. "1h 12m", "13m").
    var sessionDurationFormatted: String? {
        guard let ms = usage?.sessionDurationMs, ms > 0 else { return nil }
        let totalSeconds = ms / 1000
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    /// Lines added/removed this session, when Claude Code reports them.
    var sessionLinesChanged: (added: Int, removed: Int)? {
        let a = usage?.sessionLinesAdded ?? 0
        let r = usage?.sessionLinesRemoved ?? 0
        return (a > 0 || r > 0) ? (a, r) : nil
    }

    /// Max context window (200k or 1M). Defaults to 200k if unknown.
    var contextWindowSize: Int { usage?.contextWindowSize ?? 200_000 }

    /// Current context-window fill percentage (from statusline), if available.
    var contextUsedPercentage: Double? {
        guard let p = usage?.contextUsedPct, p >= 0 else { return nil }
        return p
    }

    // MARK: - Extra Token Tracking (tokens above included plan limits)

    /// Total tokens for a period across all models (all 4 types: input + output + cache_write + cache_read).
    func totalTokens(for period: Period) -> Int {
        totalTokensAll(for: period)
    }

    private func updateExtraTokenTracking() {
        var changed = false

        // 5-hour bucket
        if let pct = fiveHourPercentage, pct.value >= 100 {
            if extraTokenSnapshots.fiveHour == nil {
                let now = Self.iso8601Formatter.string(from: .now)
                extraTokenSnapshots.fiveHour = ExtraTokenSnapshot(
                    snapshotTokens: totalTokens(for: .fiveHour),
                    snapshotAt: now
                )
                changed = true
            }
        } else if extraTokenSnapshots.fiveHour != nil && isAPIDataFresh {
            // Only clear when API data is authoritative AND fresh — avoid spurious
            // reset on stale data. Without the freshness gate, a user whose API
            // token expires while above 100% would have the snapshot pinned forever
            // because `apiUsage != nil` no longer implies the value is current.
            extraTokenSnapshots.fiveHour = nil
            changed = true
        }

        // 7-day bucket
        if let pct = weekPercentage, pct.value >= 100 {
            if extraTokenSnapshots.sevenDay == nil {
                let now = Self.iso8601Formatter.string(from: .now)
                extraTokenSnapshots.sevenDay = ExtraTokenSnapshot(
                    snapshotTokens: totalTokens(for: .week),
                    snapshotAt: now
                )
                changed = true
            }
        } else if extraTokenSnapshots.sevenDay != nil && isAPIDataFresh {
            extraTokenSnapshots.sevenDay = nil
            changed = true
        }

        if changed { extraTokenSnapshots.save() }
    }

    var fiveHourExtraTokens: Int? {
        guard let snapshot = extraTokenSnapshots.fiveHour else { return nil }
        return max(0, totalTokens(for: .fiveHour) - snapshot.snapshotTokens)
    }

    var weekExtraTokens: Int? {
        guard let snapshot = extraTokenSnapshots.sevenDay else { return nil }
        return max(0, totalTokens(for: .week) - snapshot.snapshotTokens)
    }

    // MARK: - Time-to-Limit Estimates

    private func recordPercentageReading() {
        let now = Date.now
        if let pct = fiveHourPercentage, pct.value < 100 {
            if fiveHourReadings.last.map({ now.timeIntervalSince($0.timestamp) >= Self.minReadingInterval }) ?? true {
                fiveHourReadings.append(PercentageReading(value: pct.value, timestamp: now))
                // suffix(_:) is bounds-safe whether count <, ==, or > maxReadings,
                // unlike removeFirst(_:) which traps when n > count.
                if fiveHourReadings.count > Self.maxReadings {
                    fiveHourReadings = Array(fiveHourReadings.suffix(Self.maxReadings))
                }
            }
        } else {
            fiveHourReadings.removeAll()
        }

        if let pct = weekPercentage, pct.value < 100 {
            if weekReadings.last.map({ now.timeIntervalSince($0.timestamp) >= Self.minReadingInterval }) ?? true {
                weekReadings.append(PercentageReading(value: pct.value, timestamp: now))
                if weekReadings.count > Self.maxReadings {
                    weekReadings = Array(weekReadings.suffix(Self.maxReadings))
                }
            }
        } else {
            weekReadings.removeAll()
        }
    }

    private func timeToLimit(readings: [PercentageReading]) -> TimeInterval? {
        guard readings.count >= 2 else { return nil }
        let oldest = readings.first!
        let newest = readings.last!
        let elapsed = newest.timestamp.timeIntervalSince(oldest.timestamp)
        guard elapsed > 60 else { return nil } // need at least 1 minute of data
        let delta = newest.value - oldest.value
        guard delta > 0.5 else { return nil } // need measurable increase
        let ratePerSecond = delta / elapsed
        let remaining = 100.0 - newest.value
        return remaining / ratePerSecond
    }

    /// Estimated time until the 5h bucket reaches 100%, or nil if not enough data / already at limit
    var fiveHourTimeToLimit: String? {
        guard let seconds = timeToLimit(readings: fiveHourReadings) else { return nil }
        return formatTimeToLimit(seconds)
    }

    /// Estimated time until the 7d bucket reaches 100%, or nil if not enough data / already at limit
    var weekTimeToLimit: String? {
        guard let seconds = timeToLimit(readings: weekReadings) else { return nil }
        return formatTimeToLimit(seconds)
    }

    private func formatTimeToLimit(_ seconds: TimeInterval) -> String? {
        if seconds > 86400 * 3 { return nil } // too far out to be useful
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 {
            return "~\(hours)h \(minutes)m to 100%"
        } else if minutes > 1 {
            return "~\(minutes)m to 100%"
        } else {
            return "<1m to 100%"
        }
    }

    var sessionCount: Int {
        usage?.sessions.count ?? 0
    }

    /// All-time session count from stats-cache. Falls back to 0 (not the live
    /// `sessionCount`) because that live value is pruned to the last 50 sessions —
    /// presenting it under the "ALL-TIME" header would understate reality before
    /// stats-cache.json has loaded (#C5).
    var totalSessionsAllTime: Int {
        statsCache?.totalSessions ?? 0
    }

    var totalMessagesAllTime: Int {
        statsCache?.totalMessages ?? 0
    }

    // MARK: - Stats-Cache Freshness

    private static let utcTimeZone = TimeZone(identifier: "UTC")!

    private static let statsCacheDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = utcTimeZone
        return f
    }()

    // Day-diff calendar pinned to UTC to match the UTC-parsed date; using
    // Calendar.current (local TZ) against a UTC-midnight date was off-by-one near
    // local midnight for users far from UTC.
    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = utcTimeZone
        return c
    }()

    /// Days since stats-cache.json's `lastComputedDate`, or nil if unavailable.
    /// stats-cache.json is produced by an external tool (not this app); if that
    /// writer stalls, the all-time figures silently freeze — this exposes that.
    private var statsCacheAgeDays: Int? {
        guard let s = statsCache?.lastComputedDate,
              let date = Self.statsCacheDateFormatter.date(from: String(s.prefix(10))) else { return nil }
        return Self.utcCalendar.dateComponents([.day], from: date, to: .now).day
    }

    /// True when the all-time data is more than 3 days old.
    var isStatsCacheStale: Bool {
        (statsCacheAgeDays ?? 0) > 3
    }

    /// Human-readable freshness line for the all-time panel, e.g. "Data as of 2026-06-09 (41d ago)".
    var statsCacheAgeDescription: String? {
        guard let s = statsCache?.lastComputedDate else { return nil }
        let dateStr = String(s.prefix(10))
        guard let days = statsCacheAgeDays else { return "Data as of \(dateStr)" }
        if days <= 0 { return "Data as of \(dateStr) (today)" }
        if days == 1 { return "Data as of \(dateStr) (1d ago)" }
        return "Data as of \(dateStr) (\(days)d ago)"
    }

    // MARK: - Rate Limit Percentages (API first, JSON fallback)

    /// True when monthly_usage.json was decoded more recently than the last
    /// successful API fetch. The file is written by statusline.sh on every render
    /// (and surfaced within ms by FileWatcher), so during active sessions it is
    /// the freshest source — whereas the API has a 60s+ poll floor and its own
    /// server-side delay. When the file is ahead, prefer its percentage so the
    /// headline number tracks live activity instead of lagging the slow API path.
    private var fileIsFresherThanAPI: Bool {
        guard let fileTime = lastFileUpdateTime else { return false }
        guard let apiTime = lastAPISuccessTime else { return true }
        return fileTime > apiTime
    }

    var fiveHourPercentage: RateLimitPercentage? {
        // Prefer the freshly-written file value when it is ahead of the last API fetch.
        if fileIsFresherThanAPI, let real = usage?.dayUsedPct {
            return RateLimitPercentage(value: real, isEstimated: false)
        }
        if let api = apiUsage?.fiveHour {
            return RateLimitPercentage(value: api.utilization, isEstimated: false)
        }
        guard let real = usage?.dayUsedPct else { return nil }
        return RateLimitPercentage(value: real, isEstimated: false)
    }

    var weekPercentage: RateLimitPercentage? {
        if fileIsFresherThanAPI, let real = usage?.weekUsedPct {
            return RateLimitPercentage(value: real, isEstimated: false)
        }
        if let api = apiUsage?.sevenDay {
            return RateLimitPercentage(value: api.utilization, isEstimated: false)
        }
        guard let real = usage?.weekUsedPct else { return nil }
        return RateLimitPercentage(value: real, isEstimated: false)
    }

    // MARK: - 7-Day Sub-Buckets (from API — Opus/Sonnet breakdowns)

    struct SubBucket: Identifiable {
        let id: String
        let label: String
        let percentage: Double
    }

    var weekSubBuckets: [SubBucket] {
        var buckets: [SubBucket] = []
        if let opus = apiUsage?.sevenDayOpus {
            buckets.append(SubBucket(id: "opus", label: "Opus", percentage: opus.utilization))
        }
        if let sonnet = apiUsage?.sevenDaySonnet {
            buckets.append(SubBucket(id: "sonnet", label: "Sonnet", percentage: sonnet.utilization))
        }
        return buckets
    }

    // MARK: - Extra Usage (from API — dollar credits)

    var extraUsageEnabled: Bool {
        apiUsage?.extraUsage?.isEnabled ?? false
    }

    var extraUsageCredits: Double {
        (apiUsage?.extraUsage?.usedCredits ?? 0) / 100.0 // API returns cents
    }

    var extraUsageMonthlyLimit: Double {
        (apiUsage?.extraUsage?.monthlyLimit ?? 0) / 100.0 // API returns cents
    }

    var extraUsageUtilization: Double {
        apiUsage?.extraUsage?.utilization ?? 0
    }

    var extraUsageFormatted: String {
        String(format: "$%.2f", extraUsageCredits)
    }

    // MARK: - Countdowns (API ISO 8601 first, JSON epoch fallback)

    var fiveHourCountdown: String {
        // API ISO 8601 reset time (most accurate)
        if let iso = apiUsage?.fiveHour?.resetsAt, let cd = formatISO8601Countdown(iso) {
            return cd
        }
        // JSON epoch fallback
        guard let resets = usage?.dayResetsAt, resets > 0 else { return "no data yet" }
        let target = Date(timeIntervalSince1970: resets)
        let diff = target.timeIntervalSince(.now)
        if diff <= 0 { return "reset complete" }
        return formatCountdown(diff)
    }

    var weekCountdown: String {
        if let iso = apiUsage?.sevenDay?.resetsAt, let cd = formatISO8601Countdown(iso) {
            return cd
        }
        guard let resets = usage?.weekResetsAt, resets > 0 else { return "no data yet" }
        let target = Date(timeIntervalSince1970: resets)
        let diff = target.timeIntervalSince(.now)
        if diff <= 0 { return "reset complete" }
        return formatCountdown(diff)
    }

    // #21: Cached formatters (ISO8601DateFormatter is expensive to construct)
    private static let iso8601WithFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso8601NoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func formatISO8601Countdown(_ iso: String) -> String? {
        guard let target = Self.iso8601WithFrac.date(from: iso) else {
            guard let target = Self.iso8601NoFrac.date(from: iso) else { return nil }
            let diff = target.timeIntervalSince(.now)
            if diff <= 0 { return "reset complete" }
            return formatCountdown(diff)
        }
        let diff = target.timeIntervalSince(.now)
        if diff <= 0 { return "reset complete" }
        return formatCountdown(diff)
    }

    var monthCountdown: String {
        let cal = Calendar.current
        guard let startOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: Date())),
              let endOfMonth = cal.date(byAdding: .month, value: 1, to: startOfMonth) else { return "" }
        let diff = endOfMonth.timeIntervalSince(.now)
        if diff <= 0 { return "resetting..." }
        return formatCountdown(diff)
    }

    private func formatCountdown(_ diff: TimeInterval) -> String {
        let days = Int(diff) / 86400
        let hours = (Int(diff) % 86400) / 3600
        let minutes = (Int(diff) % 3600) / 60
        if days > 0 {
            return "resets in \(days)d \(hours)h"
        } else if hours > 0 {
            return "resets in \(hours)h \(minutes)m"
        } else {
            return "resets in \(minutes)m"
        }
    }

    // MARK: - Token Formatting

    static func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000_000 {
            return String(format: "%.1fB", Double(count) / 1_000_000_000)
        } else if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000)
        } else if count == 0 {
            return "0"
        } else {
            return "\(count)"
        }
    }

    // MARK: - Period Aggregates (from monthly_usage.json — real-time)

    /// Returns all 4 token types for a period, aggregated across models.
    /// In monthly_usage.json, *_input_tokens is base new input (NOT cache-inclusive).
    /// All 4 types (input, output, cache_write, cache_read) count toward rate limits.
    func tokens(for period: Period) -> (input: Int, output: Int, cacheWrite: Int, cacheRead: Int) {
        guard let models = usage?.models else { return (0, 0, 0, 0) }
        var inp = 0, out = 0, cw = 0, cr = 0
        for (_, m) in models {
            let t = m.forPeriod(period)
            inp += t.input
            out += t.output
            cw += t.cacheWrite
            cr += t.cacheRead
        }
        return (inp, out, cw, cr)
    }

    /// Returns total token count for a period (all 4 types summed).
    /// This is the true total that counts against rate limits.
    func totalTokensAll(for period: Period) -> Int {
        let t = tokens(for: period)
        return t.input + t.output + t.cacheWrite + t.cacheRead
    }

    // MARK: - Model Breakdown (from monthly_usage.json for period data)

    struct ModelSummary: Identifiable {
        let id: String
        let displayName: String
        let inputTokens: Int       // base new input (non-cache)
        let outputTokens: Int
        let cacheWriteTokens: Int
        let cacheReadTokens: Int

        var total: Int { inputTokens + outputTokens + cacheWriteTokens + cacheReadTokens }
    }

    func modelBreakdown(for period: Period) -> [ModelSummary] {
        guard let models = usage?.models else { return [] }
        return models.compactMap { (modelId, tokens) in
            let t = tokens.forPeriod(period)
            guard t.input > 0 || t.output > 0 || t.cacheWrite > 0 || t.cacheRead > 0 else { return nil }
            return ModelSummary(
                id: modelId,
                displayName: ModelUtils.displayName(for: modelId),
                inputTokens: t.input,
                outputTokens: t.output,
                cacheWriteTokens: t.cacheWrite,
                cacheReadTokens: t.cacheRead
            )
        }.sorted { $0.total > $1.total }
    }

    // MARK: - Historical All-Time Model Data (from stats-cache.json)

    struct HistoricalModelSummary: Identifiable {
        let id: String
        let displayName: String
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheCreationTokens: Int
    }

    var historicalModels: [HistoricalModelSummary] {
        guard let models = statsCache?.modelUsage else { return [] }
        return models.map { (modelId, usage) in
            HistoricalModelSummary(
                id: modelId,
                displayName: ModelUtils.displayName(for: modelId),
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                cacheReadTokens: usage.cacheReadInputTokens,
                cacheCreationTokens: usage.cacheCreationInputTokens
            )
        }.sorted {
            ($0.inputTokens + $0.outputTokens + $0.cacheReadTokens + $0.cacheCreationTokens) >
            ($1.inputTokens + $1.outputTokens + $1.cacheReadTokens + $1.cacheCreationTokens)
        }
    }

    // MARK: - Time Since Update

    var timeSinceUpdate: String {
        // Use lastAPISuccessTime when we have cached API data, lastUpdated otherwise
        let refDate = lastAPISuccessTime ?? lastUpdated
        let seconds = Int(Date.now.timeIntervalSince(refDate))
        let prefix: String
        if apiUsage != nil {
            prefix = apiPollingTask != nil ? "API" : "API idle"
        } else {
            prefix = "file"
        }
        if seconds < 5 { return "\(prefix) just now" }
        if seconds < 60 { return "\(prefix) \(seconds)s ago" }
        let minutes = seconds / 60
        if minutes >= 60 {
            return "\(prefix) \(minutes / 60)h \(minutes % 60)m ago"
        }
        return "\(prefix) \(minutes)m ago"
    }

    /// Data is stale when no API data at all (never succeeded or expired)
    var isDataStale: Bool {
        apiUsage == nil
    }

    /// API data is fresh when last successful fetch was within 5 minutes
    var isAPIDataFresh: Bool {
        guard apiUsage != nil, let lastSuccess = lastAPISuccessTime else { return false }
        return Date.now.timeIntervalSince(lastSuccess) < 300
    }

    /// Whether the DISPLAYED percentage is stale. The headline % is sourced from
    /// whichever of file (statusline) or API is fresher (see `fileIsFresherThanAPI`),
    /// so staleness must consider BOTH — otherwise the "stale" marker contradicts a
    /// live file-sourced number during an active session.
    var isDisplayStale: Bool {
        let apiFresh = isAPIDataFresh
        let fileFresh = lastFileUpdateTime.map { Date.now.timeIntervalSince($0) < 300 } ?? false
        return !(apiFresh || fileFresh)
    }

    // MARK: - Alert Levels

    enum AlertLevel: Int, Comparable {
        case normal = 0, warning90 = 1, critical95 = 2, maxed100 = 3

        static func < (lhs: AlertLevel, rhs: AlertLevel) -> Bool { lhs.rawValue < rhs.rawValue }

        static func from(percentage: Double) -> AlertLevel {
            if percentage >= 100 { return .maxed100 }
            if percentage >= 95 { return .critical95 }
            if percentage >= 90 { return .warning90 }
            return .normal
        }
    }

    var fiveHourAlertLevel: AlertLevel {
        guard let pct = fiveHourPercentage else { return .normal }
        return AlertLevel.from(percentage: pct.value)
    }

    var sevenDayAlertLevel: AlertLevel {
        guard let pct = weekPercentage else { return .normal }
        return AlertLevel.from(percentage: pct.value)
    }

    // MARK: - Menu Bar Display (5h primary)

    var menuBarText: String {
        if let pct = fiveHourPercentage {
            return "\(Int(pct.value))%"
        }
        // Fallback: show total month tokens
        let total = (usage?.monthInputTokens ?? 0) + (usage?.monthOutputTokens ?? 0)
        if total > 0 { return UsageViewModel.formatTokens(total) }
        return "\u{2014}" // em dash
    }

    var menuBarBarPercentage: Double {
        fiveHourPercentage?.value ?? 0
    }

    // MARK: - Notifications

    // Cached in-memory, persisted to UserDefaults only when changed
    private static let notifiedDefaultsKey = "notifiedThresholds"
    private var notifiedThresholds: Set<String> = {
        Set(UserDefaults.standard.stringArray(forKey: notifiedDefaultsKey) ?? [])
    }()

    private func persistNotifiedThresholds() {
        UserDefaults.standard.set(Array(notifiedThresholds), forKey: Self.notifiedDefaultsKey)
    }

    func checkAndNotify() {
        checkThreshold(bucket: "5h", percentage: fiveHourPercentage, countdown: fiveHourCountdown)
        checkThreshold(bucket: "7d", percentage: weekPercentage, countdown: weekCountdown)
    }

    private func checkThreshold(bucket: String, percentage: RateLimitPercentage?, countdown: String) {
        guard let pct = percentage, !pct.isEstimated else { return }
        let value = pct.value

        // Only clear thresholds when API data is authoritative
        guard apiUsage != nil else { return }

        var changed = false
        let allThresholds: [Double] = [90, 95, 100]
        for threshold in allThresholds {
            if value < threshold {
                if notifiedThresholds.remove("\(bucket)_\(Int(threshold))") != nil {
                    changed = true
                }
            }
        }

        let thresholds: [(Double, String)] = [(100, "100%"), (95, "95%"), (90, "90%")]
        var alreadyNotified = false
        for (threshold, label) in thresholds {
            let key = "\(bucket)_\(Int(threshold))"
            if value >= threshold && !notifiedThresholds.contains(key) {
                notifiedThresholds.insert(key)
                changed = true
                if !alreadyNotified {
                    sendNotification(
                        title: "Claude Usage Alert",
                        body: "\(bucket == "5h" ? "5-hour" : "7-day") usage at \(label) — \(countdown)"
                    )
                    alreadyNotified = true
                }
            }
        }
        if changed { persistNotifiedThresholds() }
    }

    private static var notificationAuthRequested = false

    private func sendNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()

        if !Self.notificationAuthRequested {
            Self.notificationAuthRequested = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }

        // System silently drops notifications if not authorized — acceptable behavior
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request)
    }
}
