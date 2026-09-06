import AppKit
import Security
import ServiceManagement

// MARK: - Shared model

// Both providers reduce to the same thing: a list of limit rows (label, percent,
// reset time, optional severity) plus an optional spend line. The menu and the
// bar title only ever see this shape.

struct Row {
    let label: String
    let percent: Double
    let severity: String?
    let resetsAt: Date?
}

struct Snapshot {
    let rows: [Row]
    let spendRow: String?

    var worst: Row? { rows.max(by: { $0.percent < $1.percent }) }

    // Providers flag severity themselves where they can; 80% is the backstop
    // for responses that don't carry one.
    var flagged: Bool {
        rows.contains { ($0.severity ?? "normal") != "normal" } || (worst?.percent ?? 0) >= 80
    }
}

enum FetchError: Error, CustomStringConvertible {
    case keychain(OSStatus)
    case credentialFormat
    case noCredentials(String)
    case http(Int, String)
    case network(String)

    var description: String {
        switch self {
        case .keychain(let s): return "Keychain read failed (\(s))"
        case .credentialFormat: return "Unexpected credential format"
        case .noCredentials(let hint): return hint
        case .http(401, let hint): return "Token stale — \(hint)"
        case .http(let code, _): return "HTTP \(code)"
        case .network(let m): return m
        }
    }
}

protocol Provider {
    /// Short tag shown in the menu bar, e.g. "CC".
    var code: String { get }
    /// Full name used as the menu section header.
    var name: String { get }
    func fetch(completion: @escaping (Result<Snapshot, FetchError>) -> Void)
}

func getJSON(_ req: URLRequest, staleHint: String,
             decode: @escaping (Data) throws -> Snapshot,
             completion: @escaping (Result<Snapshot, FetchError>) -> Void) {
    URLSession.shared.dataTask(with: req) { data, resp, err in
        if let err {
            completion(.failure(.network(err.localizedDescription)))
            return
        }
        guard let http = resp as? HTTPURLResponse else {
            completion(.failure(.network("No response")))
            return
        }
        guard http.statusCode == 200 else {
            completion(.failure(.http(http.statusCode, staleHint)))
            return
        }
        guard let data, let snap = try? decode(data) else {
            completion(.failure(.network("Could not parse response")))
            return
        }
        completion(.success(snap))
    }.resume()
}

// The Anthropic API returns 6-digit fractional seconds, which ISO8601DateFormatter can't parse.
func parseISO(_ s: String?) -> Date? {
    guard let s else { return nil }
    let cleaned = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: cleaned)
}

func windowLabel(seconds: Int?) -> String {
    switch seconds {
    case .some(let s) where s <= 6 * 3600: return "Session (\(s / 3600)h)"
    case .some(let s) where s % 86400 == 0 && s / 86400 == 7: return "Week"
    case .some(let s) where s % 86400 == 0: return "\(s / 86400)d"
    case .some(let s): return "\(s / 3600)h"
    case .none: return "Limit"
    }
}

// MARK: - Claude Code

// The usage endpoint returns two generations of the same data. `limits` is the
// current shape: one entry per limit the plan actually has, including
// model-scoped weekly limits the old fixed fields can't express. The top-level
// `five_hour`/`seven_day*` buckets are the legacy shape, kept as a fallback.

struct ClaudeCode: Provider {
    let code = "CC"
    let name = "Claude Code"

    struct Bucket: Decodable {
        let utilization: Double?
        let resetsAt: String?
        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    struct Scope: Decodable {
        struct Named: Decodable {
            let displayName: String?
            enum CodingKeys: String, CodingKey { case displayName = "display_name" }
        }
        let model: Named?
        let surface: Named?
        var label: String? { model?.displayName ?? surface?.displayName }
    }

    struct Limit: Decodable {
        let kind: String
        let percent: Double?
        let severity: String?
        let resetsAt: String?
        let scope: Scope?
        enum CodingKeys: String, CodingKey {
            case kind, percent, severity, scope
            case resetsAt = "resets_at"
        }
        var label: String {
            switch kind {
            case "session": return "Session (5h)"
            case "weekly_all": return "Week (all)"
            case "weekly_scoped": return "Week (\(scope?.label ?? "scoped"))"
            default:
                // Future kinds render readably instead of vanishing.
                let pretty = kind.replacingOccurrences(of: "_", with: " ").capitalized
                if let s = scope?.label { return "\(pretty) (\(s))" }
                return pretty
            }
        }
    }

