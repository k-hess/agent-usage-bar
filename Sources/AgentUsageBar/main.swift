import AppKit
import Security
import ServiceManagement

// MARK: - Shared model

// Every provider reduces to the same thing: a list of limit rows (label, percent,
// reset time, optional severity) plus extra lines such as spend or credits. The
// menu and the bar title only ever see this shape.

struct Row {
    let label: String
    let percent: Double
    let severity: String?
    let resetsAt: Date?

    var line: Line {
        Line(label: label, value: "\(Int(percent.rounded()))%", detail: resetText(resetsAt))
    }
}

// One data line in the dropdown, drawn as three aligned columns.
struct Line {
    let label: String
    let value: String
    var detail = ""
}

// One Claude account in cswap mode: its lines plus any status notes beneath them.
struct Account {
    let number: Int
    let label: String
    let active: Bool
    let lines: [Line]
    let notes: [String]
}

struct Snapshot {
    let rows: [Row]
    var extras: [Line] = []
    // cswap mode: the active account's name for the bar title, and every account.
    var label: String?
    var accounts: [Account] = []

    var lines: [Line] {
        accounts.isEmpty ? rows.map(\.line) + extras : accounts.flatMap(\.lines)
    }

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
    case cswap(String)

    var description: String {
        switch self {
        case .keychain(let s): return "Keychain read failed (\(s))"
        case .credentialFormat: return "Unexpected credential format"
        case .noCredentials(let hint): return hint
        case .http(401, let hint): return "Token stale — \(hint)"
        case .http(let code, _): return "HTTP \(code)"
        case .network(let m), .cswap(let m): return m
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
            return formatMoney(amountMinor / pow(10, Double(exponent ?? 2)), currency: currency)
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
            var extras: [Line] = []
            if let spend, spend.enabled == true, let pct = spend.percent {
                var detail = ""
                if let used = spend.used?.formatted, let limit = spend.limit?.formatted {
                    detail = "\(used) of \(limit)"
                }
                extras.append(Line(label: "Extra usage", value: "\(Int(pct.rounded()))%", detail: detail))
            }
            return Snapshot(rows: rows, extras: extras)
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
            var extras: [Line] = []
            if let credits, credits.hasCredits == true {
                extras.append(Line(label: "Credits", value: credits.unlimited == true
                    ? "unlimited" : formatCredits(credits.balance)))
            }
            return Snapshot(rows: rows, extras: extras)
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

// MARK: - cswap

// cswap (claude-swap) manages several Claude accounts and fetches their usage
// itself. In this mode the app only runs `cswap list --json` and reads its
// output: no Keychain read and no API call of its own. Every field is optional
// and unknown ones are ignored, since the schema only ever grows.

struct CswapList: Decodable {
    struct Window: Decodable {
        let pct: Double?
        let resetsAt: String?
    }

    struct Scoped: Decodable {
        let name: String?
        let pct: Double?
        let resetsAt: String?
    }

    // used and limit are dollars, not minor units (cswap divides by 100 itself).
    struct Spend: Decodable {
        let used: Double?
        let limit: Double?
        let pct: Double?
        let currency: String?
    }

    struct Usage: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?
        let scoped: [Scoped]?
        let spend: Spend?
    }

    struct Entry: Decodable {
        let number: Int?
        let email: String?
        let alias: String?
        let active: Bool?
        let usageStatus: String?
        let usage: Usage?
        let lastGoodUsage: Usage?
        let usageError: String?
        let loginExpiresAt: String?
    }

    struct Failure: Decodable {
        let message: String?
    }

    let activeAccountNumber: Int?
    let accounts: [Entry]?
    let error: Failure?
}

struct CswapSwitch: Decodable {
    let switched: Bool?
    let reason: String?
    let error: CswapList.Failure?
}

// A GUI app has no shell PATH, so look in the places cswap gets installed.
var cswapPath: String? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return ["\(home)/.local/bin/cswap", "/opt/homebrew/bin/cswap", "/usr/local/bin/cswap"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}

// Blocking, so call it off the main thread. The pipe is read on its own thread
// while we wait: a large payload can't deadlock on a full pipe, and a stuck
// process can't hang us past the timeout.
func runCswap(_ args: [String], timeout: TimeInterval = 20) throws -> (status: Int32, output: Data) {
    guard let path = cswapPath else {
        throw FetchError.cswap("cswap not found — install claude-swap")
    }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
    proc.environment = env
    let stdout = Pipe()
    proc.standardOutput = stdout
    proc.standardError = FileHandle.nullDevice
    proc.standardInput = FileHandle.nullDevice
    do {
        try proc.run()
    } catch {
        throw FetchError.cswap(error.localizedDescription)
    }
    var data = Data()
    let eof = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
        data = stdout.fileHandleForReading.readDataToEndOfFile()
        eof.signal()
    }
    if eof.wait(timeout: .now() + timeout) == .timedOut {
        proc.terminate()
        DispatchQueue.global(qos: .utility).async { proc.waitUntilExit() }
        throw FetchError.cswap("cswap timed out after \(Int(timeout))s")
    }
    proc.waitUntilExit()
    return (proc.terminationStatus, data)
}

// Runs a switch and returns the reason it didn't happen, or nil when it did.
// Switching rewrites credentials, so it gets longer than a read before we kill it.
func runCswapSwitch(_ args: [String]) -> String? {
    do {
        let (status, data) = try runCswap(args, timeout: 60)
        let result = try? JSONDecoder().decode(CswapSwitch.self, from: data)
        if status == 0 && result?.switched != false { return nil }
        return result?.reason ?? result?.error?.message
            ?? (status == 0 ? "Not switched" : "cswap exited with status \(status)")
    } catch {
        return "\(error)"
    }
}

final class CswapProvider: Provider {
    let code = "CC"
    let name = "Claude Code"

