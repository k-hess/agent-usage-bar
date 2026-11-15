import AppKit
import SQLite3

// MARK: - Claude desktop windows

// Extra copies of the Claude desktop app, each on its own data folder and signed
// in to its own account, side by side with the main Claude. Claude has no
// single-instance lock, so `open -n` with `--user-data-dir` starts a second copy.
//
// Deliberately small: nothing here copies, moves or writes anything in Claude's
// own data folder. Each profile is a folder we create. The user signs in inside
// that window once and the sign-in stays there. The only read from the main data
// folder is `locale` and `userThemeMode`, to seed a new profile's config.json.
//
// The approach (second copy via --user-data-dir, process args via KERN_PROCARGS2)
// follows AI-Native-Lab/claude-multi-accounts; the code is our own.

// MARK: Profiles

struct ClaudeProfile: Codable, Equatable {
    let id: String
    var name: String
    // Relative to the storage root: `profiles/<id>`.
    let folder: String
}

enum ClaudeDesktopError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let text): return text }
    }
}

// profiles.json plus one 0700 folder per profile, under `root`.
struct ClaudeProfileStore {
    let root: URL

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentUsageBar/claude-desktop", isDirectory: true)
    }

    private var listURL: URL { root.appendingPathComponent("profiles.json") }

    func folderURL(_ profile: ClaudeProfile) -> URL {
        root.appendingPathComponent(profile.folder, isDirectory: true)
    }

    func load() -> [ClaudeProfile] {
        guard let data = try? Data(contentsOf: listURL),
              let list = try? JSONDecoder().decode([ClaudeProfile].self, from: data) else { return [] }
        return list
    }

    private func save(_ list: [ClaudeProfile]) throws {
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(list).write(to: listURL, options: .atomic)
    }

    // Unique ignoring case, after trimming. Returns the reason it's unusable, if any.
    func nameProblem(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Enter a name." }
        if load().contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return "A window named “\(name)” already exists."
        }
        return nil
    }

    func create(name raw: String, seed: [String: Any]) throws -> ClaudeProfile {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = nameProblem(name) { throw ClaudeDesktopError.message(problem) }
        let id = UUID().uuidString.lowercased()
        let profile = ClaudeProfile(id: id, name: name, folder: "profiles/\(id)")
        let folder = folderURL(profile)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !seed.isEmpty {
            let data = try JSONSerialization.data(withJSONObject: seed, options: [.prettyPrinted, .sortedKeys])
            let config = folder.appendingPathComponent("config.json")
            try data.write(to: config, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        }
        try save(load() + [profile])
        return profile
    }

    // The folder goes to the Trash, never rm: it holds the sign-in and whatever
    // the user kept in that window.
    func remove(_ profile: ClaudeProfile) throws {
        let folder = folderURL(profile)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        }
        try save(load().filter { $0.id != profile.id })
    }
}

// Just the two settings a window should open with, so a new window doesn't look
// foreign. Read-only on the main folder; takes the parsed config so it's testable.
func seedConfig(from main: [String: Any]?) -> [String: Any] {
    var seed: [String: Any] = [:]
    for key in ["locale", "userThemeMode"] {
        if let value = main?[key] { seed[key] = value }
    }
    return seed
}