    struct Money: Decodable {
        let amountMinor: Double?
        let currency: String?
        let exponent: Int?
        enum CodingKeys: String, CodingKey {
            case amountMinor = "amount_minor"
            case currency, exponent
        }
        var formatted: String? {
            guard let amountMinor else { return nil }
            let value = amountMinor / pow(10, Double(exponent ?? 2))
            let fmt = NumberFormatter()
            fmt.numberStyle = .currency
            fmt.currencyCode = currency ?? "USD"
            return fmt.string(from: NSNumber(value: value))
        }
    }

    struct Spend: Decodable {
        let used: Money?
        let limit: Money?
        let percent: Double?
        let enabled: Bool?
    }

    struct Usage: Decodable {
        let limits: [Limit]?
        let spend: Spend?
        let fiveHour: Bucket?
        let sevenDay: Bucket?
        let sevenDayOpus: Bucket?
        let sevenDaySonnet: Bucket?
        enum CodingKeys: String, CodingKey {
            case limits, spend
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case sevenDayOpus = "seven_day_opus"
            case sevenDaySonnet = "seven_day_sonnet"
        }

        var snapshot: Snapshot {
            var rows: [Row]
            if let limits, !limits.isEmpty {
                rows = limits.compactMap { l in
                    guard let pct = l.percent else { return nil }
                    return Row(label: l.label, percent: pct, severity: l.severity, resetsAt: parseISO(l.resetsAt))
                }
            } else {
                let legacy: [(String, Bucket?)] = [
                    ("Session (5h)", fiveHour),
                    ("Week (all)", sevenDay),
                    ("Week (Opus)", sevenDayOpus),
                    ("Week (Sonnet)", sevenDaySonnet),
                ]
                rows = legacy.compactMap { label, b in
                    guard let b, let pct = b.utilization else { return nil }
                    return Row(label: label, percent: pct, severity: nil, resetsAt: parseISO(b.resetsAt))
                }
            }
            var spendRow: String?
            if let spend, spend.enabled == true, let pct = spend.percent {
                spendRow = "Extra usage:  \(Int(pct.rounded()))%"
                if let used = spend.used?.formatted, let limit = spend.limit?.formatted {
                    spendRow! += "  ·  \(used) of \(limit)"
                }
            }
            return Snapshot(rows: rows, spendRow: spendRow)
        }
    }

    // Reads via /usr/bin/security rather than SecItemCopyMatching: the credential
    // item's partition list only trusts Apple-signed tools, and this app is ad-hoc
    // signed (no Team ID), so a direct read re-prompts for the keychain password on
    // every poll — "Always Allow" can never stick. Apple's own tool passes silently.
    func readAccessToken() throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let stdout = Pipe()
        proc.standardOutput = stdout
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            throw FetchError.network(error.localizedDescription)
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw FetchError.keychain(proc.terminationStatus)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else {
            throw FetchError.credentialFormat
        }
        return token
    }

    func fetch(completion: @escaping (Result<Snapshot, FetchError>) -> Void) {
        let token: String
        do {
            token = try readAccessToken()
        } catch let e as FetchError {
            completion(.failure(e)); return
        } catch {
            completion(.failure(.network(error.localizedDescription))); return
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        getJSON(req, staleHint: "open Claude Code to refresh",
                decode: { try JSONDecoder().decode(Usage.self, from: $0).snapshot },
                completion: completion)
    }
}

// MARK: - Codex

// Codex stores its ChatGPT OAuth tokens in ~/.codex/auth.json (0600). The usage
// endpoint is the one behind `/status` in the Codex CLI. It reports a primary
// window (the plan's main limit) and an optional secondary window, plus extra
// named limits for models metered separately.

struct Codex: Provider {
    let code = "CX"
    let name = "Codex"

    struct Window: Decodable {
        let usedPercent: Double?
        let limitWindowSeconds: Int?
        let resetAt: Double?
        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case limitWindowSeconds = "limit_window_seconds"
            case resetAt = "reset_at"
        }
        func row(_ label: String) -> Row? {
            guard let usedPercent else { return nil }
            return Row(label: label, percent: usedPercent, severity: nil,
                       resetsAt: resetAt.map { Date(timeIntervalSince1970: $0) })
        }
    }

    struct RateLimit: Decodable {
        let primaryWindow: Window?
        let secondaryWindow: Window?
        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
        func rows(scope: String?) -> [Row] {
            let suffix = scope.map { " (\($0))" } ?? ""
            return [primaryWindow, secondaryWindow].compactMap { w in
                w?.row(windowLabel(seconds: w?.limitWindowSeconds) + suffix)
            }
        }
    }

    struct Additional: Decodable {
        let limitName: String?
        let rateLimit: RateLimit?
        enum CodingKeys: String, CodingKey {
            case limitName = "limit_name"
            case rateLimit = "rate_limit"
        }
    }