    private let lock = NSLock()
    private var inFlight = false
    private var rerun: ((Result<Snapshot, FetchError>) -> Void)?

    // Blocks until the read finishes, so callers run it off the main thread.
    // Reads never overlap: a plain call during a read is dropped, and a forced
    // one (after a switch, when the read in flight is already stale) runs again
    // as soon as that read finishes.
    func read(force: Bool, completion: @escaping (Result<Snapshot, FetchError>) -> Void) {
        lock.lock()
        if inFlight {
            if force { rerun = completion }
            lock.unlock()
            return
        }
        inFlight = true
        lock.unlock()
        var next: ((Result<Snapshot, FetchError>) -> Void)? = completion
        while let done = next {
            done(readOnce())
            lock.lock()
            next = rerun
            rerun = nil
            if next == nil { inFlight = false }
            lock.unlock()
        }
    }

    func fetch(completion: @escaping (Result<Snapshot, FetchError>) -> Void) {
        read(force: false, completion: completion)
    }

    private func readOnce() -> Result<Snapshot, FetchError> {
        let status: Int32
        let data: Data
        do {
            (status, data) = try runCswap(["list", "--json"])
        } catch let e as FetchError {
            return .failure(e)
        } catch {
            return .failure(.cswap(error.localizedDescription))
        }
        guard let list = try? JSONDecoder().decode(CswapList.self, from: data) else {
            return .failure(.cswap(status == 0 ? "Could not parse cswap output" : "cswap exited with status \(status)"))
        }
        if let err = list.error {
            return .failure(.cswap(err.message ?? "cswap reported an error"))
        }
        let entries = (list.accounts ?? []).filter { $0.number != nil }
        guard !entries.isEmpty else {
            return .failure(.cswap("No accounts — run `cswap add`"))
        }
        let accounts = entries.map { account($0, activeNumber: list.activeAccountNumber) }
        let active = zip(entries, accounts).first { $0.1.active }
        // The bar title reads live numbers only; stale ones show in the dropdown.
        return .success(Snapshot(rows: rows(active?.0.usage), label: active?.1.label, accounts: accounts))
    }

