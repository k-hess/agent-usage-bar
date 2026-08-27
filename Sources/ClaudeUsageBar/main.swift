import AppKit
import Security
import ServiceManagement

// MARK: - API types

// The usage endpoint returns two generations of the same data. `limits` is the
// current shape: one entry per limit the plan actually has, including
// model-scoped weekly limits the old fixed fields can't express. The top-level
// `five_hour`/`seven_day*` buckets are the legacy shape, kept as a fallback.

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

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
        }
    }

    let model: Named?
    let surface: Named?

    var label: String? {
        model?.displayName ?? surface?.displayName
    }
}

struct Limit: Decodable {
    let kind: String
    let group: String?
    let percent: Double?
    let severity: String?
    let resetsAt: String?
    let scope: Scope?

    enum CodingKeys: String, CodingKey {
        case kind, group, percent, severity, scope
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
    let severity: String?
    let enabled: Bool?
}

struct Usage: Decodable {
    let limits: [Limit]?
    let spend: Spend?

    // Legacy fields.
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

    struct Row {
        let label: String
        let percent: Double
        let severity: String?
        let resetsAt: String?
    }

    var rows: [Row] {
        if let limits, !limits.isEmpty {
            return limits.compactMap { l in
                guard let pct = l.percent else { return nil }
                return Row(label: l.label, percent: pct, severity: l.severity, resetsAt: l.resetsAt)
            }
        }
        let legacy: [(String, Bucket?)] = [
            ("Session (5h)", fiveHour),
            ("Week (all)", sevenDay),
            ("Week (Opus)", sevenDayOpus),
            ("Week (Sonnet)", sevenDaySonnet),
        ]
        return legacy.compactMap { label, b in
            guard let b, let pct = b.utilization else { return nil }
            return Row(label: label, percent: pct, severity: nil, resetsAt: b.resetsAt)
        }
    }

    var spendRow: String? {
        guard let spend, spend.enabled == true, let pct = spend.percent else { return nil }
        var text = "Extra usage:  \(Int(pct.rounded()))%"
        if let used = spend.used?.formatted, let limit = spend.limit?.formatted {
            text += "  ·  \(used) of \(limit)"
        }
        return text
    }
}

enum FetchError: Error, CustomStringConvertible {
    case keychain(OSStatus)
    case credentialFormat
    case http(Int)
    case network(String)

    var description: String {
        switch self {
        case .keychain(let s): return "Keychain read failed (\(s))"
        case .credentialFormat: return "Unexpected credential format"
        case .http(401): return "Token stale — open Claude Code to refresh"
        case .http(let code): return "HTTP \(code)"
        case .network(let m): return m
        }
    }
}

// MARK: - Credentials + fetch

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

func fetchUsage(completion: @escaping (Result<Usage, FetchError>) -> Void) {
    let token: String
    do {
        token = try readAccessToken()
    } catch let e as FetchError {
        completion(.failure(e))
        return
    } catch {
        completion(.failure(.network(error.localizedDescription)))
        return
    }

    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

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
            completion(.failure(.http(http.statusCode)))
            return
        }
        guard let data, let usage = try? JSONDecoder().decode(Usage.self, from: data) else {
            completion(.failure(.network("Could not parse response")))
            return
        }
        completion(.success(usage))
    }.resume()
}

// MARK: - Formatting

// The API returns 6-digit fractional seconds, which ISO8601DateFormatter can't parse.
func parseISO(_ s: String) -> Date? {
    let cleaned = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: cleaned)
}

func resetText(_ iso: String?) -> String {
    guard let iso, let date = parseISO(iso) else { return "" }
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var usage: Usage?
    private var lastFetch: Date?
    private var lastError: FetchError?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "CC …"
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
            self.fetch()
        }
    }

    private func fetch() {
        fetchUsage { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let usage):
                    self.usage = usage
                    self.lastFetch = Date()
                    self.lastError = nil
                case .failure(let e):
                    self.lastError = e
                }
                self.updateTitle()
                self.rebuildMenu()
            }
        }
    }

    private func updateTitle() {
        guard let usage, let worst = usage.rows.max(by: { $0.percent < $1.percent }) else {
            statusItem.button?.title = "CC –"
            return
        }
        let pct = Int(worst.percent.rounded())
        // The API flags severity itself; 80% is the backstop for responses that
        // don't carry one (the legacy fields never do).
        let flagged = usage.rows.contains { ($0.severity ?? "normal") != "normal" } || pct >= 80
        statusItem.button?.title = flagged ? "CC ⚠️ \(pct)%" : "CC \(pct)%"
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        func addInfo(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        if let usage {
            for row in usage.rows {
                let pct = Int(row.percent.rounded())
                addInfo("\(row.label):  \(pct)%\(resetText(row.resetsAt))")
            }
            if let spendRow = usage.spendRow {
                menu.addItem(.separator())
                addInfo(spendRow)
            }
        }

        if let lastError {
            addInfo("\(lastError)")
            if let lastFetch {
                let fmt = DateFormatter()
                fmt.timeStyle = .short
                addInfo("Showing data from \(fmt.string(from: lastFetch))")
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