func readMainClaudeConfig() -> [String: Any]? {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/config.json")
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

// MARK: Sign-in state

enum SignIn: Equatable {
    case signedOut
    // nil expiry: a session cookie, which lasts until Claude quits.
    case signedIn(expires: Date?)
}

enum ClaudeCookies {
    static let names = ["sessionKey", "sessionKeyV2", "sessionKeyV3"]
    // Chromium counts microseconds from 1601-01-01.
    static let epochOffset = 11_644_473_600.0

    static func date(fromChromium micros: Int64) -> Date {
        Date(timeIntervalSince1970: Double(micros) / 1_000_000 - epochOffset)
    }

    static func databaseURL(in folder: URL) -> URL? {
        // Newer Chromium keeps it under Network/.
        for path in ["Cookies", "Network/Cookies"] {
            let url = folder.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    // Reads name, host_key, expires_utc and has_expires, never the value columns.
    static func signIn(in folder: URL, now: Date = Date()) -> SignIn {
        guard let db = databaseURL(in: folder) else { return .signedOut }
        // Read-only keeps the live WAL visible; immutable is the fallback for a
        // database we can't open that way (no -shm and an unwritable folder).
        for query in ["mode=ro", "immutable=1"] {
            if let result = read(db, query: query, now: now) { return result }
        }
        return .signedOut
    }

    private static func read(_ db: URL, query: String, now: Date) -> SignIn? {
        var encoded = db.path
        encoded = encoded.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? encoded
        var handle: OpaquePointer?
        guard sqlite3_open_v2("file:\(encoded)?\(query)", &handle,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 500)
        let sql = "SELECT name, host_key, expires_utc, has_expires FROM cookies WHERE name IN ('sessionKey','sessionKeyV2','sessionKeyV3')"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        var cookies: [(host: String, expires: Int64, hasExpires: Bool)] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_ROW {
                let host = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                cookies.append((host, sqlite3_column_int64(stmt, 2), sqlite3_column_int(stmt, 3) != 0))
            } else if step == SQLITE_DONE {
                break
            } else {
                return nil
            }
        }
        return evaluate(cookies, now: now)
    }

    // Pure, so the self-test can feed it rows.
    static func evaluate(_ cookies: [(host: String, expires: Int64, hasExpires: Bool)], now: Date) -> SignIn {
        var latest: Date?
        var session = false
        for cookie in cookies where cookie.host == ".claude.ai" || cookie.host == "claude.ai" {
            if !cookie.hasExpires { session = true; continue }
            let expires = date(fromChromium: cookie.expires)
            if expires > now, latest == nil || expires > latest! { latest = expires }
        }
        if session { return .signedIn(expires: nil) }
        if let latest { return .signedIn(expires: latest) }
        return .signedOut
    }

    static func accountUUID(in folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("config.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["lastKnownAccountUuid"] as? String
    }
}

// MARK: Processes

struct ClaudeProcess {
    let pid: pid_t
    // The --user-data-dir this copy was started with; nil is the main Claude.
    let dataDir: String?
}

struct ProcessScan {
    var claude: [ClaudeProcess] = []
    var updaterRunning = false

    var mainRunning: Bool { claude.contains { $0.dataDir == nil } }
}

enum Processes {
    static let claudeSuffix = "Claude.app/Contents/MacOS/Claude"
    static let updaterSuffix = "Squirrel.framework/Resources/ShipIt"

    // Layout of KERN_PROCARGS2: argc (Int32), the executable path, NUL padding,
    // then argc NUL-terminated arguments (argv[0] first).
    static func parseArguments(_ buffer: [UInt8], size: Int) -> [String]? {
        let head = MemoryLayout<Int32>.size
        guard size > head, size <= buffer.count else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = head
        while i < size && buffer[i] != 0 { i += 1 }
        while i < size && buffer[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < argc && i < size {
            let start = i
            while i < size && buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    // Both `--user-data-dir=<path>` and `--user-data-dir <path>`.
    static func userDataDir(in args: [String]) -> String? {
        var i = 1
        while i < args.count {
            let arg = args[i]
            if arg.hasPrefix("--user-data-dir=") { return String(arg.dropFirst("--user-data-dir=".count)) }
            if arg == "--user-data-dir", i + 1 < args.count { return args[i + 1] }
            i += 1
        }
        return nil
    }

    static func arguments(of pid: pid_t) -> [String]? {
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        size = buffer.count
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseArguments(buffer, size: size)
    }

    // realpath, so /Users/x and a symlink to it compare equal.
    static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func scan() -> ProcessScan {
        var result = ProcessScan()
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return result }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 16)
        let filled = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return result }
        var path = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(Int(filled) / MemoryLayout<pid_t>.size) where pid > 0 {
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            let exe = String(cString: path)
            if exe.hasSuffix(updaterSuffix) {
                result.updaterRunning = true
            } else if exe.hasSuffix(claudeSuffix) {
                let dir = arguments(of: pid).flatMap(userDataDir(in:)).map(canonical)
                result.claude.append(ClaudeProcess(pid: pid, dataDir: dir))
            }
        }
        return result
    }
}

// MARK: Update relaunch

// When Claude updates, an idle copy quits to install and leaves `stealth-relaunch`
// in its data folder. The updater reopens only the main Claude, so side copies
// are reopened by us. Pure, so the self-test can walk the cases.
enum StealthRelaunch {
    static let maxAge: TimeInterval = 5 * 60

    static func timestamp(of note: [String: Any]) -> Double? {
        (note["ts"] as? NSNumber)?.doubleValue
    }

    private static func truthy(_ value: Any?) -> Bool {
        switch value {
        case let flag as Bool: return flag
        case let number as NSNumber: return number.doubleValue != 0
        case let text as String: return !text.isEmpty
        default: return false
        }
    }

    // Returns the note's ts when a relaunch is due, nil otherwise.
    static func due(note: [String: Any]?, now: Date, copyRunning: Bool, updaterRunning: Bool,
                    mainRunning: Bool, lastActed: Double?) -> Double? {
        guard let note, let ts = timestamp(of: note) else { return nil }
        guard !copyRunning, !updaterRunning, mainRunning else { return nil }
        guard !truthy(note["userQuit"]), !truthy(note["navOnly"]) else { return nil }
        let age = now.timeIntervalSince1970 - ts / 1000
        guard age < maxAge else { return nil }
        if let lastActed, lastActed == ts { return nil }
        return ts
    }

    static func readNote(in folder: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("stealth-relaunch")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

// MARK: Launching

enum ClaudeApp {
    static var url: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for path in ["/Applications/Claude.app", "\(home)/Applications/Claude.app"]
        where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    // Our own environment is kept so Claude behaves as it would from Finder, minus
    // the few variables that describe us (and would mislead or break Electron).
    static func launch(app: URL, folder: URL, background: Bool) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = (background ? ["-g"] : []) + ["-n", "-a", app.path, "--args", "--user-data-dir=\(folder.path)"]
        var env = ProcessInfo.processInfo.environment
        for key in ["__CFBundleIdentifier", "XPC_SERVICE_NAME", "ELECTRON_RUN_AS_NODE"] { env[key] = nil }
        process.environment = env
        let err = Pipe()
        process.standardError = err
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let data = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ClaudeDesktopError.message("Couldn't open Claude: \(text.isEmpty ? "open exited \(process.terminationStatus)" : text)")
        }
    }

    // Terminate is a normal quit. Never a force kill.
    static func quit(pid: pid_t) {
        if let app = NSRunningApplication(processIdentifier: pid) {
            if !app.terminate() { kill(pid, SIGTERM) }
        } else {
            kill(pid, SIGTERM)
        }
    }

    static func bringForward(pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
    }
}

// MARK: Model the menu reads

struct ClaudeWindowRow {
    let profile: ClaudeProfile
    let pid: pid_t?
    let signIn: SignIn
    let accountUUID: String?

    var isOpen: Bool { pid != nil }

    // `open`, `not signed in`, or `sign-in expires <date>` within 3 days.
    var status: String? {
        var parts: [String] = []
        if isOpen { parts.append("open") }
        switch signIn {
        case .signedOut:
            // A fresh window that's open and still at the sign-in screen is the
            // normal first state, and says so.
            parts.append("not signed in")
        case .signedIn(let expires):
            if let expires, expires.timeIntervalSinceNow < 3 * 24 * 3600 {
                let fmt = DateFormatter()
                fmt.dateStyle = .medium
                fmt.timeStyle = .none
                parts.append("sign-in expires \(fmt.string(from: expires))")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

// MARK: Controller

// Owns the profile list and what's running. AppDelegate calls in on the main
// thread and is told through `onChange` when to redraw.
final class ClaudeDesktop {
    let store: ClaudeProfileStore
    private(set) var rows: [ClaudeWindowRow] = []
    // Shown as a line in the section until the next good action.
    private(set) var error: String?
    var onChange: () -> Void = {}

    private var relaunchTimer: Timer?
    private var actedOn: [String: Double] = [:]
    private var busy = false
    var reopenAfterUpdates: () -> Bool = { true }

    init(store: ClaudeProfileStore = ClaudeProfileStore(root: ClaudeProfileStore.defaultRoot)) {
        self.store = store
        rows = store.load().map { ClaudeWindowRow(profile: $0, pid: nil, signIn: .signedOut, accountUUID: nil) }
    }

    var hasProfiles: Bool { !rows.isEmpty }

    // Cheap: one process scan and one small sqlite read per profile.
    func refresh() {
        let profiles = store.load()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let scan = Processes.scan()
            let rows = profiles.map { profile -> ClaudeWindowRow in
                let folder = self.store.folderURL(profile)
                let canon = Processes.canonical(folder.path)
                let pid = scan.claude.first { $0.dataDir == canon }?.pid
                return ClaudeWindowRow(profile: profile, pid: pid, signIn: ClaudeCookies.signIn(in: folder),
                                       accountUUID: ClaudeCookies.accountUUID(in: folder))
            }
            DispatchQueue.main.async {
                self.rows = rows
                self.syncRelaunchTimer()
                self.onChange()
            }
        }
    }

    private func fail(_ message: String) {
        error = message
        onChange()
    }

    private func settleSoon() {
        // The new process takes a moment to show up in the scan.
        for delay in [1.5, 5.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refresh() }
        }
    }

    // MARK: Actions

    func open(_ profile: ClaudeProfile) {
        if let pid = rows.first(where: { $0.profile.id == profile.id })?.pid {
            ClaudeApp.bringForward(pid: pid)
            return
        }
        launch(profile, background: false)
    }

    private func launch(_ profile: ClaudeProfile, background: Bool) {
        guard let app = ClaudeApp.url else { return fail("Claude isn't installed in /Applications.") }
        let folder = store.folderURL(profile)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try ClaudeApp.launch(app: app, folder: folder, background: background)
                DispatchQueue.main.async {
                    self?.error = nil
                    self?.settleSoon()
                }
            } catch {
                DispatchQueue.main.async { self?.fail("\(error)") }
            }
        }
    }

    func close(_ profile: ClaudeProfile) {
        guard let pid = rows.first(where: { $0.profile.id == profile.id })?.pid else { return }
        ClaudeApp.quit(pid: pid)
        error = nil
        settleSoon()
    }

    // Returns after the user's choice; refuses while the window is open.
    func remove(_ profile: ClaudeProfile) {
        if rows.first(where: { $0.profile.id == profile.id })?.isOpen == true {
            return fail("Close the “\(profile.name)” window before removing it.")
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Remove “\(profile.name)”?"
        alert.informativeText = "Its folder, including the sign-in kept there, moves to the Trash. Your main Claude isn't touched."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.remove(profile)
            error = nil
            refresh()
        } catch {
            fail("Couldn't remove “\(profile.name)”: \(error.localizedDescription)")
        }
    }

    func createAndOpen() {
        NSApp.activate(ignoringOtherApps: true)
        var problem: String?
        while true {
            let alert = NSAlert()
            alert.messageText = "New Claude window"
            alert.informativeText = problem ?? "Name this account. You'll sign in inside the window, once."
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            field.placeholderString = "Work"
            alert.accessoryView = field
            alert.addButton(withTitle: "Create")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if let why = store.nameProblem(field.stringValue) { problem = why; continue }
            do {
                let profile = try store.create(name: field.stringValue, seed: seedConfig(from: readMainClaudeConfig()))
                error = nil
                refresh()
                launch(profile, background: false)
            } catch {
                fail("Couldn't create the window: \(error.localizedDescription)")
            }
            return
        }
    }

    // MARK: Update relaunch

    // Runs only while a profile exists, so with none the app does no extra work.
    private func syncRelaunchTimer() {
        if hasProfiles, relaunchTimer == nil {
            relaunchTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                self?.relaunchTick()
            }
            relaunchTimer?.tolerance = 1
        } else if !hasProfiles {
            relaunchTimer?.invalidate()
            relaunchTimer = nil
        }
    }

    private func relaunchTick() {
        guard reopenAfterUpdates(), let app = ClaudeApp.url else { return }
        let profiles = rows.map(\.profile)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            // Look for the note first: nearly every tick has nothing to do.
            let noted = profiles.filter {
                FileManager.default.fileExists(atPath: self.store.folderURL($0).appendingPathComponent("stealth-relaunch").path)
            }
            guard !noted.isEmpty else { return }
            let scan = Processes.scan()
            for profile in noted {
                let folder = self.store.folderURL(profile)
                let canon = Processes.canonical(folder.path)
                let running = scan.claude.contains { $0.dataDir == canon }
                var last: Double?
                DispatchQueue.main.sync { last = self.actedOn[profile.id] }
                guard let ts = StealthRelaunch.due(
                    note: StealthRelaunch.readNote(in: folder), now: Date(), copyRunning: running,
                    updaterRunning: scan.updaterRunning, mainRunning: scan.mainRunning, lastActed: last) else { continue }
                DispatchQueue.main.sync { self.actedOn[profile.id] = ts }
                do {
                    try ClaudeApp.launch(app: app, folder: folder, background: true)
                    DispatchQueue.main.async { self.settleSoon() }
                } catch {
                    DispatchQueue.main.async { self.fail("\(error)") }
                }
            }
        }
    }
}

// MARK: - Self-test

// `AgentUsageBar --claude-desktop-selftest <tmpdir>`: checks the parts that can
// be checked without launching Claude. Exits 0 when every line passes.
func runClaudeDesktopSelfTest(root: String) -> Int32 {
    var failed = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        if !ok { failed += 1 }
    }

    let rootURL = URL(fileURLWithPath: root, isDirectory: true)
    try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let store = ClaudeProfileStore(root: rootURL.appendingPathComponent("claude-desktop", isDirectory: true))

    // Profiles
    let seed = seedConfig(from: ["locale": "en-US", "userThemeMode": "dark", "oauth:tokenCache": "SECRET"])
    check("seed copies only locale and userThemeMode", seed.count == 2 && seed["oauth:tokenCache"] == nil)
    guard let profile = try? store.create(name: "Work", seed: seed) else {
        check("create profile", false)
        return 1
    }
    let folder = store.folderURL(profile)
    let mode = (try? FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int) ?? 0
    check("profile folder created 0700", mode == 0o700, String(mode, radix: 8))
    check("profiles.json round-trips", store.load() == [profile])
    check("name unique ignoring case", store.nameProblem("work") != nil && store.nameProblem("Other") == nil)
    check("empty name refused", store.nameProblem("  ") != nil)
    let seeded = (try? Data(contentsOf: folder.appendingPathComponent("config.json")))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    check("config.json seeded", seeded?["locale"] as? String == "en-US")

    // Cookies: a fake database with names and expiries only.
    let now = Date()
    func chromium(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 + ClaudeCookies.epochOffset) * 1_000_000) }
    func makeCookies(_ rows: [(String, String, Int64, Int)]) -> Bool {
        let path = folder.appendingPathComponent("Cookies").path
        try? FileManager.default.removeItem(atPath: path)
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { return false }
        defer { sqlite3_close(db) }
        var ok = sqlite3_exec(db, "CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, expires_utc INTEGER, has_expires INTEGER)", nil, nil, nil) == SQLITE_OK
        for r in rows {
            ok = ok && sqlite3_exec(db, "INSERT INTO cookies VALUES ('\(r.0)', '\(r.1)', '', x'00', \(r.2), \(r.3))", nil, nil, nil) == SQLITE_OK
        }
        return ok
    }
    let future = now.addingTimeInterval(30 * 24 * 3600)
    check("no Cookies file is signed out", ClaudeCookies.signIn(in: folder, now: now) == .signedOut)
    _ = makeCookies([(".claude.ai", "sessionKey", chromium(future), 1), (".claude.ai", "sessionKeyV2", chromium(now.addingTimeInterval(-3600)), 1)])
    if case .signedIn(let expires?) = ClaudeCookies.signIn(in: folder, now: now) {
        check("future sessionKey is signed in, expiry parsed", abs(expires.timeIntervalSince(future)) < 1)
    } else {
        check("future sessionKey is signed in, expiry parsed", false)
    }
    _ = makeCookies([(".claude.ai", "sessionKey", chromium(now.addingTimeInterval(-3600)), 1)])
    check("only an expired sessionKey is signed out", ClaudeCookies.signIn(in: folder, now: now) == .signedOut)
    _ = makeCookies([("example.com", "sessionKey", chromium(future), 1), (".claude.ai", "other", chromium(future), 1)])
    check("other host or cookie name ignored", ClaudeCookies.signIn(in: folder, now: now) == .signedOut)
    _ = makeCookies([("claude.ai", "sessionKeyV3", 0, 0)])
    check("session cookie (no expiry) is signed in", ClaudeCookies.signIn(in: folder, now: now) == .signedIn(expires: nil))
    check("Chromium epoch parse", ClaudeCookies.date(fromChromium: 13_000_000_000_000_000).timeIntervalSince1970 == 13_000_000_000.0 - ClaudeCookies.epochOffset)
    let soon = ClaudeWindowRow(profile: profile, pid: nil, signIn: .signedIn(expires: now.addingTimeInterval(2 * 24 * 3600)), accountUUID: nil)
    let later = ClaudeWindowRow(profile: profile, pid: 1, signIn: .signedIn(expires: future), accountUUID: nil)
    check("status: expires within 3 days is shown", soon.status?.hasPrefix("sign-in expires") == true, soon.status ?? "nil")
    check("status: open, far expiry", later.status == "open", later.status ?? "nil")

    // Stealth relaunch decision
    let nowMs = now.timeIntervalSince1970 * 1000
    func due(_ note: [String: Any]?, copy: Bool = false, updater: Bool = false, main: Bool = true, last: Double? = nil) -> Bool {
        StealthRelaunch.due(note: note, now: now, copyRunning: copy, updaterRunning: updater, mainRunning: main, lastActed: last) != nil
    }
    check("relaunch: fresh note", due(["ts": nowMs - 10_000]))
    check("relaunch: stale note (6 min)", !due(["ts": nowMs - 6 * 60_000]))
    check("relaunch: userQuit", !due(["ts": nowMs - 10_000, "userQuit": true]))
    check("relaunch: navOnly", !due(["ts": nowMs - 10_000, "navOnly": true]))
    check("relaunch: userQuit false is fine", due(["ts": nowMs - 10_000, "userQuit": false]))
    check("relaunch: copy already running", !due(["ts": nowMs - 10_000], copy: true))
    check("relaunch: updater running", !due(["ts": nowMs - 10_000], updater: true))
    check("relaunch: main not running", !due(["ts": nowMs - 10_000], main: false))
    check("relaunch: once per ts", !due(["ts": nowMs - 10_000], last: nowMs - 10_000))
    check("relaunch: new ts after acting", due(["ts": nowMs - 10_000], last: nowMs - 90_000))
    check("relaunch: no note / no ts", !due(nil) && !due(["other": 1]))

    // KERN_PROCARGS2 buffer: argc, path, padding NULs, argv, then environment.
    var buffer: [UInt8] = []
    var argc: Int32 = 3
    withUnsafeBytes(of: &argc) { buffer += $0 }
    buffer += Array("/Applications/Claude.app/Contents/MacOS/Claude".utf8) + [0, 0, 0]
    for arg in ["/Applications/Claude.app/Contents/MacOS/Claude", "--user-data-dir=/tmp/a b/profiles/x", "--flag"] {
        buffer += Array(arg.utf8) + [0]
    }
    buffer += Array("HOME=/Users/x".utf8) + [0]
    let args = Processes.parseArguments(buffer, size: buffer.count)
    check("procargs: argc args parsed, env excluded", args?.count == 3 && args?[2] == "--flag", "\(args ?? [])")
    check("procargs: user-data-dir (= form)", args.flatMap(Processes.userDataDir(in:)) == "/tmp/a b/profiles/x")
    check("procargs: user-data-dir (split form)", Processes.userDataDir(in: ["Claude", "--user-data-dir", "/x/y"]) == "/x/y")
    check("procargs: main Claude has none", Processes.userDataDir(in: ["Claude"]) == nil)
    check("procargs: truncated buffer is safe", Processes.parseArguments([1, 0, 0], size: 3) == nil)
    check("procargs: live scan of this process", Processes.arguments(of: getpid())?.isEmpty == false)

    print(failed == 0 ? "ALL PASSED" : "\(failed) FAILED")
    return failed == 0 ? 0 : 1
}