    private func account(_ e: CswapList.Entry, activeNumber: Int?) -> Account {
        let number = e.number ?? 0
        let shown = e.usage ?? e.lastGoodUsage
        var lines = rows(shown).map(\.line)
        if let spend = shown?.spend, let pct = spend.pct {
            var detail = ""
            if let used = spend.used, let limit = spend.limit,
               let u = formatMoney(used, currency: spend.currency),
               let l = formatMoney(limit, currency: spend.currency) {
                detail = "\(u) of \(l)"
            }
            lines.append(Line(label: "Extra usage", value: "\(Int(pct.rounded()))%", detail: detail))
        }
        var notes: [String] = []
        if e.usage == nil, let reason = reason(e, number: number) { notes.append(reason) }
        if let expires = parseISO(e.loginExpiresAt), expires.timeIntervalSinceNow < 3 * 86400 {
            notes.append(expires < Date() ? "Login expired" : "Login expires \(resetText(expires))")
        }
        let email = e.email ?? ""
        // cswap lowercases aliases; they read better as tags in capitals.
        let label = [e.alias?.uppercased(), email.split(separator: "@").last.map(String.init), e.email]
            .compactMap { $0 }.first { !$0.isEmpty } ?? "Account \(number)"
        return Account(number: number, label: label, active: e.active ?? (number == activeNumber),
                       lines: lines, notes: notes)
    }

    private func rows(_ usage: CswapList.Usage?) -> [Row] {
        guard let usage else { return [] }
        var rows: [Row] = []
        if let w = usage.fiveHour, let pct = w.pct {
            rows.append(Row(label: "Session (5h)", percent: pct, severity: nil, resetsAt: parseISO(w.resetsAt)))
        }
        if let w = usage.sevenDay, let pct = w.pct {
            rows.append(Row(label: "Week (all)", percent: pct, severity: nil, resetsAt: parseISO(w.resetsAt)))
        }
        for s in usage.scoped ?? [] {
            guard let pct = s.pct else { continue }
            rows.append(Row(label: "Week (\(s.name ?? "scoped"))", percent: pct, severity: nil,
                            resetsAt: parseISO(s.resetsAt)))
        }
        return rows
    }

    // Why an account has no live usage. Unknown statuses show as cswap sent them.
    private func reason(_ e: CswapList.Entry, number: Int) -> String? {
        switch e.usageStatus ?? "unavailable" {
        case "ok": return nil
        case "token_expired": return "Token stale — open Claude Code to refresh"
        case "relogin_required": return "Login expired — /login, then cswap add --slot \(number)"
        case "foreign_credential": return "Credential mismatch — switching repairs it"
        case "api_key": return "API key — no quota"
        case "keychain_unavailable": return "Keychain unavailable"
        case "no_credentials": return "No credentials"
        case "unavailable": return e.usageError ?? "Usage unavailable"
        case let other: return other
        }
    }
}

// MARK: - Formatting

func resetText(_ date: Date?) -> String {
    guard let date else { return "" }
    let fmt = DateFormatter()
    fmt.setLocalizedDateFormatFromTemplate(Calendar.current.isDateInToday(date) ? "jmm" : "EEE jmm")
    return fmt.string(from: date)
}

func formatMoney(_ value: Double, currency: String?) -> String? {
    let fmt = NumberFormatter()
    fmt.numberStyle = .currency
    fmt.currencyCode = currency ?? "USD"
    fmt.minimumFractionDigits = 0
    fmt.maximumFractionDigits = 2
    return fmt.string(from: NSNumber(value: value))
}

// Codex sends the balance as a string like "75000.0000000000".
func formatCredits(_ balance: String?) -> String {
    guard let balance else { return "?" }
    guard let value = Double(balance) else { return balance }
    let fmt = NumberFormatter()
    fmt.numberStyle = .decimal
    fmt.maximumFractionDigits = 0
    return fmt.string(from: NSNumber(value: value)) ?? balance
}

// Data rows are three columns: label, right-aligned value, reset. Tab stops are
// measured from the widest label and value in the menu, so a long model name
// widens the column instead of breaking it.
let dataFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

struct Columns {
    let value: CGFloat
    let detail: CGFloat