    struct Credits: Decodable {
        let hasCredits: Bool?
        let unlimited: Bool?
        let balance: String?
        enum CodingKeys: String, CodingKey {
            case hasCredits = "has_credits"
            case unlimited, balance
        }
    }

    struct Usage: Decodable {
        let planType: String?
        let rateLimit: RateLimit?
        let additionalRateLimits: [Additional]?
        let credits: Credits?
        enum CodingKeys: String, CodingKey {
            case planType = "plan_type"
            case rateLimit = "rate_limit"
            case additionalRateLimits = "additional_rate_limits"
            case credits
        }

        var snapshot: Snapshot {
            var rows = rateLimit?.rows(scope: nil) ?? []
            for a in additionalRateLimits ?? [] {
                rows += a.rateLimit?.rows(scope: a.limitName) ?? []
            }
            var spendRow: String?
            if let credits, credits.hasCredits == true {
                spendRow = credits.unlimited == true
                    ? "Credits:  unlimited"
                    : "Credits:  \(credits.balance ?? "?") remaining"
            }
            return Snapshot(rows: rows, spendRow: spendRow)
        }
    }

    func readAuth() throws -> (token: String, accountId: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url) else {
            throw FetchError.noCredentials("Not logged in — run `codex login`")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String,
              let account = tokens["account_id"] as? String
        else {
            throw FetchError.credentialFormat
        }
        return (token, account)
    }

    func fetch(completion: @escaping (Result<Snapshot, FetchError>) -> Void) {
        let auth: (token: String, accountId: String)
        do {
            auth = try readAuth()
        } catch let e as FetchError {
            completion(.failure(e)); return
        } catch {
            completion(.failure(.network(error.localizedDescription))); return
        }
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        req.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        req.setValue(auth.accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        getJSON(req, staleHint: "run codex to refresh",
                decode: { try JSONDecoder().decode(Usage.self, from: $0).snapshot },
                completion: completion)
    }
}

// MARK: - Formatting

func resetText(_ date: Date?) -> String {
    guard let date else { return "" }
    let fmt = DateFormatter()
    if Calendar.current.isDateInToday(date) {
        fmt.dateStyle = .none
        fmt.timeStyle = .short
    } else {
        fmt.setLocalizedDateFormatFromTemplate("EEE j")
    }
    return "  ·  resets \(fmt.string(from: date))"
}

// MARK: - App

final class ProviderState {
    let provider: Provider
    var snapshot: Snapshot?
    var lastFetch: Date?
    var lastError: FetchError?
    init(_ provider: Provider) { self.provider = provider }

    var title: String {
        guard let snapshot, let worst = snapshot.worst else { return "\(provider.code) –" }
        let pct = Int(worst.percent.rounded())
        return snapshot.flagged ? "\(provider.code) ⚠️ \(pct)%" : "\(provider.code) \(pct)%"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private let states: [ProviderState] = [ProviderState(ClaudeCode()), ProviderState(Codex())]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = states.map { "\($0.provider.code) …" }.joined(separator: "  ")
        rebuildMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = 30
    }

    @objc func refresh() {
        // The keychain read is a blocking subprocess call — keep it off the main
        // thread or the menu renders blank while it waits.
        DispatchQueue.global(qos: .utility).async {
            for state in self.states { self.fetch(state) }
        }
    }

    private func fetch(_ state: ProviderState) {
        state.provider.fetch { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let snap):
                    state.snapshot = snap
                    state.lastFetch = Date()
                    state.lastError = nil
                case .failure(let e):
                    state.lastError = e
                }
                self.statusItem.button?.title = self.states.map(\.title).joined(separator: "  ")
                self.rebuildMenu()
            }
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        func addInfo(_ title: String, header: Bool = false) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            if header {
                item.attributedTitle = NSAttributedString(
                    string: title,
                    attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
            }
            menu.addItem(item)
        }

        for (i, state) in states.enumerated() {
            if i > 0 { menu.addItem(.separator()) }
            addInfo(state.provider.name, header: true)
            if let snap = state.snapshot {
                for row in snap.rows {
                    addInfo("\(row.label):  \(Int(row.percent.rounded()))%\(resetText(row.resetsAt))")
                }
                if let spendRow = snap.spendRow { addInfo(spendRow) }
            }
            if let err = state.lastError {
                addInfo("\(err)")
                if let lastFetch = state.lastFetch {
                    let fmt = DateFormatter()
                    fmt.timeStyle = .short
                    addInfo("Showing data from \(fmt.string(from: lastFetch))")
                }
            }
        }

        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "Refresh now", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let loginItem = NSMenuItem(title: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc func toggleLaunchAtLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled {
                try svc.unregister()
            } else {
                try svc.register()
            }
        } catch {
            NSLog("Launch at login toggle failed: \(error)")
        }
        rebuildMenu()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