    init(_ lines: [Line]) {
        func width(_ s: String) -> CGFloat {
            ceil((s as NSString).size(withAttributes: [.font: dataFont]).width)
        }
        value = (lines.map { width($0.label) }.max() ?? 0) + 16 + (lines.map { width($0.value) }.max() ?? 0)
        detail = value + 12
    }
}

func dataTitle(_ line: Line, _ cols: Columns) -> NSAttributedString {
    let style = NSMutableParagraphStyle()
    style.tabStops = [NSTextTab(textAlignment: .right, location: cols.value),
                      NSTextTab(textAlignment: .left, location: cols.detail)]
    let text = NSMutableAttributedString(
        string: "\(line.label)\t\(line.value)",
        attributes: [.font: dataFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
    if !line.detail.isEmpty {
        text.append(NSAttributedString(
            string: "\t\(line.detail)",
            attributes: [.font: dataFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]))
    }
    return text
}

// MARK: - App

final class ProviderState {
    let provider: Provider
    var snapshot: Snapshot?
    var lastFetch: Date?
    var lastError: FetchError?
    // A failed switch, shown until a read that started after it succeeds.
    var note: (text: String, at: Date)?
    init(_ provider: Provider) { self.provider = provider }

    var title: String {
        guard let snapshot, let worst = snapshot.worst else { return "\(provider.code) –" }
        let pct = Int(worst.percent.rounded())
        let tag = snapshot.label.map { "\(provider.code) \($0)" } ?? provider.code
        return snapshot.flagged ? "\(tag) ⚠️ \(pct)%" : "\(tag) \(pct)%"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var cswapTimer: Timer?
    private let claude = ProviderState(ClaudeCode())
    private let cswap = ProviderState(CswapProvider())
    private let codex = ProviderState(Codex())
    private var menuOpen = false
    private var menuStale = false
    private var switching = false

    // Unset means on if cswap is installed. Never falls back to standard on its own.
    private var useCswap: Bool {
        get { UserDefaults.standard.object(forKey: "useCswap") as? Bool ?? (cswapPath != nil) }
        set { UserDefaults.standard.set(newValue, forKey: "useCswap") }
    }
    private var claudeState: ProviderState { useCswap ? cswap : claude }
    private var states: [ProviderState] { [claudeState, codex] }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = states.map { "\($0.provider.code) …" }.joined(separator: "  ")
        rebuildMenu()
        refreshAll()
        // Codex and standard Claude poll every 5 minutes; cswap mode adds a
        // 60-second read of cswap only.
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.fetch(self.codex)
            if !self.useCswap { self.fetch(self.claude) }
        }
        timer?.tolerance = 30
        scheduleCswapTimer()
    }

    private func scheduleCswapTimer() {
        cswapTimer?.invalidate()
        cswapTimer = nil
        guard useCswap else { return }
        cswapTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.fetch(self.cswap)
        }
        cswapTimer?.tolerance = 5
    }

    @objc func refreshAll() {
        states.forEach { fetch($0) }
    }

    // `force` is for the read right after a switch: it never clears the switch
    // note, and it runs even if a read was already in flight.
    private func fetch(_ state: ProviderState, force: Bool = false) {
        let started = Date()
        // The keychain read and the cswap call are blocking subprocess calls —
        // keep them off the main thread or the menu renders blank while it waits.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let done: (Result<Snapshot, FetchError>) -> Void = { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let snap):
                        state.snapshot = snap
                        state.lastFetch = Date()
                        state.lastError = nil
                        if !force, let note = state.note, started > note.at { state.note = nil }
                    case .failure(let e):
                        state.lastError = e
                        // cswap mode shows `CC –` rather than numbers it can't vouch for.
                        if state.provider is CswapProvider { state.snapshot = nil }
                    }
                    self.updateTitle()
                    self.rebuildMenu()
                }
            }
            if force, let provider = state.provider as? CswapProvider {
                provider.read(force: true, completion: done)
            } else {
                state.provider.fetch(completion: done)
            }
        }
    }

    private func updateTitle() {
        statusItem.button?.title = states.map(\.title).joined(separator: "  ")
    }

    // MARK: Menu

    // A rebuild while the dropdown is open would replace it under the cursor, so
    // it waits for the close. The bar title still updates.
    func menuWillOpen(_ menu: NSMenu) { menuOpen = true }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        // A chosen item's action fires after this; rebuild once it has.
        guard menuStale else { return }
        DispatchQueue.main.async { [weak self] in self?.rebuildMenu() }
    }

    private func rebuildMenu() {
        if menuOpen { menuStale = true; return }
        menuStale = false
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        let cols = Columns(states.flatMap { $0.snapshot?.lines ?? [] })
        let smallFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        @discardableResult
        func addText(_ title: String, font: NSFont = .systemFont(ofSize: NSFont.systemFontSize),
                     color: NSColor = .labelColor, indent: Int = 0) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.indentationLevel = indent
            item.attributedTitle = NSAttributedString(
                string: title, attributes: [.font: font, .foregroundColor: color])
            menu.addItem(item)
            return item
        }

        func addLine(_ line: Line, indent: Int = 0) {
            let item = NSMenuItem(title: line.label, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.indentationLevel = indent
            item.attributedTitle = dataTitle(line, cols)
            menu.addItem(item)
        }

        for (i, state) in states.enumerated() {
            if i > 0 { menu.addItem(.separator()) }
            addText(state.provider.name, font: .boldSystemFont(ofSize: NSFont.systemFontSize))
            if let snap = state.snapshot {
                if snap.accounts.isEmpty {
                    snap.lines.forEach { addLine($0) }
                }
                for account in snap.accounts {
                    let item = NSMenuItem(title: account.label, action: #selector(switchAccount(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = account.number
                    item.isEnabled = !account.active && !switching
                    if account.active {
                        item.state = .on
                        item.attributedTitle = NSAttributedString(
                            string: account.label,
                            attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                                         .foregroundColor: NSColor.labelColor])
                    }
                    menu.addItem(item)
                    account.lines.forEach { addLine($0, indent: 1) }
                    account.notes.forEach { addText($0, color: .secondaryLabelColor, indent: 1) }
                }
                if snap.accounts.count >= 2 {
                    let best = NSMenuItem(title: "Switch to most quota left", action: #selector(switchBest), keyEquivalent: "")
                    best.target = self
                    best.isEnabled = !switching
                    menu.addItem(best)
                    addText("Switching moves all running sessions within ~30s",
                            font: smallFont, color: .secondaryLabelColor, indent: 1)
                }
            }
            if state.provider is CswapProvider && switching { addText("Switching…", color: .secondaryLabelColor) }
            if let note = state.note?.text { addText(note) }
            if let err = state.lastError {
                addText("\(err)")
                if state.snapshot != nil, let lastFetch = state.lastFetch {
                    let fmt = DateFormatter()
                    fmt.timeStyle = .short
                    addText("Showing data from \(fmt.string(from: lastFetch))", color: .secondaryLabelColor)
                }
            }
        }

        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "Refresh now", action: #selector(refreshAll), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let loginItem = NSMenuItem(title: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        // Greyed out only when there's nothing to use and nothing to turn off.
        let cswapItem = NSMenuItem(title: "Use cswap", action: #selector(toggleCswap), keyEquivalent: "")
        cswapItem.target = self
        cswapItem.state = useCswap ? .on : .off
        cswapItem.isEnabled = useCswap || cswapPath != nil
        menu.addItem(cswapItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc func toggleCswap() {
        useCswap.toggle()
        scheduleCswapTimer()
        updateTitle()
        rebuildMenu()
        fetch(claudeState)
    }

    @objc func switchAccount(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? Int else { return }
        runSwitch(["switch", "\(number)", "--json"])
    }

    @objc func switchBest() {
        runSwitch(["switch", "--strategy", "best", "--json"])
    }

    private func runSwitch(_ args: [String]) {
        guard !switching else { return }
        switching = true
        rebuildMenu()
        DispatchQueue.global(qos: .userInitiated).async {
            let failure = runCswapSwitch(args)
            DispatchQueue.main.async {
                self.switching = false
                self.cswap.note = failure.map { ($0, Date()) }
                self.fetch(self.cswap, force: true)
            }
        }
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
