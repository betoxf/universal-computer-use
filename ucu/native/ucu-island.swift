// ucu-island: MacBook Notch Dynamic Island UI and encrypted secret vault for ucu.
//
// Runs as a single shared per-user daemon so concurrent chats queue cleanly on the notch and
// plaintext secrets stay inside one native process (CryptoKit AES-256-GCM + macOS Keychain master
// key + LocalAuthentication), never entering the LLM context or process arguments.
//
//   ucu-island serve                            run the Unix socket daemon (island.sock)
//   ucu-island version                          print version
//   ucu-island vault list                       list stored entries (metadata only)
//   ucu-island vault add <id> [--kind ...]      add or update an entry (secret read from stdin)
//   ucu-island vault remove <id>                delete an entry
//   ucu-island demo <passkey|approve|login|toast>   preview a Notch Island state live
//
// Build: `ucu install` (swiftc -O native/ucu-island.swift -o ~/.local/bin/ucu-island)
import AppKit
import CryptoKit
import Darwin
import Foundation
import LocalAuthentication
import QuartzCore
import Security

let VERSION = "ucu-island 1"
let APP_SUPPORT = NSHomeDirectory() + "/Library/Application Support/ucu"
let SOCKET_PATH = ProcessInfo.processInfo.environment["UCU_ISLAND_SOCKET"] ?? (APP_SUPPORT + "/island.sock")
let LOCK_PATH = ProcessInfo.processInfo.environment["UCU_ISLAND_LOCK"] ?? (APP_SUPPORT + "/island.lock")
let VAULT_PATH = ProcessInfo.processInfo.environment["UCU_VAULT_PATH"] ?? (APP_SUPPORT + "/vault.enc")
let APPROVALS_PATH = ProcessInfo.processInfo.environment["UCU_APPROVALS_PATH"] ?? (APP_SUPPORT + "/approvals.json")
let AUTH_PREFS_PATH = ProcessInfo.processInfo.environment["UCU_AUTH_PREFS_PATH"] ?? (APP_SUPPORT + "/auth-prefs.json")
let ACCOUNTS_PATH = ProcessInfo.processInfo.environment["UCU_ACCOUNTS_PATH"] ?? (APP_SUPPORT + "/accounts.json")
let KEYCHAIN_SERVICE = ProcessInfo.processInfo.environment["UCU_KEYCHAIN_SERVICE"] ?? "com.ucu.vault.master"
let KEYCHAIN_ACCOUNT = "default"
let SESSIONS_DIR = APP_SUPPORT + "/sessions"
let IDLE_EXIT_SECONDS: TimeInterval = 300

func fail(_ message: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

func colorFromHex(_ hex: String?) -> NSColor {
    guard let hex, hex.hasPrefix("#"), hex.count == 7,
          let value = UInt32(hex.dropFirst(), radix: 16) else {
        return NSColor(srgbRed: 0.35, green: 0.65, blue: 1.0, alpha: 1.0)
    }
    return NSColor(
        srgbRed: CGFloat((value >> 16) & 255) / 255.0,
        green: CGFloat((value >> 8) & 255) / 255.0,
        blue: CGFloat(value & 255) / 255.0,
        alpha: 1.0
    )
}

// Normalize a URL or host to a lowercase bare hostname without port or trailing dot.
func normalizeHost(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.contains("://"), let url = URL(string: trimmed), let host = url.host {
        return host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
    if let url = URL(string: "https://" + trimmed), let host = url.host, !host.isEmpty {
        return host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
    return trimmed.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
}

// Strict dot-boundary domain match: "github.com" matches "github.com" and "gist.github.com",
// never "evilgithub.com".
func hostMatches(_ host: String, allowed: String) -> Bool {
    guard let h = normalizeHost(host), let a = normalizeHost(allowed), !h.isEmpty, !a.isEmpty else {
        return false
    }
    return h == a || h.hasSuffix("." + a)
}

func slugify(_ text: String) -> String {
    let lowered = text.lowercased()
    var out = ""
    var dash = false
    for scalar in lowered.unicodeScalars {
        if CharacterSet.alphanumerics.contains(scalar) {
            out.unicodeScalars.append(scalar)
            dash = false
        } else if !dash && !out.isEmpty {
            out.append("-")
            dash = true
        }
    }
    let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return trimmed.isEmpty ? "secret-\(Int(Date().timeIntervalSince1970))" : String(trimmed.prefix(48))
}

func maskedPreview(_ secret: String, kind: String) -> String {
    if kind == "login" || secret.count <= 8 {
        return "••••••••"
    }
    return "\(secret.prefix(4))…\(secret.suffix(4))"
}

// MARK: - Keychain Master Key & Encrypted Vault

struct VaultEntry: Codable {
    var id: String
    var kind: String            // "login" | "api_key" | "secret"
    var label: String
    var domains: [String]       // normalized hosts allowed for this credential/secret
    var app: String?
    var username: String?
    var secret: String
    var autoApprove: Bool
    var allowedDestinations: [String]
    var createdAt: Double
    var lastUsedAt: Double?
    var ephemeral: Bool

    func metadata() -> [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "kind": kind,
            "label": label,
            "domains": domains,
            "preview": maskedPreview(secret, kind: kind),
            "auto_approve": autoApprove,
            "ephemeral": ephemeral,
            "created_at": createdAt,
        ]
        if let app, !app.isEmpty { dict["app"] = app }
        if let username, !username.isEmpty { dict["username"] = username }
        if !allowedDestinations.isEmpty { dict["allowed_destinations"] = allowedDestinations }
        if let lastUsedAt { dict["last_used_at"] = lastUsedAt }
        return dict
    }
}

struct AuthPref: Codable {
    var method: String          // "oauth" | "passkey" | "password" | "quick_login"
    var provider: String?       // "google" | "apple" | "github" | "microsoft"
    var account: String?        // optional email / profile name to pick automatically
    var updatedAt: Double

    func toDict() -> [String: Any] {
        var d: [String: Any] = ["method": method, "updated_at": updatedAt]
        if let provider, !provider.isEmpty { d["provider"] = provider }
        if let account, !account.isEmpty { d["account"] = account }
        return d
    }
}

// Learned account identity (no password needed — powers Google/Passkey 2-step sign-ins and account choosers!).
struct AccountProfile: Codable {
    var id: String
    var email: String
    var provider: String        // "google" | "apple" | "microsoft" | "email"
    var label: String
    var purpose: String         // e.g. "personal, dev, github" or "work, ommatrucking"
    var domains: [String]       // domains where this account has been used (learns over time!)
    var isDefault: Bool
    var useCount: Int
    var lastUsedAt: Double

    func toDict() -> [String: Any] {
        [
            "id": id,
            "email": email,
            "provider": provider,
            "label": label,
            "purpose": purpose,
            "domains": domains,
            "is_default": isDefault,
            "use_count": useCount,
            "last_used_at": lastUsedAt,
        ]
    }
}

struct VaultFile: Codable {
    var version: Int = 1
    var entries: [VaultEntry] = []
}

final class VaultStore {
    private let lock = NSLock()
    private var entries: [String: VaultEntry] = [:]
    private var rememberedKeys = Set<String>()
    private var loadedStamp: String?
    private var cachedKey: SymmetricKey?

    // Read or create the 32-byte AES-256 master key in macOS Keychain via `security -i`
    // (stdin pipe, never argv) so rebuilding `ucu-island` never triggers Keychain signature prompts.
    private func masterKey() throws -> SymmetricKey {
        if let cachedKey { return cachedKey }
        if let envHex = ProcessInfo.processInfo.environment["UCU_VAULT_TEST_KEY"],
           let bytes = Self.decodeHex(envHex), bytes.count == 32 {
            let key = SymmetricKey(data: bytes)
            cachedKey = key
            return key
        }
        if let existing = Self.readKeychainSecret(service: KEYCHAIN_SERVICE, account: KEYCHAIN_ACCOUNT),
           let bytes = Self.decodeHex(existing), bytes.count == 32 {
            let key = SymmetricKey(data: bytes)
            cachedKey = key
            return key
        }
        var raw = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, raw.count, &raw) == errSecSuccess else {
            throw NSError(domain: "ucu-island", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to generate random key"])
        }
        let hex = raw.map { String(format: "%02x", $0) }.joined()
        guard Self.writeKeychainSecret(service: KEYCHAIN_SERVICE, account: KEYCHAIN_ACCOUNT, secret: hex) else {
            throw NSError(domain: "ucu-island", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not store vault master key in macOS Keychain"])
        }
        let key = SymmetricKey(data: Data(raw))
        cachedKey = key
        return key
    }

    private static func decodeHex(_ hex: String) -> Data? {
        let clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count % 2 == 0 else { return nil }
        var data = Data(capacity: clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    private static func runSecurity(stdin: String) -> (Int32, String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["-i"]
        let inputPipe = Pipe(), outputPipe = Pipe(), errorPipe = Pipe()
        task.standardInput = inputPipe
        task.standardOutput = outputPipe
        task.standardError = errorPipe
        do {
            try task.run()
        } catch {
            return (-1, "")
        }
        if let data = stdin.data(using: .utf8) {
            inputPipe.fileHandleForWriting.write(data)
        }
        try? inputPipe.fileHandleForWriting.close()
        let outData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(data: outData, encoding: .utf8) ?? "")
    }

    private static func readKeychainSecret(service: String, account: String) -> String? {
        let cmd = "find-generic-password -s \(service) -a \(account) -w\n"
        let (status, out) = runSecurity(stdin: cmd)
        guard status == 0 else { return nil }
        let value = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func writeKeychainSecret(service: String, account: String, secret: String) -> Bool {
        let cmd = "add-generic-password -U -s \(service) -a \(account) -w \(secret)\n"
        let (status, _) = runSecurity(stdin: cmd)
        return status == 0
    }

    private func diskStamp() -> String? {
        var st = stat()
        guard stat(VAULT_PATH, &st) == 0 else { return nil }
        return "\(st.st_ino)-\(st.st_size)-\(st.st_mtimespec.tv_sec)-\(st.st_mtimespec.tv_nsec)"
    }

    private func ensureLoadedLocked() throws {
        let current = diskStamp()
        if current == loadedStamp { return }
        loadedStamp = current
        // Keep in-memory ephemeral entries; refresh persisted entries from disk.
        entries = entries.filter { $0.value.ephemeral }
        guard current != nil else { return }
        let url = URL(fileURLWithPath: VAULT_PATH)
        let cipher = try Data(contentsOf: url)
        guard !cipher.isEmpty else { return }
        let key = try masterKey()
        let box = try AES.GCM.SealedBox(combined: cipher)
        let plain = try AES.GCM.open(box, using: key)
        let file = try JSONDecoder().decode(VaultFile.self, from: plain)
        for entry in file.entries {
            entries[entry.id] = entry
        }
    }

    private func persistLocked() throws {
        let persisted = entries.values.filter { !$0.ephemeral }.sorted { $0.id < $1.id }
        let file = VaultFile(version: 1, entries: persisted)
        let plain = try JSONEncoder().encode(file)
        let key = try masterKey()
        let sealed = try AES.GCM.seal(plain, using: key)
        guard let combined = sealed.combined else {
            throw NSError(domain: "ucu-island", code: 3, userInfo: [NSLocalizedDescriptionKey: "AES-GCM seal failed"])
        }
        let dir = (VAULT_PATH as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let tmp = VAULT_PATH + ".tmp-\(ProcessInfo.processInfo.processIdentifier)"
        FileManager.default.createFile(atPath: tmp, contents: combined, attributes: [.posixPermissions: 0o600])
        _ = chmod(tmp, 0o600)
        if rename(tmp, VAULT_PATH) != 0 {
            try? FileManager.default.removeItem(atPath: tmp)
            throw NSError(domain: "ucu-island", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to save vault file"])
        }
        _ = chmod(VAULT_PATH, 0o600)
        loadedStamp = diskStamp()
    }

    func hasSecrets() -> Bool {
        lock.lock(); defer { lock.unlock() }
        try? ensureLoadedLocked()
        return !entries.isEmpty
    }

    func list(domain: String? = nil, app: String? = nil, kind: String? = nil) throws -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        try ensureLoadedLocked()
        let wantedHost = normalizeHost(domain)
        let wantedApp = app?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries.values
            .filter { entry in
                if let kind, !kind.isEmpty, entry.kind != kind { return false }
                if let wantedHost {
                    guard entry.domains.contains(where: { hostMatches(wantedHost, allowed: $0) }) else { return false }
                }
                if let wantedApp, !wantedApp.isEmpty {
                    guard entry.app?.lowercased() == wantedApp else { return false }
                }
                return true
            }
            .sorted { $0.id < $1.id }
            .map { $0.metadata() }
    }

    func store(id requestedId: String?, kind: String, label: String, domains: [String], app: String?,
               username: String?, secret: String, autoApprove: Bool, ephemeral: Bool,
               allowedDestinations: [String] = []) throws -> VaultEntry {
        lock.lock(); defer { lock.unlock() }
        try ensureLoadedLocked()
        let normDomains = Array(Set(domains.compactMap(normalizeHost))).sorted()
        let id = (requestedId?.isEmpty == false ? slugify(requestedId!) : nil)
            ?? slugify(label.isEmpty ? (normDomains.first ?? kind) : label)
        let existing = entries[id]
        let mergedDestinations = Array(Set((existing?.allowedDestinations ?? []) + allowedDestinations)).sorted()
        let entry = VaultEntry(
            id: id,
            kind: kind,
            label: label.isEmpty ? id : label,
            domains: normDomains.isEmpty ? (existing?.domains ?? []) : normDomains,
            app: (app?.isEmpty == false) ? app : existing?.app,
            username: (username?.isEmpty == false) ? username : existing?.username,
            secret: secret,
            autoApprove: autoApprove,
            allowedDestinations: mergedDestinations,
            createdAt: existing?.createdAt ?? Date().timeIntervalSince1970,
            lastUsedAt: existing?.lastUsedAt,
            ephemeral: ephemeral
        )
        entries[id] = entry
        if !ephemeral {
            try persistLocked()
        }
        return entry
    }

    func find(id: String?, domain: String?, app: String?, kind: String?, account: String? = nil) throws -> VaultEntry? {
        lock.lock(); defer { lock.unlock() }
        try ensureLoadedLocked()
        if let id, !id.isEmpty {
            return entries[id] ?? entries[slugify(id)]
        }
        let wantedHost = normalizeHost(domain)
        let wantedApp = app?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let wantedAcct = account?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = entries.values.filter { entry in
            if let kind, !kind.isEmpty, entry.kind != kind { return false }
            if let wantedHost {
                return entry.domains.contains { hostMatches(wantedHost, allowed: $0) }
            }
            if let wantedApp, !wantedApp.isEmpty {
                return entry.app?.lowercased() == wantedApp
            }
            return false
        }
        if let wantedAcct, !wantedAcct.isEmpty {
            if let exact = matches.first(where: { ($0.username?.lowercased() == wantedAcct) || ($0.label.lowercased() == wantedAcct) }) {
                return exact
            }
            if let partial = matches.first(where: { ($0.username?.lowercased().contains(wantedAcct) == true) || ($0.label.lowercased().contains(wantedAcct)) }) {
                return partial
            }
        }
        return matches.sorted { ($0.lastUsedAt ?? $0.createdAt) > ($1.lastUsedAt ?? $1.createdAt) }.first
    }

    func recordUse(id: String, addDestination: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[id] else { return }
        entry.lastUsedAt = Date().timeIntervalSince1970
        if let addDestination, !addDestination.isEmpty, !entry.allowedDestinations.contains(addDestination) {
            entry.allowedDestinations.append(addDestination)
            entry.allowedDestinations.sort()
        }
        entries[id] = entry
        if !entry.ephemeral {
            try? persistLocked()
        }
    }

    func delete(id: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        try ensureLoadedLocked()
        guard let removed = entries.removeValue(forKey: id) ?? entries.removeValue(forKey: slugify(id)) else {
            return false
        }
        if !removed.ephemeral {
            try persistLocked()
        }
        return true
    }

    func redact(_ text: String) -> String {
        lock.lock()
        try? ensureLoadedLocked()
        let pairs = entries.values
            .filter { $0.secret.count >= 8 }
            .map { ($0.id, $0.secret) }
            .sorted { $0.1.count > $1.1.count }
        lock.unlock()
        guard !pairs.isEmpty, !text.isEmpty else { return text }
        var out = text
        for (id, secret) in pairs {
            if out.contains(secret) {
                out = out.replacingOccurrences(of: secret, with: "[REDACTED:vault:\(id)]")
            }
        }
        return out
    }

    private var approvalsLoaded = false

    private func ensureApprovalsLoadedLocked() {
        guard !approvalsLoaded else { return }
        approvalsLoaded = true
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: APPROVALS_PATH)),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return }
        rememberedKeys.formUnion(list)
    }

    private func persistApprovalsLocked() {
        let sorted = Array(rememberedKeys).sorted()
        guard let data = try? JSONEncoder().encode(sorted) else { return }
        let dir = (APPROVALS_PATH as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let tmp = APPROVALS_PATH + ".tmp-\(ProcessInfo.processInfo.processIdentifier)"
        FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600])
        _ = chmod(tmp, 0o600)
        _ = rename(tmp, APPROVALS_PATH)
    }

    func isRemembered(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        ensureApprovalsLoadedLocked()
        return rememberedKeys.contains(key)
    }

    func rememberApproval(_ key: String, persist: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        ensureApprovalsLoadedLocked()
        rememberedKeys.insert(key)
        if persist { persistApprovalsLocked() }
    }

    // Per-site remembered preferred sign-in method (e.g. github.com -> oauth:google, linear.app -> passkey)
    private var authPrefs: [String: AuthPref] = [:]
    private var authPrefsLoaded = false

    private func ensureAuthPrefsLoadedLocked() {
        guard !authPrefsLoaded else { return }
        authPrefsLoaded = true
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: AUTH_PREFS_PATH)),
              let map = try? JSONDecoder().decode([String: AuthPref].self, from: data) else { return }
        authPrefs = map
    }

    private func persistAuthPrefsLocked() {
        guard let data = try? JSONEncoder().encode(authPrefs) else { return }
        let dir = (AUTH_PREFS_PATH as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let tmp = AUTH_PREFS_PATH + ".tmp-\(ProcessInfo.processInfo.processIdentifier)"
        FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600])
        _ = chmod(tmp, 0o600)
        _ = rename(tmp, AUTH_PREFS_PATH)
    }

    func authPref(for domain: String) -> AuthPref? {
        lock.lock(); defer { lock.unlock() }
        ensureAuthPrefsLoadedLocked()
        guard let host = normalizeHost(domain) else { return nil }
        if let exact = authPrefs[host] { return exact }
        for (saved, pref) in authPrefs where hostMatches(host, allowed: saved) {
            return pref
        }
        return nil
    }

    func setAuthPref(domain: String, method: String, provider: String? = nil, account: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        ensureAuthPrefsLoadedLocked()
        guard let host = normalizeHost(domain) else { return }
        let existing = authPrefs[host]
        let chosenAccount = (account?.isEmpty == false) ? account : existing?.account
        authPrefs[host] = AuthPref(
            method: method,
            provider: (provider?.isEmpty == false) ? provider?.lowercased() : nil,
            account: chosenAccount,
            updatedAt: Date().timeIntervalSince1970
        )
        persistAuthPrefsLocked()
    }

    // Learned account profiles (most-used accounts & which sites/purposes they belong to).
    private var accounts: [String: AccountProfile] = [:]
    private var accountsLoaded = false

    private func ensureAccountsLoadedLocked() {
        guard !accountsLoaded else { return }
        accountsLoaded = true
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: ACCOUNTS_PATH)),
              let list = try? JSONDecoder().decode([AccountProfile].self, from: data) else { return }
        for a in list { accounts[a.id] = a }
    }

    private func persistAccountsLocked() {
        let sorted = accounts.values.sorted { ($0.useCount, $0.lastUsedAt) > ($1.useCount, $1.lastUsedAt) }
        guard let data = try? JSONEncoder().encode(sorted) else { return }
        let dir = (ACCOUNTS_PATH as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let tmp = ACCOUNTS_PATH + ".tmp-\(ProcessInfo.processInfo.processIdentifier)"
        FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600])
        _ = chmod(tmp, 0o600)
        _ = rename(tmp, ACCOUNTS_PATH)
    }

    func listAccounts() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        ensureAccountsLoadedLocked()
        return accounts.values
            .sorted { ($0.isDefault ? 1 : 0, $0.useCount, $0.lastUsedAt) > ($1.isDefault ? 1 : 0, $1.useCount, $1.lastUsedAt) }
            .map { $0.toDict() }
    }

    func saveAccount(email: String, provider: String = "google", label: String = "", purpose: String = "",
                     domains: [String] = [], isDefault: Bool = false) -> AccountProfile {
        lock.lock(); defer { lock.unlock() }
        ensureAccountsLoadedLocked()
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = slugify(cleanEmail)
        let existing = accounts[id]
        let normDomains = Array(Set((existing?.domains ?? []) + domains.compactMap(normalizeHost))).sorted()
        let prov = provider.lowercased()
        if isDefault {
            for (k, var other) in accounts where other.provider == prov && k != id {
                other.isDefault = false
                accounts[k] = other
            }
        }
        let prof = AccountProfile(
            id: id,
            email: cleanEmail,
            provider: prov,
            label: label.isEmpty ? (existing?.label ?? cleanEmail) : label,
            purpose: purpose.isEmpty ? (existing?.purpose ?? "") : purpose,
            domains: normDomains,
            isDefault: isDefault || (existing?.isDefault ?? accounts.values.filter { $0.provider == prov }.isEmpty),
            useCount: (existing?.useCount ?? 0) + 1,
            lastUsedAt: Date().timeIntervalSince1970
        )
        accounts[id] = prof
        persistAccountsLocked()
        return prof
    }

    // Pick the best learned account for a login page (e.g. accounts.google.com for app_domain=github.com).
    // When `requireMatch` is true, an account must match the target/context domain, inferred provider, or explicit hint
    // (a default Google account must never be auto-filled onto an unrelated site like apple.com).
    func bestAccount(domain: String?, contextDomain: String?, provider: String?, hint: String?,
                     requireMatch: Bool = false) -> AccountProfile? {
        lock.lock(); defer { lock.unlock() }
        ensureAccountsLoadedLocked()
        guard !accounts.isEmpty else { return nil }
        let all = Array(accounts.values)
        let normDom = normalizeHost(domain)
        let normCtx = normalizeHost(contextDomain)
        let inferredProv: String? = {
            if let provider, !provider.isEmpty { return provider.lowercased() }
            if let normDom {
                if normDom.contains("google") { return "google" }
                if normDom.contains("apple") || normDom.contains("icloud") { return "apple" }
                if normDom.contains("microsoft") || normDom.contains("live.com") { return "microsoft" }
            }
            return nil
        }()
        if let hint, !hint.isEmpty {
            let low = hint.lowercased()
            if let exact = all.first(where: { $0.email.lowercased() == low }) { return exact }
            if let fuzzy = all.first(where: { $0.email.lowercased().contains(low) || $0.purpose.lowercased().contains(low) || $0.label.lowercased().contains(low) }) {
                return fuzzy
            }
        }
        func matchPoints(_ a: AccountProfile) -> Int {
            var s = 0
            if let normCtx, a.domains.contains(where: { hostMatches(normCtx, allowed: $0) }) { s += 100 }
            if let normDom, a.domains.contains(where: { hostMatches(normDom, allowed: $0) }) { s += 40 }
            if let inferredProv, a.provider == inferredProv { s += 50 }
            return s
        }
        func score(_ a: AccountProfile) -> (Int, Int, Double) {
            let m = matchPoints(a)
            let bonus = (a.isDefault && (!requireMatch || m > 0)) ? 20 : 0
            return (m + bonus, a.useCount, a.lastUsedAt)
        }
        let ranked = all.sorted { score($0) > score($1) }
        guard let top = ranked.first else { return nil }
        if requireMatch {
            guard matchPoints(top) > 0 else { return nil }
        } else {
            guard score(top).0 > 0 else { return nil }
        }
        return top
    }

    func recordAccountUse(email: String, domain: String?, contextDomain: String?) {
        lock.lock(); defer { lock.unlock() }
        ensureAccountsLoadedLocked()
        let id = slugify(email)
        guard var prof = accounts[id] else { return }
        prof.useCount += 1
        prof.lastUsedAt = Date().timeIntervalSince1970
        for d in [domain, contextDomain].compactMap(normalizeHost) where !prof.domains.contains(d) {
            prof.domains.append(d)
        }
        prof.domains.sort()
        accounts[id] = prof
        persistAccountsLocked()
    }
}

// MARK: - Notch Geometry & Dynamic Island Visual Surface

struct NotchGeometry {
    let screen: NSScreen
    let hasNotch: Bool
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let centerX: CGFloat
    let topY: CGFloat

    static func detect() -> NotchGeometry {
        let realScreens = NSScreen.screens.filter { $0.localizedName != "UCU Agent Desktop" }
        let pointer = NSEvent.mouseLocation
        let chosen = realScreens.first { $0.frame.contains(pointer) }
            ?? realScreens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.main
            ?? realScreens.first
            ?? NSScreen.screens[0]

        let safeTop = chosen.safeAreaInsets.top
        if safeTop > 0, let left = chosen.auxiliaryTopLeftArea, let right = chosen.auxiliaryTopRightArea {
            let width = max(140, right.minX - left.maxX)
            let center = (left.maxX + right.minX) / 2.0
            return NotchGeometry(
                screen: chosen,
                hasNotch: true,
                notchWidth: width,
                notchHeight: safeTop,
                centerX: center,
                topY: chosen.frame.maxY
            )
        }
        return NotchGeometry(
            screen: chosen,
            hasNotch: false,
            notchWidth: 160,
            notchHeight: 34,
            centerX: chosen.frame.midX,
            topY: chosen.frame.maxY - 8
        )
    }
}

// Pure black Dynamic Island panel that never steals focus unless the user clicks a credential field.
final class NotchPanel: NSPanel {
    var allowKeyFocus = false
    override var canBecomeKey: Bool { allowKeyFocus }
    override var canBecomeMain: Bool { false }
}

final class IslandBackdropView: NSView {
    static let padX: CGFloat = 24
    static let padBottom: CGFloat = 28

    var hasNotch = true { didSet { needsLayout = true } }
    var leftEar = true { didSet { needsLayout = true } }
    var rightEar = true { didSet { needsLayout = true } }
    var useShadowPadding = true { didSet { needsLayout = true } }
    var accentColor: NSColor = NSColor(white: 1.0, alpha: 0.25) {
        didSet { updateAccentRim() }
    }
    let contentContainer = NSView(frame: .zero)
    private let shapeLayer = CAShapeLayer()
    private let rimLayer = CAShapeLayer()
    private let pulseRimLayer = CAShapeLayer()

    var islandRect: CGRect {
        guard useShadowPadding else { return bounds }
        let px = bounds.width > Self.padX * 2 ? Self.padX : 0
        let pb = bounds.height > Self.padBottom ? Self.padBottom : 0
        return CGRect(x: px, y: pb, width: max(0, bounds.width - px * 2), height: max(0, bounds.height - pb))
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        shapeLayer.fillColor = NSColor.black.cgColor
        shapeLayer.shadowColor = NSColor.black.cgColor
        shapeLayer.shadowOpacity = 0.28
        shapeLayer.shadowRadius = 10
        shapeLayer.shadowOffset = CGSize(width: 0, height: -3)

        rimLayer.fillColor = NSColor.clear.cgColor
        rimLayer.strokeColor = NSColor(white: 1.0, alpha: 0.13).cgColor
        rimLayer.lineWidth = 1.0

        pulseRimLayer.fillColor = NSColor.clear.cgColor
        pulseRimLayer.strokeColor = NSColor.clear.cgColor
        pulseRimLayer.lineWidth = 1.6
        pulseRimLayer.lineCap = .round
        pulseRimLayer.opacity = 0

        layer?.addSublayer(shapeLayer)
        layer?.addSublayer(rimLayer)
        layer?.addSublayer(pulseRimLayer)
        contentContainer.wantsLayer = true
        addSubview(contentContainer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // Clicks in the transparent shadow buffer pass straight through to the user's windows beneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard islandRect.contains(point) else { return nil }
        return super.hitTest(point)
    }

    private func updateAccentRim() {
        pulseRimLayer.strokeColor = accentColor.withAlphaComponent(0.85).cgColor
        pulseRimLayer.shadowColor = accentColor.cgColor
        pulseRimLayer.shadowRadius = 6
        pulseRimLayer.shadowOpacity = 0.85
        pulseRimLayer.shadowOffset = .zero
    }

    // Futuristic holographic rim scan sweep along the island contour on open / agent switch.
    func sweepGlow(color: NSColor, duration: CFTimeInterval = 0.62) {
        accentColor = color
        pulseRimLayer.removeAllAnimations()
        pulseRimLayer.opacity = 1.0

        let startAnim = CABasicAnimation(keyPath: "strokeStart")
        startAnim.fromValue = 0.0
        startAnim.toValue = 0.72
        startAnim.duration = duration
        startAnim.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)

        let endAnim = CABasicAnimation(keyPath: "strokeEnd")
        endAnim.fromValue = 0.18
        endAnim.toValue = 1.0
        endAnim.duration = duration
        endAnim.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.30, 1.0)

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.0, 0.95, 0.75, 0.0]
        fade.keyTimes = [0.0, 0.18, 0.62, 1.0]
        fade.duration = duration

        let group = CAAnimationGroup()
        group.animations = [startAnim, endAnim, fade]
        group.duration = duration
        group.fillMode = .forwards
        group.isRemovedOnCompletion = true
        pulseRimLayer.add(group, forKey: "rimSweep")
        pulseRimLayer.opacity = 0.0
    }

    override func layout() {
        super.layout()
        let rect = islandRect
        contentContainer.frame = rect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let localRect = CGRect(origin: .zero, size: rect.size)
        let body = Self.islandPath(in: localRect, hasNotch: hasNotch, leftEar: leftEar, rightEar: rightEar)
        let rim = Self.rimPath(in: localRect, hasNotch: hasNotch, leftEar: leftEar, rightEar: rightEar)
        shapeLayer.frame = rect
        shapeLayer.path = body
        shapeLayer.shadowPath = body
        rimLayer.frame = rect
        rimLayer.path = rim
        pulseRimLayer.frame = rect
        pulseRimLayer.path = rim
        CATransaction.commit()
    }

    // Concave top-ear silhouette flowing seamlessly out of the MacBook notch, or floating pill without one.
    static func islandPath(in rect: CGRect, hasNotch: Bool, leftEar: Bool = true, rightEar: Bool = true) -> CGPath {
        if !hasNotch {
            let r = min(20, rect.height / 2, rect.width / 2)
            return CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: r, cornerHeight: r, transform: nil)
        }
        let earL: CGFloat = leftEar ? min(12, rect.height * 0.28) : 0
        let earR: CGFloat = rightEar ? min(12, rect.height * 0.28) : 0
        let bottomR: CGFloat = min(22, max(11, (rect.height - max(earL, earR)) * 0.65))
        let w = rect.width, h = rect.height
        let p = CGMutablePath()
        // In AppKit's non-flipped layer coordinates, y = h is the top edge (flush with display bezel).
        p.move(to: CGPoint(x: 0, y: h))
        if earL > 0 {
            p.addQuadCurve(to: CGPoint(x: earL, y: h - earL), control: CGPoint(x: earL, y: h))
        }
        p.addLine(to: CGPoint(x: earL, y: bottomR))
        p.addQuadCurve(to: CGPoint(x: earL + bottomR, y: 0), control: CGPoint(x: earL, y: 0))
        p.addLine(to: CGPoint(x: w - earR - bottomR, y: 0))
        p.addQuadCurve(to: CGPoint(x: w - earR, y: bottomR), control: CGPoint(x: w - earR, y: 0))
        if earR > 0 {
            p.addLine(to: CGPoint(x: w - earR, y: h - earR))
            p.addQuadCurve(to: CGPoint(x: w, y: h), control: CGPoint(x: w - earR, y: h))
        } else {
            p.addLine(to: CGPoint(x: w, y: h))
        }
        p.closeSubpath()
        return p
    }

    // Open hairline along the ears, sides and bottom only — never across the top display bezel.
    static func rimPath(in rect: CGRect, hasNotch: Bool, leftEar: Bool = true, rightEar: Bool = true) -> CGPath {
        if !hasNotch {
            return islandPath(in: rect, hasNotch: false)
        }
        let earL: CGFloat = leftEar ? min(12, rect.height * 0.28) : 0
        let earR: CGFloat = rightEar ? min(12, rect.height * 0.28) : 0
        let bottomR: CGFloat = min(22, max(11, (rect.height - max(earL, earR)) * 0.65))
        let w = rect.width, h = rect.height
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0.5, y: h))
        if earL > 0 {
            p.addQuadCurve(to: CGPoint(x: earL + 0.5, y: h - earL), control: CGPoint(x: earL + 0.5, y: h))
        }
        p.addLine(to: CGPoint(x: earL + 0.5, y: bottomR))
        p.addQuadCurve(to: CGPoint(x: earL + bottomR, y: 0.5), control: CGPoint(x: earL + 0.5, y: 0.5))
        p.addLine(to: CGPoint(x: w - earR - bottomR, y: 0.5))
        p.addQuadCurve(to: CGPoint(x: w - earR - 0.5, y: bottomR), control: CGPoint(x: w - earR - 0.5, y: 0.5))
        if earR > 0 {
            p.addLine(to: CGPoint(x: w - earR - 0.5, y: h - earR))
            p.addQuadCurve(to: CGPoint(x: w - 0.5, y: h), control: CGPoint(x: w - earR - 0.5, y: h))
        } else {
            p.addLine(to: CGPoint(x: w - 0.5, y: h))
        }
        return p
    }
}

final class PillButton: NSButton {
    var fillColor: NSColor
    var hoverColor: NSColor
    var textColor: NSColor
    private let labelText: String
    private let symbolName: String?
    private var tracking: NSTrackingArea?
    private var hovered = false

    init(title: String, symbol: String? = nil, fill: NSColor, hover: NSColor, text: NSColor,
         target: AnyObject?, action: Selector?) {
        self.fillColor = fill
        self.hoverColor = hover
        self.textColor = text
        self.labelText = title
        self.symbolName = symbol
        super.init(frame: .zero)
        self.target = target
        self.action = action
        self.title = ""
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.masksToBounds = true
        updateBackground()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; updateBackground() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateBackground() }

    private func updateBackground() {
        layer?.backgroundColor = (hovered ? hoverColor : fillColor).cgColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: textColor,
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
        ]
        let textSize = (labelText as NSString).size(withAttributes: attrs)
        var iconImg: NSImage?
        var iconSize = NSSize.zero
        if let symbolName, let raw = NSImage(systemSymbolName: symbolName, accessibilityDescription: labelText) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 11.5, weight: .semibold)
            let styled = raw.withSymbolConfiguration(cfg) ?? raw
            iconSize = styled.size
            let tint = textColor
            iconImg = NSImage(size: iconSize, flipped: false) { dst in
                styled.draw(in: dst)
                tint.set()
                dst.fill(using: .sourceAtop)
                return true
            }
        }
        let gap: CGFloat = (iconImg != nil && !labelText.isEmpty) ? 5 : 0
        let groupW = iconSize.width + gap + textSize.width
        let startX = round((bounds.width - groupW) / 2)
        if let iconImg {
            iconImg.draw(in: NSRect(x: startX, y: round((bounds.height - iconSize.height) / 2),
                                    width: iconSize.width, height: iconSize.height))
        }
        if !labelText.isEmpty {
            (labelText as NSString).draw(
                at: CGPoint(x: startX + iconSize.width + gap, y: round((bounds.height - textSize.height) / 2) + 0.5),
                withAttributes: attrs
            )
        }
    }
}

// Compact toggle pill for single-line notch approval ("Always" ON by default, click to switch to "Once").
final class ScopeTogglePill: NSButton {
    private let onLabel: String
    private let offLabel: String
    private var tracking: NSTrackingArea?
    private var hovered = false

    init(onLabel: String, offLabel: String = "Once", on: Bool = true) {
        self.onLabel = onLabel
        self.offLabel = offLabel
        super.init(frame: .zero)
        setButtonType(.toggle)
        self.state = on ? .on : .off
        self.title = ""
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 11.5
        layer?.masksToBounds = true
        target = self
        action = #selector(toggled)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    @objc private func toggled() { needsDisplay = true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let isOn = (state == .on)
        let bg = isOn
            ? NSColor(srgbRed: 0.16, green: 0.72, blue: 0.48, alpha: hovered ? 0.36 : 0.25)
            : NSColor(white: 1.0, alpha: hovered ? 0.18 : 0.10)
        let border = isOn
            ? NSColor(srgbRed: 0.24, green: 0.86, blue: 0.60, alpha: 0.55)
            : NSColor(white: 1.0, alpha: 0.16)
        let fg = isOn
            ? NSColor(srgbRed: 0.45, green: 0.96, blue: 0.72, alpha: 1.0)
            : NSColor(white: 1.0, alpha: 0.65)
        layer?.backgroundColor = bg.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = border.cgColor

        let text = isOn ? onLabel : offLabel
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: fg,
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
        ]
        let sz = (text as NSString).size(withAttributes: attrs)
        var iconImg: NSImage?
        var iconSize = NSSize.zero
        let symName = isOn ? "infinity" : "1.circle"
        if let raw = NSImage(systemSymbolName: symName, accessibilityDescription: text) {
            let styled = raw.withSymbolConfiguration(.init(pointSize: 10.5, weight: .semibold)) ?? raw
            iconSize = styled.size
            iconImg = NSImage(size: iconSize, flipped: false) { dst in
                styled.draw(in: dst)
                fg.set()
                dst.fill(using: .sourceAtop)
                return true
            }
        }
        let gap: CGFloat = iconImg != nil ? 4 : 0
        let total = iconSize.width + gap + sz.width
        let x = round((bounds.width - total) / 2)
        if let iconImg {
            iconImg.draw(in: NSRect(x: x, y: round((bounds.height - iconSize.height) / 2),
                                    width: iconSize.width, height: iconSize.height))
        }
        (text as NSString).draw(at: CGPoint(x: x + iconSize.width + gap, y: round((bounds.height - sz.height) / 2) + 0.5),
                                withAttributes: attrs)
    }
}

// One-tap OAuth / Passkey button rendered inside the expanded Login Form when a page offers Google, Passkey, Apple, etc.
final class QuickAuthPill: NSButton {
    let authMethod: String
    let authProvider: String?
    private let labelText: String
    private var tracking: NSTrackingArea?
    private var hovered = false

    init(method: String, provider: String?, title: String, target: AnyObject?, action: Selector?) {
        self.authMethod = method
        self.authProvider = provider
        self.labelText = title
        super.init(frame: .zero)
        self.target = target
        self.action = action
        self.title = ""
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true
        updateBg()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; updateBg() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateBg() }

    private func updateBg() {
        layer?.backgroundColor = NSColor(white: 1.0, alpha: hovered ? 0.18 : 0.10).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1.0, alpha: hovered ? 0.30 : 0.16).cgColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
        ]
        let textSz = (labelText as NSString).size(withAttributes: attrs)
        let iconSide: CGFloat = 16
        let gap: CGFloat = 6
        let totalW = iconSide + gap + textSz.width
        let x0 = round((bounds.width - totalW) / 2)
        let iconRect = NSRect(x: x0, y: round((bounds.height - iconSide) / 2), width: iconSide, height: iconSide)

        if let provider = authProvider {
            let v = ProviderLogoView(provider: provider.lowercased(), size: iconSide)
            v.frame = NSRect(origin: .zero, size: iconRect.size)
            let img = NSImage(size: iconRect.size, flipped: false) { _ in
                v.draw(v.bounds)
                return true
            }
            img.draw(in: iconRect)
        } else if authMethod == "passwords", let sym = NSImage(systemSymbolName: "key.icloud.fill", accessibilityDescription: "Passwords") {
            let styled = sym.withSymbolConfiguration(.init(pointSize: 13.5, weight: .semibold)) ?? sym
            let sky = NSColor(srgbRed: 0.45, green: 0.74, blue: 1.0, alpha: 1.0)
            let tinted = NSImage(size: iconRect.size, flipped: false) { dst in
                styled.draw(in: dst)
                sky.set()
                dst.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: iconRect)
        } else if authMethod == "passkey", let sym = NSImage(systemSymbolName: "touchid", accessibilityDescription: "Passkey") {
            let styled = sym.withSymbolConfiguration(.init(pointSize: 14, weight: .medium)) ?? sym
            let rose = NSColor(srgbRed: 1.0, green: 0.27, blue: 0.42, alpha: 1.0)
            let tinted = NSImage(size: iconRect.size, flipped: false) { dst in
                styled.draw(in: dst)
                rose.set()
                dst.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: iconRect)
        }
        (labelText as NSString).draw(at: CGPoint(x: x0 + iconSide + gap, y: round((bounds.height - textSz.height) / 2) + 0.5),
                                     withAttributes: attrs)
    }
}

// High-contrast dark-mode checkbox that renders crisp on pure black regardless of system Light/Dark appearance.
final class DarkCheckButton: NSButton {
    private let labelText: String

    init(title: String, checked: Bool) {
        self.labelText = title
        super.init(frame: .zero)
        setButtonType(.toggle)
        self.state = checked ? .on : .off
        self.title = ""
        isBordered = false
        target = self
        action = #selector(toggled)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    @objc private func toggled() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setAllowsAntialiasing(true)
        let boxSize: CGFloat = 14
        let boxRect = CGRect(x: 0.5, y: round((bounds.height - boxSize) / 2), width: boxSize, height: boxSize)
        let boxPath = CGPath(roundedRect: boxRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        if state == .on {
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.addPath(boxPath); ctx.fillPath()
            // Crisp black checkmark (NSButton is flipped: y grows downward)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(1.85)
            ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.move(to: CGPoint(x: boxRect.minX + 3.2, y: boxRect.midY + 0.4))
            ctx.addLine(to: CGPoint(x: boxRect.minX + 5.8, y: boxRect.maxY - 3.6))
            ctx.addLine(to: CGPoint(x: boxRect.maxX - 3.0, y: boxRect.minY + 3.6))
            ctx.strokePath()
        } else {
            ctx.setFillColor(NSColor(white: 1.0, alpha: 0.08).cgColor)
            ctx.addPath(boxPath); ctx.fillPath()
            ctx.setStrokeColor(NSColor(white: 1.0, alpha: 0.42).cgColor)
            ctx.setLineWidth(1.1)
            ctx.addPath(boxPath); ctx.strokePath()
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(white: 1.0, alpha: 0.78),
            .font: NSFont.systemFont(ofSize: 11.5, weight: .regular),
        ]
        let sz = (labelText as NSString).size(withAttributes: attrs)
        (labelText as NSString).draw(at: CGPoint(x: boxSize + 8, y: round((bounds.height - sz.height) / 2)),
                                     withAttributes: attrs)
    }
}

final class PaddedTextFieldCell: NSTextFieldCell {
    private func textRect(_ rect: NSRect) -> NSRect {
        let lineH: CGFloat = 17
        let dy = max(2, floor((rect.height - lineH) / 2))
        return NSRect(x: rect.minX + 10, y: rect.minY + dy, width: max(0, rect.width - 20), height: lineH)
    }
    override func drawingRect(forBounds rect: NSRect) -> NSRect { textRect(rect) }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: textRect(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: textRect(rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}

final class PaddedSecureFieldCell: NSSecureTextFieldCell {
    private func textRect(_ rect: NSRect) -> NSRect {
        let lineH: CGFloat = 17
        let dy = max(2, floor((rect.height - lineH) / 2))
        return NSRect(x: rect.minX + 10, y: rect.minY + dy, width: max(0, rect.width - 20), height: lineH)
    }
    override func drawingRect(forBounds rect: NSRect) -> NSRect { textRect(rect) }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: textRect(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: textRect(rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}

final class ClickableTextField: NSTextField {
    var onFocusRequest: (() -> Void)?
    override class var cellClass: AnyClass? {
        get { PaddedTextFieldCell.self }
        set {}
    }
    override func mouseDown(with event: NSEvent) {
        onFocusRequest?()
        super.mouseDown(with: event)
    }
}

final class ClickableSecureField: NSSecureTextField {
    var onFocusRequest: (() -> Void)?
    override class var cellClass: AnyClass? {
        get { PaddedSecureFieldCell.self }
        set {}
    }
    override func mouseDown(with event: NSEvent) {
        onFocusRequest?()
        super.mouseDown(with: event)
    }
}

// MARK: - Agent Identity & Vector Harness Logos

struct AgentIdentity {
    let harness: String
    let harnessId: String
    let agent: String
    let color: NSColor

    static func from(_ req: [String: Any]) -> AgentIdentity {
        let who = (req["who"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitHarness = (req["harness"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitId = (req["harness_id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let explicitAgent = (req["agent"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let parts = who.split(separator: ":", maxSplits: 1).map(String.init)
        let rawHarness = !explicitHarness.isEmpty ? explicitHarness : (parts.first ?? "Agent")
        let rawAgent = !explicitAgent.isEmpty ? explicitAgent : (parts.count > 1 ? parts[1] : "session")

        let probe = (explicitId.isEmpty ? rawHarness : explicitId).lowercased()
        let (hid, hname): (String, String) = {
            if probe.contains("claude") { return ("claude", explicitHarness.isEmpty ? "Claude Code" : explicitHarness) }
            if probe.contains("cursor") { return ("cursor", explicitHarness.isEmpty ? "Cursor" : explicitHarness) }
            if probe.contains("codex") || probe.contains("openai") || probe.contains("chatgpt") {
                return ("codex", explicitHarness.isEmpty ? "Codex" : explicitHarness)
            }
            if probe.contains("opencode") { return ("opencode", explicitHarness.isEmpty ? "opencode" : explicitHarness) }
            if probe.contains("windsurf") || probe.contains("codeium") {
                return ("windsurf", explicitHarness.isEmpty ? "Windsurf" : explicitHarness)
            }
            let clean = rawHarness.isEmpty || rawHarness == "unknown" ? "Agent" : rawHarness
            return ("generic", clean)
        }()

        return AgentIdentity(
            harness: hname,
            harnessId: hid,
            agent: rawAgent.isEmpty || rawAgent == "?" ? "session" : rawAgent,
            color: colorFromHex(req["color"] as? String)
        )
    }
}

// Retina-crisp vector harness brand mark drawn directly with CoreGraphics (zero image asset dependencies).
final class HarnessLogoView: NSView {
    let harnessId: String
    let tint: NSColor

    init(harnessId: String, tint: NSColor, size: CGFloat) {
        self.harnessId = harnessId
        self.tint = tint
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let r = rect.width * 0.28
        let bgPath = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)

        switch harnessId {
        case "claude":
            ctx.setFillColor(NSColor(srgbRed: 0.20, green: 0.11, blue: 0.08, alpha: 1).cgColor)
            ctx.addPath(bgPath); ctx.fillPath()
            ctx.setStrokeColor(NSColor(srgbRed: 0.88, green: 0.49, blue: 0.35, alpha: 0.45).cgColor)
            ctx.setLineWidth(0.9); ctx.addPath(bgPath); ctx.strokePath()
            // Claude 10-ray starburst sparkle
            let cx = rect.midX, cy = rect.midY, outer = rect.width * 0.34, inner = rect.width * 0.10
            ctx.setStrokeColor(NSColor(srgbRed: 0.92, green: 0.53, blue: 0.38, alpha: 1).cgColor)
            ctx.setLineCap(.round)
            ctx.setLineWidth(max(1.25, rect.width * 0.085))
            for i in 0..<10 {
                let angle = CGFloat(i) * (.pi * 2.0 / 10.0) + 0.15
                let len = (i % 2 == 0) ? outer : outer * 0.80
                ctx.move(to: CGPoint(x: cx + cos(angle) * inner * 0.4, y: cy + sin(angle) * inner * 0.4))
                ctx.addLine(to: CGPoint(x: cx + cos(angle) * len, y: cy + sin(angle) * len))
            }
            ctx.strokePath()

        case "cursor":
            ctx.setFillColor(NSColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1).cgColor)
            ctx.addPath(bgPath); ctx.fillPath()
            ctx.setStrokeColor(NSColor(white: 1.0, alpha: 0.24).cgColor)
            ctx.setLineWidth(0.9); ctx.addPath(bgPath); ctx.strokePath()
            // Isometric 3D Cursor prism
            let cx = rect.midX, cy = rect.midY, rad = rect.width * 0.34
            func pt(_ deg: CGFloat) -> CGPoint {
                let a = deg * .pi / 180.0
                return CGPoint(x: cx + cos(a) * rad, y: cy + sin(a) * rad)
            }
            let top = pt(90), tr = pt(30), br = pt(-30), bot = pt(-90), bl = pt(-150), tl = pt(150), center = CGPoint(x: cx, y: cy)
            // Left shaded facet
            ctx.setFillColor(NSColor(white: 0.62, alpha: 1).cgColor)
            ctx.beginPath(); ctx.move(to: center); ctx.addLine(to: tl); ctx.addLine(to: bl); ctx.addLine(to: bot); ctx.closePath(); ctx.fillPath()
            // Right deeper facet
            ctx.setFillColor(NSColor(white: 0.38, alpha: 1).cgColor)
            ctx.beginPath(); ctx.move(to: center); ctx.addLine(to: bot); ctx.addLine(to: br); ctx.addLine(to: tr); ctx.closePath(); ctx.fillPath()
            // Lit top facet + bright pointer sheen
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.beginPath(); ctx.move(to: center); ctx.addLine(to: tr); ctx.addLine(to: top); ctx.addLine(to: tl); ctx.closePath(); ctx.fillPath()

        case "codex":
            ctx.setFillColor(NSColor(srgbRed: 0.06, green: 0.17, blue: 0.14, alpha: 1).cgColor)
            ctx.addPath(bgPath); ctx.fillPath()
            ctx.setStrokeColor(NSColor(srgbRed: 0.18, green: 0.83, blue: 0.66, alpha: 0.45).cgColor)
            ctx.setLineWidth(0.9); ctx.addPath(bgPath); ctx.strokePath()
            // 6-petal OpenAI / Codex geometric bloom
            let cx = rect.midX, cy = rect.midY, ring = rect.width * 0.16, pr = rect.width * 0.16
            ctx.setStrokeColor(NSColor(srgbRed: 0.30, green: 0.90, blue: 0.72, alpha: 1).cgColor)
            ctx.setLineWidth(max(1.1, rect.width * 0.075))
            for i in 0..<6 {
                let a = CGFloat(i) * (.pi / 3.0)
                let px = cx + cos(a) * ring, py = cy + sin(a) * ring
                ctx.addEllipse(in: CGRect(x: px - pr, y: py - pr, width: pr * 2, height: pr * 2))
            }
            ctx.strokePath()

        case "opencode":
            ctx.setFillColor(NSColor(srgbRed: 0.11, green: 0.13, blue: 0.17, alpha: 1).cgColor)
            ctx.addPath(bgPath); ctx.fillPath()
            ctx.setStrokeColor(NSColor(white: 1.0, alpha: 0.24).cgColor)
            ctx.setLineWidth(0.9); ctx.addPath(bgPath); ctx.strokePath()
            // Geometric `>_` terminal mark
            let w = rect.width, h = rect.height
            ctx.setStrokeColor(NSColor(srgbRed: 0.52, green: 0.88, blue: 0.98, alpha: 1).cgColor)
            ctx.setLineWidth(max(1.3, w * 0.095))
            ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.move(to: CGPoint(x: rect.minX + w * 0.24, y: rect.minY + h * 0.66))
            ctx.addLine(to: CGPoint(x: rect.minX + w * 0.46, y: rect.minY + h * 0.50))
            ctx.addLine(to: CGPoint(x: rect.minX + w * 0.24, y: rect.minY + h * 0.34))
            ctx.move(to: CGPoint(x: rect.minX + w * 0.52, y: rect.minY + h * 0.34))
            ctx.addLine(to: CGPoint(x: rect.minX + w * 0.76, y: rect.minY + h * 0.34))
            ctx.strokePath()

        case "windsurf":
            ctx.setFillColor(NSColor(srgbRed: 0.05, green: 0.17, blue: 0.19, alpha: 1).cgColor)
            ctx.addPath(bgPath); ctx.fillPath()
            ctx.setStrokeColor(NSColor(srgbRed: 0.13, green: 0.83, blue: 0.78, alpha: 0.45).cgColor)
            ctx.setLineWidth(0.9); ctx.addPath(bgPath); ctx.strokePath()
            let w = rect.width, h = rect.height
            ctx.setStrokeColor(NSColor(srgbRed: 0.16, green: 0.86, blue: 0.82, alpha: 1).cgColor)
            ctx.setLineWidth(max(1.4, w * 0.10))
            ctx.setLineCap(.round)
            for offset in [0.0, 0.20] as [CGFloat] {
                ctx.move(to: CGPoint(x: rect.minX + w * 0.22, y: rect.minY + h * (0.36 + offset)))
                ctx.addCurve(
                    to: CGPoint(x: rect.minX + w * 0.78, y: rect.minY + h * (0.48 + offset)),
                    control1: CGPoint(x: rect.minX + w * 0.42, y: rect.minY + h * (0.64 + offset)),
                    control2: CGPoint(x: rect.minX + w * 0.58, y: rect.minY + h * (0.24 + offset))
                )
            }
            ctx.strokePath()

        default:
            ctx.setFillColor(tint.withAlphaComponent(0.22).cgColor)
            ctx.addPath(bgPath); ctx.fillPath()
            ctx.setStrokeColor(tint.withAlphaComponent(0.55).cgColor)
            ctx.setLineWidth(0.9); ctx.addPath(bgPath); ctx.strokePath()
            if let sym = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Agent") {
                let color = self.tint
                let tinted = NSImage(size: NSSize(width: rect.width * 0.62, height: rect.height * 0.62), flipped: false) { dst in
                    sym.draw(in: dst)
                    color.set()
                    dst.fill(using: .sourceAtop)
                    return true
                }
                let s = rect.width * 0.62
                tinted.draw(in: NSRect(x: rect.midX - s / 2, y: rect.midY - s / 2, width: s, height: s))
            }
        }
    }
}

// Crisp vector OAuth / sign-in provider marks (Google 4-color G, Apple, GitHub, Microsoft).
final class ProviderLogoView: NSView {
    let provider: String

    init(provider: String, size: CGFloat) {
        self.provider = provider
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    static func detect(from text: String) -> String? {
        let low = text.lowercased()
        if low.contains("google") { return "google" }
        if low.contains("apple") { return "apple" }
        if low.contains("github") { return "github" }
        if low.contains("microsoft") { return "microsoft" }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)

        switch provider {
        case "google":
            // Clean white circular badge with crisp 4-color Google "G" arcs + crossbar
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: rect)
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let r = rect.width * 0.31
            let lw = max(2.1, rect.width * 0.145)
            ctx.setLineWidth(lw)
            ctx.setLineCap(.butt)
            func arc(_ startDeg: CGFloat, _ endDeg: CGFloat, _ color: NSColor) {
                ctx.setStrokeColor(color.cgColor)
                ctx.addArc(center: c, radius: r, startAngle: startDeg * .pi / 180,
                           endAngle: endDeg * .pi / 180, clockwise: false)
                ctx.strokePath()
            }
            let red = NSColor(srgbRed: 0.92, green: 0.26, blue: 0.21, alpha: 1)
            let yellow = NSColor(srgbRed: 0.98, green: 0.74, blue: 0.02, alpha: 1)
            let green = NSColor(srgbRed: 0.20, green: 0.66, blue: 0.33, alpha: 1)
            let blue = NSColor(srgbRed: 0.26, green: 0.52, blue: 0.96, alpha: 1)
            // AppKit CGContext y grows upward: 0° right, 90° top, 180° left, 270° bottom
            arc(42, 152, red)
            arc(152, 212, yellow)
            arc(212, 316, green)
            arc(316, 362, blue)
            // Horizontal blue crossbar of the "G"
            ctx.setStrokeColor(blue.cgColor)
            ctx.setLineWidth(lw * 0.92)
            ctx.setLineCap(.butt)
            ctx.move(to: CGPoint(x: c.x - lw * 0.12, y: c.y))
            ctx.addLine(to: CGPoint(x: c.x + r + lw * 0.45, y: c.y))
            ctx.strokePath()

        case "microsoft":
            let pad = rect.width * 0.16
            let gap: CGFloat = 1.4
            let s = (rect.width - pad * 2 - gap) / 2
            let x0 = rect.minX + pad, y0 = rect.minY + pad
            let colors: [(CGFloat, CGFloat, NSColor)] = [
                (x0, y0 + s + gap, NSColor(srgbRed: 0.95, green: 0.31, blue: 0.13, alpha: 1)),
                (x0 + s + gap, y0 + s + gap, NSColor(srgbRed: 0.50, green: 0.73, blue: 0.00, alpha: 1)),
                (x0, y0, NSColor(srgbRed: 0.00, green: 0.64, blue: 0.94, alpha: 1)),
                (x0 + s + gap, y0, NSColor(srgbRed: 1.00, green: 0.73, blue: 0.00, alpha: 1)),
            ]
            for (x, y, col) in colors {
                ctx.setFillColor(col.cgColor)
                ctx.fill(CGRect(x: x, y: y, width: s, height: s))
            }

        case "apple":
            if let sym = NSImage(systemSymbolName: "apple.logo", accessibilityDescription: "Apple") {
                let sz = NSSize(width: rect.width * 0.76, height: rect.height * 0.86)
                let white = NSImage(size: sz, flipped: false) { dst in
                    sym.draw(in: dst)
                    NSColor.white.set()
                    dst.fill(using: .sourceAtop)
                    return true
                }
                white.draw(in: NSRect(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2,
                                      width: sz.width, height: sz.height))
            }

        default:
            ctx.setFillColor(NSColor(white: 1.0, alpha: 0.14).cgColor)
            ctx.fillEllipse(in: rect)
            if let sym = NSImage(systemSymbolName: "person.badge.key.fill", accessibilityDescription: provider) {
                let sz = NSSize(width: rect.width * 0.62, height: rect.height * 0.62)
                let white = NSImage(size: sz, flipped: false) { dst in
                    sym.draw(in: dst)
                    NSColor.white.set()
                    dst.fill(using: .sourceAtop)
                    return true
                }
                white.draw(in: NSRect(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2,
                                      width: sz.width, height: sz.height))
            }
        }
    }
}

// Crisp vector site badge (recognizes common domains, falls back cleanly to a deterministic colored monogram for any site).
final class SiteLogoView: NSView {
    let domain: String

    init(domain: String, size: CGFloat) {
        self.domain = domain.lowercased()
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private static func monogramColor(for host: String) -> NSColor {
        let palette: [NSColor] = [
            NSColor(srgbRed: 0.25, green: 0.52, blue: 0.96, alpha: 1),
            NSColor(srgbRed: 0.45, green: 0.36, blue: 0.96, alpha: 1),
            NSColor(srgbRed: 0.14, green: 0.68, blue: 0.54, alpha: 1),
            NSColor(srgbRed: 0.88, green: 0.42, blue: 0.22, alpha: 1),
            NSColor(srgbRed: 0.84, green: 0.28, blue: 0.56, alpha: 1),
            NSColor(srgbRed: 0.10, green: 0.62, blue: 0.78, alpha: 1),
        ]
        var h: UInt64 = 5381
        for b in host.utf8 { h = ((h << 5) &+ h) &+ UInt64(b) }
        return palette[Int(h % UInt64(palette.count))]
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)

        if domain.contains("google") {
            let g = ProviderLogoView(provider: "google", size: bounds.width)
            g.frame = bounds
            g.draw(dirtyRect)
            return
        }
        if domain.contains("vercel") {
            ctx.setFillColor(NSColor(white: 0.14, alpha: 1).cgColor)
            ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(NSColor(white: 1.0, alpha: 0.24).cgColor)
            ctx.setLineWidth(0.9); ctx.strokeEllipse(in: rect)
            let cx = rect.midX, cy = rect.midY, s = rect.width * 0.28
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: cx, y: cy + s))
            ctx.addLine(to: CGPoint(x: cx + s * 1.12, y: cy - s * 0.78))
            ctx.addLine(to: CGPoint(x: cx - s * 1.12, y: cy - s * 0.78))
            ctx.closePath(); ctx.fillPath()
            return
        }
        if domain.contains("github") {
            ctx.setFillColor(NSColor(white: 0.16, alpha: 1).cgColor)
            ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(NSColor(white: 1.0, alpha: 0.28).cgColor)
            ctx.setLineWidth(0.9); ctx.strokeEllipse(in: rect)
            // Crisp minimal GitHub cat-head silhouette
            let cx = rect.midX, cy = rect.midY - rect.height * 0.04
            let rx = rect.width * 0.27, ry = rect.height * 0.22
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
            // Left & right cat ears
            for sign in [-1.0, 1.0] as [CGFloat] {
                ctx.beginPath()
                ctx.move(to: CGPoint(x: cx + sign * rx * 0.82, y: cy + ry * 0.35))
                ctx.addLine(to: CGPoint(x: cx + sign * rx * 0.76, y: cy + ry * 1.38))
                ctx.addLine(to: CGPoint(x: cx + sign * rx * 0.18, y: cy + ry * 0.85))
                ctx.closePath(); ctx.fillPath()
            }
            return
        }
        if domain.contains("stripe") {
            ctx.setFillColor(NSColor(srgbRed: 0.39, green: 0.36, blue: 1.0, alpha: 1).cgColor)
            let p = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.28, cornerHeight: rect.width * 0.28, transform: nil)
            ctx.addPath(p); ctx.fillPath()
            drawLetter("S", in: rect, color: .white)
            return
        }
        if domain.contains("facebook") {
            ctx.setFillColor(NSColor(srgbRed: 0.09, green: 0.47, blue: 0.95, alpha: 1).cgColor)
            ctx.fillEllipse(in: rect)
            drawLetter("f", in: rect, color: .white)
            return
        }
        if domain.contains("apple") {
            let a = ProviderLogoView(provider: "apple", size: bounds.width)
            a.frame = bounds
            a.draw(dirtyRect)
            return
        }
        // Universal fallback: crisp colored monogram badge for any domain
        let base = domain.replacingOccurrences(of: "www.", with: "")
        let initial = String((base.first ?? Character("•"))).uppercased()
        let col = Self.monogramColor(for: base)
        ctx.setFillColor(col.withAlphaComponent(0.92).cgColor)
        let p = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.28, cornerHeight: rect.width * 0.28, transform: nil)
        ctx.addPath(p); ctx.fillPath()
        drawLetter(initial, in: rect, color: .white)
    }

    private func drawLetter(_ ch: String, in rect: CGRect, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: rect.width * 0.56, weight: .bold),
            .foregroundColor: color,
        ]
        let sz = (ch as NSString).size(withAttributes: attrs)
        (ch as NSString).draw(at: CGPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2 + 0.5),
                              withAttributes: attrs)
    }
}

// MARK: - Pending UI Requests

enum IslandDecision {
    case approved(remembered: Bool, global: Bool)
    case denied
    case show
    case filled(username: String, secret: String, remember: Bool)
    case chooseAuth(method: String, provider: String?, remember: Bool)
    case timeout
}

final class InteractiveRequest {
    enum Kind {
        case approve(title: String, detail: String, badge: String, canShow: Bool, canRemember: Bool,
                     rememberLabel: String, canRememberGlobal: Bool, globalLabel: String,
                     requireTouchID: Bool, icon: String)
        case credential(kind: String, title: String, subtitle: String, badge: String, usernameHint: String,
                        canShow: Bool, defaultRemember: Bool, rememberLabel: String,
                        availableOAuth: [String], hasPasskey: Bool)
    }
    let id = UUID()
    let identity: AgentIdentity
    let kind: Kind
    let completion: (IslandDecision) -> Void
    var resolved = false

    init(identity: AgentIdentity, kind: Kind, completion: @escaping (IslandDecision) -> Void) {
        self.identity = identity
        self.kind = kind
        self.completion = completion
    }

    func finish(_ decision: IslandDecision) {
        guard !resolved else { return }
        resolved = true
        completion(decision)
    }
}

struct PasskeyBanner {
    let identity: AgentIdentity
    let prompt: String
    let detail: String
}

struct ActiveAgent {
    let sessionId: String
    var pid: pid_t?
    var identity: AgentIdentity
    var app: String
    var windowTitle: String
    var cgWindowId: CGWindowID?
    var action: String
    var cursorNorm: CGPoint?
    var updatedAt: Date
}

// The exact same rounded dart cursor that `ucu-window.swift` draws on screen, scaled for the notch pile.
// Highlighted state uses separation, lift, luminous glow and a crisp bottom accent bar — never a circle.
final class CursorDartView: NSView {
    let sessionId: String
    let tint: NSColor
    var selected: Bool
    var dimmed: Bool
    var onHover: ((String) -> Void)?
    var onClick: ((String) -> Void)?
    private var tracking: NSTrackingArea?

    init(sessionId: String, tint: NSColor, size: CGFloat, selected: Bool = false, dimmed: Bool = false) {
        self.sessionId = sessionId
        self.tint = tint
        self.selected = selected
        self.dimmed = dimmed
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds.insetBy(dx: -4, dy: -4),
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(sessionId)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(sessionId)
    }

    // Matches `AgentCursor.arrowPath` in `ucu-window.swift`.
    static func dartPath(center: CGPoint, scale: CGFloat) -> CGPath {
        let corners: [(x: CGFloat, y: CGFloat, r: CGFloat)] = [
            (-6, -6, 1.6), (10.4, 0.4, 1.4), (3.4, 3.4, 2.5), (0.4, 10.4, 1.4),
        ]
        let pts = corners.map { CGPoint(x: center.x + $0.x * scale, y: center.y - $0.y * scale) }
        let p = CGMutablePath()
        p.move(to: CGPoint(x: (pts[0].x + pts[3].x) / 2, y: (pts[0].y + pts[3].y) / 2))
        for (i, c) in corners.enumerated() {
            p.addArc(tangent1End: pts[i], tangent2End: pts[(i + 1) % 4], radius: c.r * scale)
        }
        p.closeSubpath()
        return p
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.saveGState()
        if dimmed { ctx.setAlpha(0.42) }

        let liftY: CGFloat = selected ? 2.2 : 0.0
        let center = CGPoint(x: bounds.midX, y: bounds.midY + liftY)

        // Soft directional aura glow (brighter & wider when highlighted, no circle border!)
        let glowAlpha: CGFloat = selected ? 0.85 : 0.48
        if let grad = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [tint.withAlphaComponent(glowAlpha).cgColor,
                     tint.withAlphaComponent(selected ? 0.22 : 0.06).cgColor,
                     tint.withAlphaComponent(0.0).cgColor] as CFArray,
            locations: [0.0, 0.45, 1.0]
        ) {
            ctx.drawRadialGradient(grad, startCenter: center, startRadius: 0,
                                   endCenter: center, endRadius: bounds.width * (selected ? 0.54 : 0.46), options: [])
        }

        let scale = (bounds.width / 26.0) * (selected ? 1.18 : 0.96)
        let path = Self.dartPath(center: CGPoint(x: center.x - 1.1 * scale, y: center.y + 1.1 * scale), scale: scale)
        let bodyColor = selected ? tint : (tint.blended(withFraction: 0.24, of: .black) ?? tint)
        ctx.addPath(path)
        ctx.setFillColor(bodyColor.cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(selected ? 1.0 : 0.88).cgColor)
        ctx.setLineWidth(max(1.0, (selected ? 1.55 : 1.15) * scale))
        ctx.setLineJoin(.round)
        ctx.strokePath()

        // Crisp glowing underline bar beneath the highlighted cursor
        if selected {
            let barW: CGFloat = 11
            let barH: CGFloat = 2.2
            let barRect = CGRect(x: bounds.midX - barW / 2, y: 1.5, width: barW, height: barH)
            ctx.setFillColor(tint.cgColor)
            ctx.addPath(CGPath(roundedRect: barRect, cornerWidth: 1.1, cornerHeight: 1.1, transform: nil))
            ctx.fillPath()
        }
        ctx.restoreGState()
    }
}

final class HoverHostView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onMove: ((NSPoint) -> Void)?
    var onScroll: ((CGFloat) -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds.insetBy(dx: -8, dy: -6),
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
    override func mouseMoved(with event: NSEvent) {
        onMove?(convert(event.locationInWindow, from: nil))
    }
    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX)
    }
}

final class ClickablePreviewBox: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
}

// MARK: - Notch Island UI Controller (Main Thread Only)

final class NotchIslandController: NSObject, NSTextFieldDelegate {
    private var panel: NotchPanel?
    private var backdrop: IslandBackdropView?
    private var contentHost: NSView?
    private var queue: [InteractiveRequest] = []
    private var active: InteractiveRequest?
    private var passkey: PasskeyBanner?
    private var passkeyTimer: Timer?
    private var toastTimer: Timer?
    private var hotkeyMonitor: Any?
    private var previousApp: NSRunningApplication?

    // Active form controls
    private var usernameField: ClickableTextField?
    private var secretField: ClickableSecureField?
    private var rememberCheck: NSButton?
    private var globalRememberCheck: NSButton?
    private var approvalAlwaysOn = true
    private var approvalExpanded = false
    private var credentialExpanded = false
    private var credentialPinned = false
    private var credentialHoverExitTimer: Timer?
    private var authenticatingTouchID = false
    private var lastSecretLen = 0
    private var lastUsernameAutoAt = Date.distantPast
    private var autoSubmitWork: DispatchWorkItem?
    private var menuInstalled = false

    // Active agents using the computer (piled cursors on the left side of the notch + hover live preview)
    private var activeAgents: [ActiveAgent] = []
    private var hoveredAgentId: String?
    private var cursorHitZones: [(String, CGRect)] = []
    private var hoverExitTimer: Timer?
    private var hoverRefreshTimer: Timer?
    private var ambientWiggleTimer: Timer?
    private var globalMouseMonitor: Any?
    private var lastScrollCycle = Date.distantPast
    private var previewImages: [String: NSImage] = [:]
    private var lastCaptureAt: [String: Date] = [:]
    private var capturingSessions = Set<String>()
    private weak var livePreviewImageView: NSImageView?
    private var toastActive = false
    private let captureQueue = DispatchQueue(label: "ucu.island.preview", qos: .userInitiated)

    var isBusy: Bool { active != nil || passkey != nil || !queue.isEmpty || !activeAgents.isEmpty }

    // Standard Edit menu so Cmd+V and macOS Passwords AutoFill work cleanly inside our borderless panel.
    private func installEditMenuIfNeeded() {
        guard !menuInstalled else { return }
        menuInstalled = true
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let pwItem = NSMenuItem(title: "Passwords…", action: NSSelectorFromString("_handleInsertFromPasswordsCommand:"), keyEquivalent: "")
        editMenu.addItem(pwItem)
        editItem.submenu = editMenu
        main.addItem(editItem)
        NSApplication.shared.mainMenu = main
    }

    private func ensurePanel() -> (NotchPanel, IslandBackdropView, NSView) {
        installEditMenuIfNeeded()
        if let panel, let backdrop, let contentHost {
            return (panel, backdrop, contentHost)
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        let panel = NotchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 34),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false

        let backdrop = IslandBackdropView(frame: NSRect(x: 0, y: 0, width: 248, height: 62))
        backdrop.autoresizingMask = [.width, .height]
        backdrop.useShadowPadding = true
        let host = HoverHostView(frame: backdrop.contentContainer.bounds)
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.onEnter = { [weak self] in self?.onPointerEnteredIsland() }
        host.onExit = { [weak self] in self?.scheduleHoverExit() }
        host.onMove = { [weak self] pt in self?.onPointerMovedInIsland(pt) }
        host.onScroll = { [weak self] delta in self?.onScrollCycleAgents(delta) }
        backdrop.contentContainer.addSubview(host)
        panel.contentView = backdrop

        self.panel = panel
        self.backdrop = backdrop
        self.contentHost = host
        return (panel, backdrop, host)
    }

    // MARK: Public API (call on main thread)

    func enqueue(_ request: InteractiveRequest) {
        queue.append(request)
        if active == nil {
            showNext()
        } else {
            refreshQueueBadge()
        }
    }

    func cancel(id: UUID) {
        if let idx = queue.firstIndex(where: { $0.id == id }) {
            let item = queue.remove(at: idx)
            item.finish(.timeout)
            refreshQueueBadge()
            return
        }
        if active?.id == id {
            finishActive(.timeout)
        }
    }

    func setPasskey(active isActive: Bool, identity: AgentIdentity, prompt: String?, detail: String?,
                    timeout: TimeInterval) {
        passkeyTimer?.invalidate()
        passkeyTimer = nil
        if isActive {
            passkey = PasskeyBanner(
                identity: identity,
                prompt: (prompt?.isEmpty == false ? prompt! : "Please touch the key"),
                detail: detail ?? ""
            )
            passkeyTimer = Timer.scheduledTimer(withTimeInterval: max(5, min(timeout, 120)), repeats: false) { [weak self] _ in
                self?.setPasskey(active: false, identity: identity, prompt: nil, detail: nil, timeout: 0)
            }
            if active == nil {
                toastTimer?.invalidate()
                toastTimer = nil
                renderPasskey(passkey!)
            }
        } else {
            passkey = nil
            if active == nil {
                showIdleState()
            }
        }
    }

    func showToast(identity: AgentIdentity, icon: String, text: String, duration: TimeInterval = 2.6) {
        // Never interrupt an active approval, credential form, or Touch ID prompt.
        guard active == nil, passkey == nil else { return }
        toastTimer?.invalidate()
        toastActive = true
        renderToast(identity: identity, icon: icon, text: text)
        toastTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.toastActive = false
            guard self.active == nil, self.passkey == nil else { return }
            self.showIdleState()
        }
    }

    // MARK: Active Agent Cursor Pile & Compact Hover Preview

    func updateAgent(sessionId: String, pid: pid_t?, identity: AgentIdentity, active isActive: Bool,
                     app: String?, windowTitle: String?, cgWindowId: CGWindowID?, action: String?,
                     cursorNorm: CGPoint?) {
        if !isActive {
            activeAgents.removeAll { $0.sessionId == sessionId }
            previewImages.removeValue(forKey: sessionId)
            lastCaptureAt.removeValue(forKey: sessionId)
            if hoveredAgentId == sessionId {
                hoveredAgentId = activeAgents.first?.sessionId
                if hoveredAgentId == nil { stopHoverRefresh() }
            }
        } else if let idx = activeAgents.firstIndex(where: { $0.sessionId == sessionId }) {
            activeAgents[idx].identity = identity
            if let pid { activeAgents[idx].pid = pid }
            if let app, !app.isEmpty { activeAgents[idx].app = app }
            if let windowTitle, !windowTitle.isEmpty { activeAgents[idx].windowTitle = windowTitle }
            if let cgWindowId, cgWindowId != 0 { activeAgents[idx].cgWindowId = cgWindowId }
            if let action, !action.isEmpty { activeAgents[idx].action = action }
            if let cursorNorm { activeAgents[idx].cursorNorm = cursorNorm }
            activeAgents[idx].updatedAt = Date()
            prewarmCapture(for: sessionId)
        } else {
            activeAgents.append(ActiveAgent(
                sessionId: sessionId,
                pid: pid,
                identity: identity,
                app: app ?? "",
                windowTitle: windowTitle ?? "",
                cgWindowId: (cgWindowId ?? 0) != 0 ? cgWindowId : nil,
                action: action ?? "Working…",
                cursorNorm: cursorNorm,
                updatedAt: Date()
            ))
            prewarmCapture(for: sessionId)
        }
        syncGlobalMouseMonitor()
        syncAmbientWiggle()
        if active == nil && passkey == nil && !toastActive {
            showIdleState()
            if isActive && hoveredAgentId == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
                    self?.wiggleCursor(sessionId: sessionId, subtle: true)
                }
            }
        }
    }

    // Occasional organic micro-wiggle so piled cursors feel subtly alive while driving the Mac (not constant!).
    private func syncAmbientWiggle() {
        if activeAgents.isEmpty {
            ambientWiggleTimer?.invalidate()
            ambientWiggleTimer = nil
        } else if ambientWiggleTimer == nil {
            scheduleNextWiggle()
        }
    }

    private func scheduleNextWiggle() {
        ambientWiggleTimer?.invalidate()
        guard !activeAgents.isEmpty else { ambientWiggleTimer = nil; return }
        let delay = Double.random(in: 3.4...6.8)
        ambientWiggleTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.active == nil && self.passkey == nil && !self.toastActive && self.hoveredAgentId == nil,
               let pick = self.activeAgents.randomElement() {
                self.wiggleCursor(sessionId: pick.sessionId, subtle: false)
            }
            self.scheduleNextWiggle()
        }
    }

    private func wiggleCursor(sessionId: String, subtle: Bool) {
        guard let host = contentHost,
              let dart = host.subviews.compactMap({ $0 as? CursorDartView }).first(where: { $0.sessionId == sessionId }),
              let layer = dart.layer else { return }
        // Pivot around the dart's center
        let frame = layer.frame
        if layer.anchorPoint != CGPoint(x: 0.5, y: 0.5) {
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: frame.midX, y: frame.midY)
        }
        layer.removeAnimation(forKey: "aliveWiggle")
        let angle: CGFloat = subtle ? 0.10 : 0.17
        let shift: CGFloat = subtle ? 1.4 : 2.3

        let rot = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        rot.values = [0, -angle, angle * 0.85, -angle * 0.45, 0]
        rot.keyTimes = [0, 0.25, 0.55, 0.80, 1.0]

        let dx = CAKeyframeAnimation(keyPath: "transform.translation.x")
        dx.values = [0, shift, -shift * 0.7, shift * 0.35, 0]
        dx.keyTimes = [0, 0.28, 0.58, 0.82, 1.0]

        let dy = CAKeyframeAnimation(keyPath: "transform.translation.y")
        dy.values = [0, shift * 0.65, -shift * 0.3, 0]
        dy.keyTimes = [0, 0.35, 0.72, 1.0]

        let group = CAAnimationGroup()
        group.animations = [rot, dx, dy]
        group.duration = subtle ? 0.32 : 0.44
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(group, forKey: "aliveWiggle")
    }

    private func syncGlobalMouseMonitor() {
        let needsMonitor = !activeAgents.isEmpty || isActiveCredential
        if !needsMonitor {
            if let globalMouseMonitor {
                NSEvent.removeMonitor(globalMouseMonitor)
                self.globalMouseMonitor = nil
            }
        } else if globalMouseMonitor == nil {
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
                DispatchQueue.main.async { self?.handleGlobalPointerMove() }
            }
        }
    }

    private var isActiveCredential: Bool {
        if let active, case .credential = active.kind { return true }
        return false
    }

    // Responsive 120Hz proximity & glide detection even while another app (Cursor, Chrome, etc.) is frontmost!
    private func handleGlobalPointerMove() {
        guard let panel, panel.isVisible, let backdrop else { return }
        let mouse = NSEvent.mouseLocation
        let islandInWindow = backdrop.islandRect
        let islandOnScreen = NSRect(
            x: panel.frame.minX + islandInWindow.minX,
            y: panel.frame.minY + islandInWindow.minY,
            width: islandInWindow.width,
            height: islandInWindow.height
        )

        // Compact single-line Login pill expands on hover (and stays pinned once you click into a field!).
        if let active, case .credential = active.kind {
            if credentialPinned { return }
            let pad: CGFloat = credentialExpanded ? 12 : 8
            if islandOnScreen.insetBy(dx: -pad, dy: -pad).contains(mouse) {
                credentialHoverExitTimer?.invalidate()
                credentialHoverExitTimer = nil
                if !credentialExpanded {
                    credentialExpanded = true
                    renderCredential(active, expanded: true)
                }
            } else if credentialExpanded {
                if credentialHoverExitTimer == nil {
                    credentialHoverExitTimer = Timer.scheduledTimer(withTimeInterval: 0.24, repeats: false) { [weak self] _ in
                        guard let self, let cur = self.active, case .credential = cur.kind, !self.credentialPinned else { return }
                        self.credentialHoverExitTimer = nil
                        self.credentialExpanded = false
                        self.renderCredential(cur, expanded: false)
                    }
                }
            }
            return
        }

        guard active == nil, passkey == nil, !toastActive, !activeAgents.isEmpty else { return }
        let pad: CGFloat = hoveredAgentId == nil ? 12 : 10
        if islandOnScreen.insetBy(dx: -pad, dy: -pad).contains(mouse) {
            cancelHoverExit()
            let localPt = NSPoint(x: mouse.x - islandOnScreen.minX, y: mouse.y - islandOnScreen.minY)
            if hoveredAgentId == nil {
                let pick = cursorHitZones.min(by: { abs($0.1.midX - localPt.x) < abs($1.1.midX - localPt.x) })?.0
                    ?? activeAgents.first?.sessionId
                if let pick { hoverAgent(pick) }
            } else {
                onPointerMovedInIsland(localPt)
            }
        } else if hoveredAgentId != nil {
            scheduleHoverExit()
        }
    }

    private func prewarmCapture(for sessionId: String) {
        if let last = lastCaptureAt[sessionId], -last.timeIntervalSinceNow < 2.0 { return }
        requestCapture(for: sessionId)
    }

    func sweepStaleAgents() {
        let now = Date()
        let before = activeAgents.count
        activeAgents.removeAll { agent in
            if let pid = agent.pid, kill(pid, 0) != 0 { return true }
            return now.timeIntervalSince(agent.updatedAt) > 150
        }
        if activeAgents.count != before {
            syncGlobalMouseMonitor()
            syncAmbientWiggle()
            if let hid = hoveredAgentId, !activeAgents.contains(where: { $0.sessionId == hid }) {
                hoveredAgentId = nil
                stopHoverRefresh()
            }
            if active == nil && passkey == nil && !toastActive {
                showIdleState()
            }
        }
    }

    private func showIdleState() {
        guard active == nil, passkey == nil else { return }
        if let hid = hoveredAgentId, let agent = activeAgents.first(where: { $0.sessionId == hid }) {
            renderAgentHover(agent)
            return
        }
        stopHoverRefresh()
        if !activeAgents.isEmpty {
            renderCursorPile()
        } else {
            collapse()
        }
    }

    private func hoverAgent(_ sessionId: String) {
        guard active == nil, passkey == nil else { return }
        cancelHoverExit()
        let changed = (hoveredAgentId != sessionId)
        hoveredAgentId = sessionId
        toastTimer?.invalidate()
        toastActive = false
        guard let agent = activeAgents.first(where: { $0.sessionId == sessionId }) else { return }
        if changed || livePreviewImageView == nil {
            renderAgentHover(agent)
        }
        startHoverRefresh(for: sessionId)
    }

    private func onPointerEnteredIsland() {
        cancelHoverExit()
        // Getting close to the resting left-side cursor pile immediately opens the first agent's preview!
        if active == nil && passkey == nil && !toastActive && hoveredAgentId == nil, let first = activeAgents.first {
            hoverAgent(first.sessionId)
        }
    }

    private func onPointerMovedInIsland(_ point: NSPoint) {
        guard active == nil, passkey == nil, !toastActive, !cursorHitZones.isEmpty else { return }
        // Glide horizontally across the piled cursors (or nearby) to cycle smoothly through active screens.
        if let hit = cursorHitZones.first(where: { $0.1.contains(point) }) {
            if hoveredAgentId != hit.0 {
                hoverAgent(hit.0)
            }
            return
        }
        // Magnetic nearest-cursor cycling while pointer stays in the top cursor band.
        if let firstZone = cursorHitZones.first?.1, point.y >= firstZone.minY - 8 && point.y <= firstZone.maxY + 8,
           let minX = cursorHitZones.map(\.1.minX).min(), let maxX = cursorHitZones.map(\.1.maxX).max(),
           point.x >= minX - 10 && point.x <= maxX + 10 {
            if let nearest = cursorHitZones.min(by: { abs($0.1.midX - point.x) < abs($1.1.midX - point.x) }),
               hoveredAgentId != nearest.0 {
                hoverAgent(nearest.0)
            }
        }
    }

    private func onScrollCycleAgents(_ delta: CGFloat) {
        guard active == nil, passkey == nil, activeAgents.count > 1, abs(delta) > 2,
              -lastScrollCycle.timeIntervalSinceNow > 0.22 else { return }
        lastScrollCycle = Date()
        let currentIdx = activeAgents.firstIndex(where: { $0.sessionId == hoveredAgentId }) ?? 0
        let nextIdx = (currentIdx + (delta < 0 ? 1 : -1) + activeAgents.count) % activeAgents.count
        hoverAgent(activeAgents[nextIdx].sessionId)
    }

    private func cancelHoverExit() {
        hoverExitTimer?.invalidate()
        hoverExitTimer = nil
    }

    private func scheduleHoverExit() {
        guard hoveredAgentId != nil else { return }
        hoverExitTimer?.invalidate()
        hoverExitTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.hoveredAgentId = nil
            self.stopHoverRefresh()
            if self.active == nil && self.passkey == nil && !self.toastActive {
                self.showIdleState()
            }
        }
    }

    private func startHoverRefresh(for sessionId: String) {
        stopHoverRefresh()
        requestCapture(for: sessionId)
        hoverRefreshTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            guard let self, self.hoveredAgentId == sessionId else { return }
            self.requestCapture(for: sessionId)
        }
    }

    private func stopHoverRefresh() {
        hoverRefreshTimer?.invalidate()
        hoverRefreshTimer = nil
        livePreviewImageView = nil
    }

    private func requestCapture(for sessionId: String) {
        guard !capturingSessions.contains(sessionId),
              let agent = activeAgents.first(where: { $0.sessionId == sessionId }) else { return }
        capturingSessions.insert(sessionId)
        lastCaptureAt[sessionId] = Date()
        captureQueue.async { [weak self] in
            let img = Self.captureWindowThumbnail(for: agent)
            DispatchQueue.main.async {
                guard let self else { return }
                self.capturingSessions.remove(sessionId)
                guard let img else { return }
                self.previewImages[sessionId] = img
                if self.hoveredAgentId == sessionId {
                    self.livePreviewImageView?.image = img
                }
            }
        }
    }

    static func resolveCGWindowID(for agent: ActiveAgent) -> CGWindowID? {
        if let wid = agent.cgWindowId, wid != 0 { return wid }
        guard !agent.app.isEmpty else { return nil }
        let wantApp = agent.app.lowercased()
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let matches = list.filter { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let owner = (info[kCGWindowOwnerName as String] as? String)?.lowercased(),
                  let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  bounds.width > 120 && bounds.height > 80 else { return false }
            return owner == wantApp || owner.contains(wantApp) || wantApp.contains(owner)
        }
        if !agent.windowTitle.isEmpty,
           let titled = matches.first(where: { ($0[kCGWindowName as String] as? String)?.localizedCaseInsensitiveContains(agent.windowTitle) == true }),
           let num = titled[kCGWindowNumber as String] as? CGWindowID {
            return num
        }
        return matches.first?[kCGWindowNumber as String] as? CGWindowID
    }

    static func captureWindowThumbnail(for agent: ActiveAgent) -> NSImage? {
        guard let wid = resolveCGWindowID(for: agent) else { return nil }
        let tmp = NSTemporaryDirectory() + "ucu-thumb-\(wid)-\(ProcessInfo.processInfo.processIdentifier).jpg"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-o", "-t", "jpg", "-l\(wid)", tmp]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return NSImage(contentsOfFile: tmp)
    }

    private func focusAgentApp(_ agent: ActiveAgent) {
        guard !agent.app.isEmpty else { return }
        let want = agent.app.lowercased()
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName?.lowercased() == want) || ($0.bundleIdentifier?.lowercased() == want)
        }) {
            running.unhide()
            running.activate(options: [])
        }
    }

    // MARK: Queue Progression

    private func showNext() {
        removeHotkeyMonitor()
        autoSubmitWork?.cancel()
        autoSubmitWork = nil
        usernameField = nil
        secretField = nil
        rememberCheck = nil
        globalRememberCheck = nil
        approvalAlwaysOn = true
        approvalExpanded = false
        credentialExpanded = false
        credentialPinned = false
        credentialHoverExitTimer?.invalidate()
        credentialHoverExitTimer = nil
        authenticatingTouchID = false
        lastSecretLen = 0
        lastUsernameAutoAt = .distantPast

        guard !queue.isEmpty else {
            active = nil
            syncGlobalMouseMonitor()
            if let passkey {
                renderPasskey(passkey)
            } else {
                showIdleState()
            }
            return
        }
        toastTimer?.invalidate()
        toastActive = false
        stopHoverRefresh()
        hoveredAgentId = nil
        toastTimer = nil
        let next = queue.removeFirst()
        active = next
        syncGlobalMouseMonitor()
        switch next.kind {
        case .approve:
            renderApproval(next, expanded: false)
            installHotkeyMonitor()
        case .credential:
            renderCredential(next, expanded: false)
        }
    }

    private func finishActive(_ decision: IslandDecision) {
        let current = active
        active = nil
        if case .show = decision {
            // Do NOT reactivate the previous app when bringing the browser tab/window to the very front!
            panel?.allowKeyFocus = false
            previousApp = nil
        } else {
            restorePreviousAppIfNeeded()
        }
        current?.finish(decision)
        showNext()
    }

    private func refreshQueueBadge() {
        guard let active else { return }
        if case .approve = active.kind {
            renderApproval(active)
        }
    }

    // MARK: Focus Helpers

    private func requestTextInputFocus() {
        guard let panel else { return }
        credentialPinned = true
        credentialHoverExitTimer?.invalidate()
        credentialHoverExitTimer = nil
        if previousApp == nil {
            let front = NSWorkspace.shared.frontmostApplication
            if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previousApp = front
            }
        }
        panel.allowKeyFocus = true
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func restorePreviousAppIfNeeded() {
        panel?.allowKeyFocus = false
        if let prev = previousApp, !prev.isTerminated {
            prev.activate(options: [])
        }
        previousApp = nil
    }

    // MARK: Hotkeys for Zero-Focus-Steal Approve/Deny

    private func installHotkeyMonitor() {
        removeHotkeyMonitor()
        hotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.active != nil else { return }
            let mods = event.modifierFlags.intersection([.control, .option, .command, .shift])
            guard mods == [.control, .option] else { return }
            if event.keyCode == 36 || event.keyCode == 76 {  // Control+Option+Return -> Approve
                DispatchQueue.main.async { self.onApproveClicked() }
            } else if event.keyCode == 53 {  // Control+Option+Escape -> Deny
                DispatchQueue.main.async { self.onDenyClicked() }
            }
        }
    }

    private func removeHotkeyMonitor() {
        if let hotkeyMonitor {
            NSEvent.removeMonitor(hotkeyMonitor)
            self.hotkeyMonitor = nil
        }
    }

    // MARK: Frame & Futuristic Spring Animations

    private func paddedFrame(islandX: CGFloat, islandBottomY: CGFloat, islandW: CGFloat, islandH: CGFloat) -> NSRect {
        let px = IslandBackdropView.padX
        let pb = IslandBackdropView.padBottom
        return NSRect(
            x: round(islandX - px),
            y: round(islandBottomY - pb),
            width: round(islandW + px * 2),
            height: round(islandH + pb)
        )
    }

    private func present(width: CGFloat, height: CGFloat, geometry: NotchGeometry,
                         allowKey: Bool = false, glowColor: NSColor? = nil) {
        let (panel, backdrop, host) = ensurePanel()
        panel.allowKeyFocus = allowKey
        backdrop.hasNotch = geometry.hasNotch
        backdrop.leftEar = true
        backdrop.rightEar = true
        let earPad: CGFloat = geometry.hasNotch ? 24 : 0
        let islandW = width + earPad
        let target = paddedFrame(
            islandX: geometry.centerX - islandW / 2.0,
            islandBottomY: geometry.topY - height,
            islandW: islandW,
            islandH: height
        )
        animateFrame(panel: panel, backdrop: backdrop, host: host, target: target,
                     geometry: geometry, glowColor: glowColor)
    }

    // Asymmetric notch extension — anchors flush to the hardware notch's right edge so ONLY the left side opens!
    private func presentAsymmetric(leftExtra: CGFloat, rightExtra: CGFloat, height: CGFloat,
                                   geometry: NotchGeometry, glowColor: NSColor? = nil) {
        let (panel, backdrop, host) = ensurePanel()
        panel.allowKeyFocus = false
        backdrop.hasNotch = geometry.hasNotch
        backdrop.leftEar = geometry.hasNotch && leftExtra > 0
        backdrop.rightEar = geometry.hasNotch && rightExtra > 0
        let target: NSRect
        if geometry.hasNotch {
            let earL: CGFloat = leftExtra > 0 ? 12 : 0
            let earR: CGFloat = rightExtra > 0 ? 12 : 0
            let notchLeft = geometry.centerX - geometry.notchWidth / 2.0
            let islandW = earL + leftExtra + geometry.notchWidth + rightExtra + earR
            target = paddedFrame(
                islandX: notchLeft - leftExtra - earL,
                islandBottomY: geometry.topY - height,
                islandW: islandW,
                islandH: height
            )
        } else {
            let islandW = max(90, leftExtra + rightExtra + 28)
            target = paddedFrame(
                islandX: geometry.centerX - islandW / 2.0,
                islandBottomY: geometry.topY - height,
                islandW: islandW,
                islandH: height
            )
        }
        animateFrame(panel: panel, backdrop: backdrop, host: host, target: target,
                     geometry: geometry, glowColor: glowColor)
    }

    private func animateFrame(panel: NotchPanel, backdrop: IslandBackdropView, host: NSView,
                              target: NSRect, geometry: NotchGeometry, glowColor: NSColor?) {
        let openingFromNotch = !panel.isVisible || panel.alphaValue < 0.05
        if openingFromNotch {
            let startW = geometry.hasNotch ? geometry.notchWidth : min(110, target.width - IslandBackdropView.padX * 2)
            let startH = geometry.notchHeight
            let start = paddedFrame(
                islandX: geometry.centerX - startW / 2.0,
                islandBottomY: geometry.topY - startH,
                islandW: startW,
                islandH: startH
            )
            panel.setFrame(start, display: false)
            panel.alphaValue = 0.0
            panel.orderFrontRegardless()
        }
        // Futuristic elastic spring morph out of the hardware notch
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = openingFromNotch ? 0.34 : 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.12, 0.28, 1.0)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1.0
        }
        animateContentEntrance(host: host, strong: openingFromNotch)
        if let glowColor {
            backdrop.sweepGlow(color: glowColor, duration: openingFromNotch ? 0.68 : 0.48)
        }
    }

    private func animateContentEntrance(host: NSView, strong: Bool) {
        guard let layer = host.layer else { return }
        layer.removeAnimation(forKey: "contentIn")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = strong ? 0.0 : 0.62
        fade.toValue = 1.0
        fade.duration = strong ? 0.24 : 0.16
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let slide = CASpringAnimation(keyPath: "transform.translation.y")
        slide.fromValue = strong ? 7.0 : 3.0
        slide.toValue = 0.0
        slide.mass = 0.7
        slide.stiffness = 340
        slide.damping = 24
        slide.duration = slide.settlingDuration

        let scale = CASpringAnimation(keyPath: "transform.scale")
        scale.fromValue = strong ? 0.94 : 0.985
        scale.toValue = 1.0
        scale.mass = 0.7
        scale.stiffness = 340
        scale.damping = 25
        scale.duration = scale.settlingDuration

        let group = CAAnimationGroup()
        group.animations = [fade, slide, scale]
        group.duration = 0.32
        layer.add(group, forKey: "contentIn")
    }

    // Staged futuristic close: content micro-scales & dissolves first, then silhouette snaps cleanly into the notch.
    private func collapse() {
        removeHotkeyMonitor()
        restorePreviousAppIfNeeded()
        cursorHitZones = []
        guard let panel, panel.isVisible else { return }
        let geo = NotchGeometry.detect()
        let startW = geo.hasNotch ? geo.notchWidth : 92
        let startH = geo.hasNotch ? geo.notchHeight : 22
        let tucked = paddedFrame(
            islandX: geo.centerX - startW / 2.0,
            islandBottomY: geo.topY - startH,
            islandW: startW,
            islandH: startH
        )
        if let layer = contentHost?.layer {
            let fadeOut = CABasicAnimation(keyPath: "opacity")
            fadeOut.fromValue = 1.0
            fadeOut.toValue = 0.0
            fadeOut.duration = 0.12
            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.fromValue = 1.0
            shrink.toValue = 0.92
            shrink.duration = 0.12
            let g = CAAnimationGroup()
            g.animations = [fadeOut, shrink]
            g.duration = 0.12
            g.fillMode = .forwards
            g.isRemovedOnCompletion = false
            layer.add(g, forKey: "contentOut")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) { [weak self] in
            guard let self, self.active == nil, self.passkey == nil, self.activeAgents.isEmpty else {
                self?.contentHost?.layer?.removeAnimation(forKey: "contentOut")
                return
            }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.55, 0.0, 0.85, 0.18)
                panel.animator().setFrame(tucked, display: true)
                panel.animator().alphaValue = 0.0
            }, completionHandler: { [weak self] in
                guard let self, self.active == nil, self.passkey == nil, self.activeAgents.isEmpty else {
                    self?.contentHost?.layer?.removeAnimation(forKey: "contentOut")
                    return
                }
                self.contentHost?.layer?.removeAnimation(forKey: "contentOut")
                self.panel?.orderOut(nil)
                self.contentHost?.subviews.forEach { $0.removeFromSuperview() }
            })
        }
    }

    // MARK: Renderers (shared by live NSPanel and offscreen `render-preview`)

    // 0a. Active Agents Cursor Pile — super tight overlapping stack on ONLY the LEFT side of the notch!
    private func renderCursorPile() {
        let geo = NotchGeometry.detect()
        let (_, _, host) = ensurePanel()
        let layout = populateCursorPile(in: host, agents: activeAgents, geo: geo)
        presentAsymmetric(leftExtra: layout.leftExtra, rightExtra: 0, height: layout.height,
                          geometry: geo, glowColor: activeAgents.last?.identity.color)
    }

    @discardableResult
    func populateCursorPile(in host: NSView, agents: [ActiveAgent], geo: NotchGeometry) -> (leftExtra: CGFloat, height: CGFloat) {
        host.subviews.forEach { $0.removeFromSuperview() }
        cursorHitZones = []
        let shown = Array(agents.prefix(4))
        let overflow = max(0, agents.count - shown.count)
        let dartSize: CGFloat = 21
        let step: CGFloat = 9.5  // ultra-close overlapping deck!
        let pileW = dartSize + CGFloat(max(0, shown.count - 1)) * step + (overflow > 0 ? 18 : 0)
        let leftExtra = pileW + 14
        let height = max(geo.notchHeight, 32)
        let earL: CGFloat = geo.hasNotch ? 12 : 0
        let startX = geo.hasNotch ? (earL + 8) : 12

        for (i, agent) in shown.enumerated() {
            let x = startX + CGFloat(i) * step
            let frame = NSRect(x: x, y: round((height - dartSize) / 2), width: dartSize, height: dartSize)
            let dart = CursorDartView(sessionId: agent.sessionId, tint: agent.identity.color, size: dartSize)
            dart.frame = frame
            dart.onHover = { [weak self] sid in self?.hoverAgent(sid) }
            dart.onClick = { [weak self] sid in self?.hoverAgent(sid) }
            host.addSubview(dart)
            cursorHitZones.append((agent.sessionId, frame))
        }
        if overflow > 0 {
            let more = makeLabel("+\(overflow)", size: 10, weight: .semibold, color: NSColor(white: 1.0, alpha: 0.65))
            more.frame = NSRect(x: startX + CGFloat(shown.count - 1) * step + dartSize - 2,
                                y: round((height - 14) / 2), width: 18, height: 14)
            host.addSubview(more)
        }
        return (leftExtra, height)
    }

    // 0b. Symmetrical Centered Hover Live Preview (ONLY while hovering — resting pile stays strictly on the left!).
    //     Larger, clearer, proportional live viewport right beneath the notch with instant hover & glide cycling.
    private func renderAgentHover(_ agent: ActiveAgent) {
        let geo = NotchGeometry.detect()
        let (_, _, host) = ensurePanel()
        let size = populateAgentHover(in: host, agents: activeAgents, selected: agent,
                                      thumbnail: previewImages[agent.sessionId], geo: geo)
        present(width: size.width, height: size.height, geometry: geo, allowKey: false, glowColor: agent.identity.color)
    }

    @discardableResult
    func populateAgentHover(in host: NSView, agents: [ActiveAgent], selected: ActiveAgent,
                            thumbnail: NSImage?, geo: NotchGeometry) -> CGSize {
        host.subviews.forEach { $0.removeFromSuperview() }
        cursorHitZones = []
        let ear: CGFloat = geo.hasNotch ? 12 : 0
        let topH = max(geo.notchHeight, 34)
        let innerW: CGFloat = max(geo.notchWidth + 216, 402)  // symmetrical wings flanking notch (~108pt each side)
        let previewH: CGFloat = 248                           // crisp, readable ~1.50:1 proportional window preview
        let footerH: CGFloat = 34
        let totalH = topH + previewH + footerH + 16
        let totalW = innerW + ear * 2
        let topBandY = totalH - topH

        // Top-left wing (beside notch): closely grouped cursors with the hovered one cleanly separated & highlighted!
        let shown = Array(agents.prefix(4))
        let dartSize: CGFloat = 22
        let tightStep: CGFloat = 11
        let splitGap: CGFloat = 8
        var curX = ear + 10
        let selIdx = shown.firstIndex(where: { $0.sessionId == selected.sessionId }) ?? 0
        for (i, agent) in shown.enumerated() {
            let isSel = (i == selIdx)
            if i > 0 {
                let prevWasSel = (i - 1 == selIdx)
                curX += (isSel || prevWasSel) ? (tightStep + splitGap) : tightStep
            }
            let frame = NSRect(x: curX, y: topBandY + round((topH - dartSize) / 2), width: dartSize, height: dartSize)
            let dart = CursorDartView(sessionId: agent.sessionId, tint: agent.identity.color,
                                      size: dartSize, selected: isSel, dimmed: !isSel)
            dart.frame = frame
            dart.onHover = { [weak self] sid in self?.hoverAgent(sid) }
            dart.onClick = { [weak self] sid in
                self?.hoverAgent(sid)
                if let target = self?.activeAgents.first(where: { $0.sessionId == sid }) {
                    self?.focusAgentApp(target)
                }
            }
            host.addSubview(dart)
            cursorHitZones.append((agent.sessionId, frame))
        }

        if let topDart = host.subviews.compactMap({ $0 as? CursorDartView }).first(where: { $0.selected }) {
            topDart.removeFromSuperview()
            host.addSubview(topDart)
        }

        // Top-right wing (symmetrical beside notch): [Harness Logo 16x16] Harness
        let rightStart = geo.hasNotch ? (totalW / 2.0 + geo.notchWidth / 2.0 + 8) : (totalW / 2.0)
        let rightEnd = totalW - ear - 14
        let hMaxW = max(56, rightEnd - rightStart - 22)
        let hW = min(hMaxW, ceil((selected.identity.harness as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold)]).width) + 6)
        let hLabel = makeLabel(selected.identity.harness, size: 11.5, weight: .semibold, color: NSColor(white: 1.0, alpha: 0.90))
        hLabel.alignment = .right
        hLabel.lineBreakMode = .byTruncatingTail
        hLabel.frame = NSRect(x: rightEnd - hW, y: topBandY + (topH - 15) / 2, width: hW, height: 15)
        host.addSubview(hLabel)

        let logo = HarnessLogoView(harnessId: selected.identity.harnessId, tint: selected.identity.color, size: 16)
        logo.frame = NSRect(x: rightEnd - hW - 21, y: topBandY + (topH - 16) / 2, width: 16, height: 16)
        host.addSubview(logo)

        // Symmetrical centered live screen preview viewport ("what it's seeing")
        let bodyLeft = ear + 14
        let bodyW = innerW - 28
        let boxRect = NSRect(x: bodyLeft, y: footerH + 6, width: bodyW, height: previewH)
        let previewBox = ClickablePreviewBox(frame: boxRect)
        previewBox.wantsLayer = true
        previewBox.layer?.cornerRadius = 11
        previewBox.layer?.masksToBounds = true
        previewBox.layer?.backgroundColor = NSColor(srgbRed: 0.07, green: 0.08, blue: 0.11, alpha: 1).cgColor
        previewBox.layer?.borderWidth = 1
        previewBox.layer?.borderColor = selected.identity.color.withAlphaComponent(0.32).cgColor
        previewBox.onClick = { [weak self] in self?.focusAgentApp(selected) }

        let imgView = NSImageView(frame: previewBox.bounds)
        imgView.imageScaling = .scaleProportionallyUpOrDown
        imgView.image = thumbnail
        previewBox.addSubview(imgView)
        livePreviewImageView = imgView

        if thumbnail == nil {
            let phTitle = selected.windowTitle.isEmpty ? (selected.app.isEmpty ? "Working in background" : selected.app) : selected.windowTitle
            let ph = makeLabel(phTitle, size: 12, weight: .medium, color: NSColor(white: 1.0, alpha: 0.45))
            ph.alignment = .center
            ph.lineBreakMode = .byTruncatingTail
            ph.frame = NSRect(x: 16, y: (previewH - 16) / 2, width: boxRect.width - 32, height: 16)
            previewBox.addSubview(ph)
        }

        // Miniature colored dart cursor mapped cleanly into the aspect-fitted image rect
        if let norm = selected.cursorNorm {
            let fitted: CGRect = {
                guard let img = thumbnail, img.size.width > 0, img.size.height > 0 else { return previewBox.bounds }
                let scale = min(boxRect.width / img.size.width, boxRect.height / img.size.height)
                let fw = img.size.width * scale, fh = img.size.height * scale
                return CGRect(x: (boxRect.width - fw) / 2, y: (boxRect.height - fh) / 2, width: fw, height: fh)
            }()
            let cx = max(10, min(boxRect.width - 10, fitted.minX + norm.x * fitted.width))
            let cy = max(10, min(boxRect.height - 10, fitted.minY + (1.0 - norm.y) * fitted.height))
            let miniCursor = CursorDartView(sessionId: selected.sessionId, tint: selected.identity.color, size: 18)
            miniCursor.frame = NSRect(x: cx - 9, y: cy - 9, width: 18, height: 18)
            previewBox.addSubview(miniCursor)
        }

        // Frosted app pill in bottom-left + agent counter in bottom-right of thumbnail
        if !selected.app.isEmpty {
            let appTag = selected.app
            let tagW = min(130, ceil((appTag as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold)]).width) + 14)
            let pill = makeLabel(appTag, size: 10, weight: .semibold, color: NSColor(white: 1.0, alpha: 0.92))
            pill.alignment = .center
            pill.wantsLayer = true
            pill.layer?.backgroundColor = NSColor(white: 0.0, alpha: 0.72).cgColor
            pill.layer?.cornerRadius = 6
            pill.frame = NSRect(x: 8, y: 8, width: tagW, height: 17)
            previewBox.addSubview(pill)
        }
        if agents.count > 1 {
            let cnt = "\(selIdx + 1) / \(agents.count)"
            let cntPill = makeLabel(cnt, size: 10, weight: .semibold, color: NSColor(white: 1.0, alpha: 0.82))
            cntPill.alignment = .center
            cntPill.wantsLayer = true
            cntPill.layer?.backgroundColor = NSColor(white: 0.0, alpha: 0.68).cgColor
            cntPill.layer?.cornerRadius = 6
            cntPill.frame = NSRect(x: boxRect.width - 40, y: 8, width: 32, height: 17)
            previewBox.addSubview(cntPill)
        }

        host.addSubview(previewBox)

        // Single crisp centered-card footer: [● dot] agent · what it's doing
        let footMidY: CGFloat = 20
        let dot = NSView(frame: NSRect(x: bodyLeft + 2, y: footMidY - 3.5, width: 7, height: 7))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.layer?.backgroundColor = selected.identity.color.cgColor
        host.addSubview(dot)

        let agentW = min(104, ceil((selected.identity.agent as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold)]).width) + 6)
        let aLabel = makeLabel(selected.identity.agent, size: 11.5, weight: .semibold, color: NSColor(white: 1.0, alpha: 0.92))
        aLabel.lineBreakMode = .byTruncatingTail
        aLabel.frame = NSRect(x: bodyLeft + 14, y: footMidY - 8, width: agentW, height: 16)
        host.addSubview(aLabel)

        let actX = bodyLeft + 14 + agentW + 3
        let actW = max(80, bodyLeft + bodyW - 2 - actX)
        let actLabel = makeLabel("· " + selected.action, size: 11.5, weight: .regular, color: NSColor(white: 1.0, alpha: 0.68))
        actLabel.lineBreakMode = .byTruncatingTail
        actLabel.frame = NSRect(x: actX, y: footMidY - 8, width: actW, height: 16)
        host.addSubview(actLabel)

        return CGSize(width: innerW, height: totalH)
    }

    // 1. Minimal Passkey / Touch ID Split Island:
    //    ONLY the Touch ID icon on the left of the notch and "Please touch the key" on the right.
    private func renderPasskey(_ banner: PasskeyBanner) {
        let geo = NotchGeometry.detect()
        let (_, _, host) = ensurePanel()
        let size = populatePasskey(in: host, banner: banner, geo: geo, animate: true)
        let rose = NSColor(srgbRed: 1.0, green: 0.27, blue: 0.42, alpha: 1.0)
        present(width: size.width, height: size.height, geometry: geo, allowKey: false, glowColor: rose)
    }

    @discardableResult
    func populatePasskey(in host: NSView, banner: PasskeyBanner, geo: NotchGeometry, animate: Bool) -> CGSize {
        host.subviews.forEach { $0.removeFromSuperview() }
        let ear: CGFloat = geo.hasNotch ? 12 : 0
        let topH = max(geo.notchHeight, 36) + 4
        let innerW: CGFloat = max(geo.notchWidth + 320, 508)
        let totalW = innerW + ear * 2

        // Left wing: concentric biometric radar ring + pulsing Touch ID SF Symbol + "Touch ID"
        let leftX = ear + 16
        let rose = NSColor(srgbRed: 1.0, green: 0.27, blue: 0.42, alpha: 1.0)
        if animate {
            let ring = NSView(frame: NSRect(x: leftX - 2, y: (topH - 26) / 2, width: 26, height: 26))
            ring.wantsLayer = true
            ring.layer?.cornerRadius = 13
            ring.layer?.borderWidth = 1.2
            ring.layer?.borderColor = rose.withAlphaComponent(0.75).cgColor
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.85
            grow.toValue = 1.45
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.75
            fade.toValue = 0.0
            let radar = CAAnimationGroup()
            radar.animations = [grow, fade]
            radar.duration = 1.4
            radar.repeatCount = .infinity
            radar.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ring.layer?.add(radar, forKey: "radar")
            host.addSubview(ring)
        }

        let touchIcon = NSImageView(frame: NSRect(x: leftX, y: (topH - 22) / 2, width: 22, height: 22))
        if let sym = NSImage(systemSymbolName: "touchid", accessibilityDescription: "Touch ID") {
            let cfg = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
            touchIcon.image = sym.withSymbolConfiguration(cfg)
            touchIcon.contentTintColor = rose
        }
        if animate {
            touchIcon.wantsLayer = true
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.45
            pulse.duration = 0.95
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            touchIcon.layer?.add(pulse, forKey: "pulse")
        }
        host.addSubview(touchIcon)

        let tidLabel = makeLabel("Touch ID", size: 12.5, weight: .semibold, color: NSColor(white: 1.0, alpha: 0.92))
        tidLabel.frame = NSRect(x: leftX + 28, y: (topH - 16) / 2, width: 92, height: 16)
        host.addSubview(tidLabel)

        // Right wing: "Please touch the key"
        let rightStart = geo.hasNotch ? (totalW / 2.0 + geo.notchWidth / 2.0 + 10) : (leftX + 126)
        let rightW = max(130, totalW - ear - rightStart - 16)
        let promptLabel = makeLabel(banner.prompt, size: 12.5, weight: .semibold, color: .white)
        promptLabel.alignment = .right
        promptLabel.lineBreakMode = .byTruncatingTail
        promptLabel.frame = NSRect(x: rightStart, y: (topH - 17) / 2, width: rightW, height: 17)
        host.addSubview(promptLabel)

        return CGSize(width: innerW, height: topH)
    }

    // 2. Autonomous Toast Pill (wings-only, zero clicks, auto-collapses after ~2.6s)
    private func renderToast(identity: AgentIdentity, icon: String, text: String) {
        let geo = NotchGeometry.detect()
        let (_, _, host) = ensurePanel()
        let size = populateToast(in: host, identity: identity, icon: icon, text: text, geo: geo)
        present(width: size.width, height: size.height, geometry: geo, allowKey: false, glowColor: identity.color)
    }

    @discardableResult
    func populateToast(in host: NSView, identity: AgentIdentity, icon: String, text: String, geo: NotchGeometry) -> CGSize {
        host.subviews.forEach { $0.removeFromSuperview() }
        let ear: CGFloat = geo.hasNotch ? 12 : 0
        let topH = max(geo.notchHeight, 36) + 4
        let innerW = geo.hasNotch ? max(geo.notchWidth + 360, 546) : 410
        let totalW = innerW + ear * 2

        // Left wing: [Harness Logo] Harness  [● dot] agent
        let logo = HarnessLogoView(harnessId: identity.harnessId, tint: identity.color, size: 18)
        logo.frame = NSRect(x: ear + 14, y: (topH - 18) / 2, width: 18, height: 18)
        host.addSubview(logo)

        let leftEdgeEnd = geo.hasNotch ? (totalW / 2.0 - geo.notchWidth / 2.0 - 10) : (ear + 190)
        let hW = min(94, ceil((identity.harness as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width) + 8)
        let hLabel = makeLabel(identity.harness, size: 12, weight: .semibold, color: NSColor(white: 1.0, alpha: 0.92))
        hLabel.lineBreakMode = .byTruncatingTail
        hLabel.frame = NSRect(x: ear + 38, y: (topH - 16) / 2, width: hW, height: 16)
        host.addSubview(hLabel)

        let dotX = ear + 38 + hW + 4
        if dotX + 16 < leftEdgeEnd {
            let dot = NSView(frame: NSRect(x: dotX, y: (topH - 6) / 2, width: 6, height: 6))
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dot.layer?.backgroundColor = identity.color.cgColor
            host.addSubview(dot)

            let aLabel = makeLabel(identity.agent, size: 11.5, weight: .medium, color: NSColor(white: 1.0, alpha: 0.60))
            aLabel.lineBreakMode = .byTruncatingTail
            aLabel.frame = NSRect(x: dotX + 10, y: (topH - 15) / 2, width: max(24, leftEdgeEnd - (dotX + 10)), height: 15)
            host.addSubview(aLabel)
        }

        // Right wing: [icon] action summary
        let rightStart = geo.hasNotch ? (totalW / 2.0 + geo.notchWidth / 2.0 + 10) : (ear + 200)
        let rightAvail = max(140, totalW - ear - rightStart - 16)
        let label = makeLabel(text, size: 12, weight: .semibold, color: .white)
        label.alignment = .right
        label.lineBreakMode = .byTruncatingTail
        let textW = min(rightAvail - 20, ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width) + 8)
        label.frame = NSRect(x: totalW - ear - 16 - textW, y: (topH - 16) / 2, width: textW, height: 16)
        host.addSubview(label)

        let glyph = NSImageView(frame: NSRect(x: totalW - ear - 16 - textW - 19, y: (topH - 15) / 2, width: 15, height: 15))
        if let sym = NSImage(systemSymbolName: icon, accessibilityDescription: "UCU") {
            glyph.image = sym.withSymbolConfiguration(.init(pointSize: 12.5, weight: .semibold))
            glyph.contentTintColor = identity.color
        }
        host.addSubview(glyph)

        return CGSize(width: innerW, height: topH)
    }

    // 3. Ultra-Minimal Quick Approval Pill (like Touch ID!).
    //    Collapsed: [G] provider logo on left  |  notch  |  [✓ Allow] [✕] on right (Always everywhere ON by default!)
    //    Hovered on middle: drops a compact 38pt drawer below with [∞ Always] toggle, [👁 View], and site/harness context.
    private func renderApproval(_ request: InteractiveRequest, expanded: Bool = false) {
        let geo = NotchGeometry.detect()
        let (_, _, host) = ensurePanel()
        guard case let .approve(title, detail, _, canShow, canRemember, _, canRememberGlobal, _, requireTouchID, _) = request.kind else { return }
        let provider = ProviderLogoView.detect(from: "\(title) \(detail)")
        let size = populateApproval(in: host, request: request, queueExtra: queue.count, geo: geo, expanded: expanded)
        if !expanded && provider != nil && geo.hasNotch {
            let hasExtra = canRememberGlobal || canRemember || canShow
            let approveW: CGFloat = requireTouchID ? 86 : 68
            let rightExtra = approveW + 6 + 24 + (hasExtra ? 27 : 0) + 22
            presentAsymmetric(leftExtra: 54, rightExtra: rightExtra, height: size.height, geometry: geo,
                              glowColor: request.identity.color)
        } else {
            present(width: size.width, height: size.height, geometry: geo, allowKey: false,
                    glowColor: expanded ? nil : request.identity.color)
        }
    }

    private func compactActionTitle(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("click ") {
            s = String(s.dropFirst(6)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'“” "))
        }
        return s
    }

    @objc private func onApprovalScopeToggled(_ sender: NSButton) {
        approvalAlwaysOn = (sender.state == .on)
    }

    @objc private func onToggleApprovalMoreClicked() {
        guard let active, case .approve = active.kind else { return }
        approvalExpanded.toggle()
        renderApproval(active, expanded: approvalExpanded)
    }

    @objc private func onExpandCredentialClicked() {
        guard let active, case .credential = active.kind else { return }
        credentialPinned = true
        credentialExpanded = true
        renderCredential(active, expanded: true)
    }

    @objc private func onQuickAuthClicked(_ sender: QuickAuthPill) {
        if sender.authMethod == "passwords" {
            onPasswordsAutoFillClicked()
            return
        }
        let remember = rememberCheck?.state != .off
        finishActive(.chooseAuth(method: sender.authMethod, provider: sender.authProvider, remember: remember))
    }

    @discardableResult
    func populateApproval(in host: NSView, request: InteractiveRequest, queueExtra: Int,
                          geo: NotchGeometry, expanded: Bool = false) -> CGSize {
        guard case let .approve(title, detail, badge, canShow, canRemember, rememberLabel,
                                canRememberGlobal, globalLabel, requireTouchID, icon) = request.kind else {
            return .zero
        }
        host.subviews.forEach { $0.removeFromSuperview() }

        let ear: CGFloat = geo.hasNotch ? 12 : 0
        let topH = max(geo.notchHeight, 36) + 4
        let provider = ProviderLogoView.detect(from: "\(title) \(detail)")
        let hasExtraOptions = canRememberGlobal || canRemember || canShow
        let drawerH: CGFloat = (expanded && hasExtraOptions) ? 40 : 0
        let totalH = topH + drawerH
        let topBandY = totalH - topH

        let approveW: CGFloat = requireTouchID ? 86 : 68
        let chevronW: CGFloat = hasExtraOptions ? 22 : 0
        let rightWingNeed: CGFloat = approveW + 6 + 24 + (hasExtraOptions ? 5 + chevronW : 0) + 22
        let leftWingW: CGFloat = (provider != nil && !expanded) ? 54 : (provider != nil ? 122 : 168)
        let rightWingW = max(rightWingNeed, expanded ? leftWingW : rightWingNeed)
        if !expanded && provider != nil && geo.hasNotch {
            // Compact hugging wings: [G] hugs left edge tightly (never overlaps menu bar Help), buttons hug right!
            let totalW = ear + leftWingW + geo.notchWidth + rightWingW + ear
            let pLogo = ProviderLogoView(provider: provider!, size: 22)
            pLogo.toolTip = "\(title) · \(badge)"
            pLogo.frame = NSRect(x: ear + 16, y: topBandY + round((topH - 22) / 2), width: 22, height: 22)
            host.addSubview(pLogo)

            let btnH: CGFloat = 24
            let btnY = topBandY + round((topH - btnH) / 2)
            let rightWingStart = ear + leftWingW + geo.notchWidth + 8
            let approveBtn = PillButton(
                title: requireTouchID ? "Touch ID" : "Allow",
                symbol: requireTouchID ? "touchid" : "checkmark",
                fill: .white, hover: NSColor(white: 0.90, alpha: 1.0), text: .black,
                target: self, action: #selector(onApproveClicked)
            )
            approveBtn.toolTip = approvalAlwaysOn ? "Allow (saves Always allow everywhere)" : "Allow once"
            approveBtn.layer?.cornerRadius = 12
            approveBtn.frame = NSRect(x: rightWingStart, y: btnY, width: approveW, height: btnH)
            host.addSubview(approveBtn)

            let denyX = rightWingStart + approveW + 6
            let denyBtn = PillButton(
                title: "", symbol: "xmark",
                fill: NSColor(white: 1.0, alpha: 0.12),
                hover: NSColor(srgbRed: 0.85, green: 0.22, blue: 0.22, alpha: 0.85),
                text: NSColor(white: 1.0, alpha: 0.88),
                target: self, action: #selector(onDenyClicked)
            )
            denyBtn.toolTip = "Deny (⌃⌥⎋)"
            denyBtn.layer?.cornerRadius = 12
            denyBtn.frame = NSRect(x: denyX, y: btnY, width: 24, height: btnH)
            host.addSubview(denyBtn)

            if hasExtraOptions {
                let moreBtn = PillButton(
                    title: "", symbol: "chevron.down",
                    fill: NSColor(white: 1.0, alpha: 0.08), hover: NSColor(white: 1.0, alpha: 0.22),
                    text: NSColor(white: 1.0, alpha: 0.78),
                    target: self, action: #selector(onToggleApprovalMoreClicked)
                )
                moreBtn.toolTip = "More options (Always allow, View tab)"
                moreBtn.layer?.cornerRadius = 11
                moreBtn.frame = NSRect(x: denyX + 24 + 5, y: btnY, width: chevronW, height: btnH)
                host.addSubview(moreBtn)
            }
            return CGSize(width: totalW - ear * 2, height: topH)
        }
        let wingW = max(rightWingNeed, leftWingW)
        let innerW: CGFloat = geo.hasNotch ? max(geo.notchWidth + wingW * 2, 474) : 370
        let totalW = innerW + ear * 2

        // Left wing (left of notch):
        // For Google/Apple/Microsoft/GitHub -> ONLY the clean provider logo (no harness/agent clutter!).
        let leftWingEnd = geo.hasNotch ? (totalW / 2.0 - geo.notchWidth / 2.0 - 8) : (ear + 130)
        if let provider {
            let pLogo = ProviderLogoView(provider: provider, size: 22)
            pLogo.toolTip = "\(title) · \(badge)"
            pLogo.frame = NSRect(x: ear + 18, y: topBandY + round((topH - 22) / 2), width: 22, height: 22)
            host.addSubview(pLogo)
            if queueExtra > 0 {
                let qPill = makeLabel("+\(queueExtra)", size: 10, weight: .semibold, color: NSColor(white: 1.0, alpha: 0.78))
                qPill.alignment = .center
                qPill.wantsLayer = true
                qPill.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.14).cgColor
                qPill.layer?.cornerRadius = 7
                qPill.frame = NSRect(x: ear + 48, y: topBandY + round((topH - 15) / 2), width: 24, height: 15)
                host.addSubview(qPill)
            }
        } else {
            let glyph = NSImageView(frame: NSRect(x: ear + 14, y: topBandY + round((topH - 16) / 2), width: 16, height: 16))
            if let sym = NSImage(systemSymbolName: icon, accessibilityDescription: title) {
                glyph.image = sym.withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
                glyph.contentTintColor = request.identity.color
            }
            host.addSubview(glyph)
            let shortTitle = compactActionTitle(title)
            let titleLabel = makeLabel(shortTitle, size: 12, weight: .semibold, color: .white)
            titleLabel.lineBreakMode = .byTruncatingTail
            titleLabel.frame = NSRect(x: ear + 35, y: topBandY + round((topH - 16) / 2),
                                      width: max(60, leftWingEnd - (ear + 35)), height: 16)
            host.addSubview(titleLabel)
        }

        // Right wing (right of notch): FIRST [✓ Allow], NEXT [✕], NEXT small [⌄] toggle for extra options
        let btnH: CGFloat = 24
        let btnY = topBandY + round((topH - btnH) / 2)
        let rightWingStart = geo.hasNotch ? (totalW / 2.0 + geo.notchWidth / 2.0 + 10) : (totalW - ear - 140)

        let approveBtn = PillButton(
            title: requireTouchID ? "Touch ID" : "Allow",
            symbol: requireTouchID ? "touchid" : "checkmark",
            fill: .white,
            hover: NSColor(white: 0.90, alpha: 1.0),
            text: .black,
            target: self,
            action: #selector(onApproveClicked)
        )
        approveBtn.toolTip = approvalAlwaysOn ? "Allow (saves Always allow everywhere)" : "Allow once"
        approveBtn.layer?.cornerRadius = 12
        approveBtn.frame = NSRect(x: rightWingStart, y: btnY, width: approveW, height: btnH)
        host.addSubview(approveBtn)

        let denyX = rightWingStart + approveW + 6
        let denyBtn = PillButton(
            title: "",
            symbol: "xmark",
            fill: NSColor(white: 1.0, alpha: 0.12),
            hover: NSColor(srgbRed: 0.85, green: 0.22, blue: 0.22, alpha: 0.85),
            text: NSColor(white: 1.0, alpha: 0.88),
            target: self,
            action: #selector(onDenyClicked)
        )
        denyBtn.toolTip = "Deny (⌃⌥⎋)"
        denyBtn.layer?.cornerRadius = 12
        denyBtn.frame = NSRect(x: denyX, y: btnY, width: 24, height: btnH)
        host.addSubview(denyBtn)

        if hasExtraOptions {
            let moreBtn = PillButton(
                title: "",
                symbol: expanded ? "chevron.up" : "chevron.down",
                fill: NSColor(white: 1.0, alpha: expanded ? 0.18 : 0.08),
                hover: NSColor(white: 1.0, alpha: 0.22),
                text: NSColor(white: 1.0, alpha: 0.78),
                target: self,
                action: #selector(onToggleApprovalMoreClicked)
            )
            moreBtn.toolTip = expanded ? "Hide options" : "More options (Always allow, View tab)"
            moreBtn.layer?.cornerRadius = 11
            moreBtn.frame = NSRect(x: denyX + 24 + 5, y: btnY, width: chevronW, height: btnH)
            host.addSubview(moreBtn)
        }

        // Expanded hover drawer right below the notch: [Harness Logo] domain   [∞ Always]  [👁 View]
        if drawerH > 0 {
            addDivider(to: host, x: ear + 16, y: drawerH - 1, width: innerW - 32)
            let midY = round((drawerH - 24) / 2)

            let hLogo = HarnessLogoView(harnessId: request.identity.harnessId, tint: request.identity.color, size: 16)
            hLogo.frame = NSRect(x: ear + 18, y: round((drawerH - 16) / 2), width: 16, height: 16)
            host.addSubview(hLogo)

            var rightX = totalW - ear - 14
            if canShow {
                let showW: CGFloat = 68
                rightX -= showW
                let showBtn = PillButton(
                    title: "View",
                    symbol: "eye",
                    fill: NSColor(white: 1.0, alpha: 0.14),
                    hover: NSColor(white: 1.0, alpha: 0.24),
                    text: .white,
                    target: self,
                    action: #selector(onShowClicked)
                )
                showBtn.layer?.cornerRadius = 12
                showBtn.frame = NSRect(x: rightX, y: midY, width: showW, height: 24)
                host.addSubview(showBtn)
                rightX -= 6
            }

            if canRememberGlobal || canRemember {
                let onLbl = canRememberGlobal ? "Always everywhere" : "Always on site"
                let pillW: CGFloat = canRememberGlobal ? 136 : 114
                rightX -= pillW
                let toggle = ScopeTogglePill(onLabel: onLbl, offLabel: "Allow once", on: approvalAlwaysOn)
                toggle.toolTip = canRememberGlobal ? globalLabel : rememberLabel
                toggle.target = self
                toggle.action = #selector(onApprovalScopeToggled(_:))
                toggle.frame = NSRect(x: rightX, y: midY, width: pillW, height: 24)
                host.addSubview(toggle)
                if canRememberGlobal { globalRememberCheck = toggle } else { rememberCheck = toggle }
                rightX -= 8
            }

            let ctxText = badge.isEmpty ? request.identity.harness : badge
            let ctxLabel = makeLabel(ctxText, size: 11.5, weight: .medium, color: NSColor(white: 1.0, alpha: 0.68))
            ctxLabel.lineBreakMode = .byTruncatingTail
            ctxLabel.frame = NSRect(x: ear + 40, y: round((drawerH - 15) / 2),
                                    width: max(60, rightX - (ear + 40)), height: 15)
            host.addSubview(ctxLabel)
        }

        return CGSize(width: innerW, height: totalH)
    }

    // 4. Inline Credential / Secret Entry Island:
    //    Collapsed (compact default): [Harness Logo] on left  |  notch  |  [Site Logo] Sign in ⌄ on right
    //    Hover or click -> expands smoothly into the full dark login form (with Apple Passwords AutoFill + Remember).
    private func renderCredential(_ request: InteractiveRequest, expanded: Bool = false) {
        let geo = NotchGeometry.detect()
        let (_, _, host) = ensurePanel()
        let size = populateCredential(in: host, request: request, queueExtra: queue.count, geo: geo, expanded: expanded)
        if !expanded && geo.hasNotch {
            presentAsymmetric(leftExtra: 52, rightExtra: 118, height: size.height, geometry: geo,
                              glowColor: request.identity.color)
        } else {
            present(width: size.width, height: size.height, geometry: geo, allowKey: false,
                    glowColor: expanded ? nil : request.identity.color)
        }
    }

    @discardableResult
    func populateCredential(in host: NSView, request: InteractiveRequest, queueExtra: Int,
                            geo: NotchGeometry, expanded: Bool = true) -> CGSize {
        guard case let .credential(kind, title, subtitle, badge, usernameHint, canShow, defaultRemember,
                                   rememberLabel, availableOAuth, hasPasskey) = request.kind else {
            return .zero
        }
        host.subviews.forEach { $0.removeFromSuperview() }

        let ear: CGFloat = geo.hasNotch ? 12 : 0
        let topH = max(geo.notchHeight, 36) + 4
        let isLogin = (kind == "login")

        // Compact single-line collapsed login pill until hovered or clicked!
        if !expanded {
            let leftExtra: CGFloat = 52
            let rightExtra: CGFloat = 118
            let innerW: CGFloat = geo.hasNotch ? (leftExtra + geo.notchWidth + rightExtra) : 300
            let totalW = innerW + ear * 2

            let clickCover = NSButton(frame: NSRect(x: ear, y: 0, width: innerW, height: topH))
            clickCover.title = ""
            clickCover.isBordered = false
            clickCover.isTransparent = true
            clickCover.target = self
            clickCover.action = #selector(onExpandCredentialClicked)
            host.addSubview(clickCover)

            let hLogo = HarnessLogoView(harnessId: request.identity.harnessId, tint: request.identity.color, size: 21)
            hLogo.frame = NSRect(x: ear + 15, y: round((topH - 21) / 2), width: 21, height: 21)
            host.addSubview(hLogo)

            let rightStart = geo.hasNotch ? (ear + leftExtra + geo.notchWidth + 8) : (totalW / 2.0)
            let sLogo = SiteLogoView(domain: badge, size: 19)
            sLogo.frame = NSRect(x: rightStart, y: round((topH - 19) / 2), width: 19, height: 19)
            host.addSubview(sLogo)

            let actionWord = isLogin ? "Sign in" : (kind == "otp" ? "Code" : "Secret")
            let lbl = makeLabel(actionWord, size: 12.5, weight: .semibold, color: .white)
            lbl.frame = NSRect(x: rightStart + 25, y: round((topH - 16) / 2), width: 54, height: 16)
            host.addSubview(lbl)

            let chev = NSImageView(frame: NSRect(x: totalW - ear - 22, y: round((topH - 11) / 2), width: 11, height: 11))
            if let sym = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Expand") {
                chev.image = sym.withSymbolConfiguration(.init(pointSize: 9.5, weight: .semibold))
                chev.contentTintColor = NSColor(white: 1.0, alpha: 0.55)
            }
            host.addSubview(chev)

            return CGSize(width: innerW, height: topH)
        }

        // Build one-tap sign-in methods row (Google / Apple / Passkey + Apple Passwords AutoFill) —
        // whichever you pick is remembered by default so UCU does it automatically next time!
        var quickOptions: [(method: String, provider: String?, title: String)] = []
        if isLogin {
            for prov in availableOAuth.prefix(2) {
                quickOptions.append(("oauth", prov.lowercased(), prov))
            }
            if hasPasskey {
                quickOptions.append(("passkey", nil, "Passkey"))
            }
            quickOptions.append(("passwords", nil, "Passwords"))
        }

        let expTopH = max(geo.notchHeight, 34)
        let innerW: CGFloat = max(geo.notchWidth + 335, 520)
        let quickRowH: CGFloat = quickOptions.isEmpty ? 0 : 38
        let fieldsH: CGFloat = isLogin ? 80 : 40
        let totalH = expTopH + 56 + quickRowH + fieldsH + 28 + 44 + 8
        let totalW = innerW + ear * 2

        addIdentityWings(to: host, totalW: totalW, topH: expTopH, totalH: totalH, ear: ear, geo: geo,
                         identity: request.identity, queueExtra: queueExtra)
        addDivider(to: host, x: ear + 18, y: totalH - expTopH - 2, width: innerW - 36)

        let headerTopY = totalH - expTopH - 14
        let sLogo = SiteLogoView(domain: badge, size: 32)
        sLogo.frame = NSRect(x: ear + 18, y: headerTopY - 33, width: 32, height: 32)
        host.addSubview(sLogo)

        let textX = ear + 62
        let textW = innerW - 80
        let titleLabel = makeLabel(title, size: 13.5, weight: .semibold, color: .white)
        titleLabel.frame = NSRect(x: textX, y: headerTopY - 18, width: textW, height: 18)
        host.addSubview(titleLabel)

        let subLabel = makeLabel(subtitle, size: 11, weight: .regular, color: NSColor(white: 1.0, alpha: 0.58))
        subLabel.lineBreakMode = .byTruncatingTail
        subLabel.frame = NSRect(x: textX, y: headerTopY - 35, width: textW, height: 15)
        host.addSubview(subLabel)

        var y = headerTopY - 46

        if !quickOptions.isEmpty {
            y -= 28
            let gap: CGFloat = 8
            let totalAvail = innerW - 36
            let pillW = floor((totalAvail - gap * CGFloat(quickOptions.count - 1)) / CGFloat(quickOptions.count))
            for (idx, opt) in quickOptions.enumerated() {
                let btn = QuickAuthPill(method: opt.method, provider: opt.provider, title: opt.title,
                                        target: self, action: #selector(onQuickAuthClicked(_:)))
                btn.frame = NSRect(x: ear + 18 + CGFloat(idx) * (pillW + gap), y: y, width: pillW, height: 28)
                host.addSubview(btn)
            }
            y -= 10
        }
        if isLogin {
            y -= 30
            let uField = makeDarkTextField(placeholder: "Email or username", value: usernameHint)
            uField.contentType = .username
            uField.frame = NSRect(x: ear + 18, y: y, width: innerW - 36, height: 30)
            uField.delegate = self
            uField.onFocusRequest = { [weak self] in self?.requestTextInputFocus() }
            host.addSubview(uField)
            usernameField = uField
            y -= 10
        }

        y -= 30
        let placeholder = isLogin ? "Password" : (kind == "otp" ? "One-time code" : "Paste API key or secret")
        let sField = makeDarkSecureField(placeholder: placeholder)
        if isLogin {
            sField.contentType = .password
            if let uField = usernameField {
                uField.nextKeyView = sField
            }
        }
        sField.frame = NSRect(x: ear + 18, y: y, width: innerW - 36, height: 30)
        sField.delegate = self
        sField.onFocusRequest = { [weak self] in self?.requestTextInputFocus() }
        host.addSubview(sField)
        secretField = sField

        y -= 28
        let check = makeDarkCheckbox(title: rememberLabel, checked: defaultRemember)
        check.frame = NSRect(x: ear + 18, y: y, width: innerW - 36, height: 18)
        host.addSubview(check)
        rememberCheck = check

        // Bottom actions: Cancel / Show tab / Fill & Sign In
        let btnY: CGFloat = 12
        let btnH: CGFloat = 28
        var rightX = totalW - ear - 16

        let submitW: CGFloat = 124
        rightX -= submitW
        let submitBtn = PillButton(
            title: isLogin ? "Fill & Sign In" : "Save & Use",
            symbol: "lock.fill",
            fill: .white,
            hover: NSColor(white: 0.90, alpha: 1.0),
            text: .black,
            target: self,
            action: #selector(onCredentialSubmit)
        )
        submitBtn.frame = NSRect(x: rightX, y: btnY, width: submitW, height: btnH)
        host.addSubview(submitBtn)

        if canShow {
            let showW: CGFloat = 86
            rightX -= showW + 8
            let showBtn = PillButton(
                title: "Show tab",
                symbol: "eye",
                fill: NSColor(white: 1.0, alpha: 0.14),
                hover: NSColor(white: 1.0, alpha: 0.22),
                text: .white,
                target: self,
                action: #selector(onShowClicked)
            )
            showBtn.frame = NSRect(x: rightX, y: btnY, width: showW, height: btnH)
            host.addSubview(showBtn)
        }

        let cancelW: CGFloat = 72
        rightX -= cancelW + 8
        let cancelBtn = PillButton(
            title: "Cancel",
            symbol: nil,
            fill: NSColor(white: 1.0, alpha: 0.12),
            hover: NSColor(srgbRed: 0.85, green: 0.22, blue: 0.22, alpha: 0.85),
            text: NSColor(white: 1.0, alpha: 0.88),
            target: self,
            action: #selector(onDenyClicked)
        )
        cancelBtn.frame = NSRect(x: rightX, y: btnY, width: cancelW, height: btnH)
        host.addSubview(cancelBtn)

        return CGSize(width: innerW, height: totalH)
    }

    // Top wings flanking the hardware notch:
    //   Left wing:  [Harness Logo] Harness Name
    //   Right wing: [● agent cursor dot] agent/session name  (+N queue pill if waiting)
    private func addIdentityWings(to host: NSView, totalW: CGFloat, topH: CGFloat, totalH: CGFloat,
                                  ear: CGFloat, geo: NotchGeometry, identity: AgentIdentity, queueExtra: Int) {
        let topBandY = totalH - topH
        let logo = HarnessLogoView(harnessId: identity.harnessId, tint: identity.color, size: 18)
        logo.frame = NSRect(x: ear + 16, y: topBandY + (topH - 18) / 2, width: 18, height: 18)
        host.addSubview(logo)

        let leftAvail = geo.hasNotch ? max(64, (totalW - geo.notchWidth) / 2 - ear - 44) : 160
        let left = makeLabel(identity.harness, size: 12, weight: .semibold, color: NSColor(white: 1.0, alpha: 0.92))
        left.lineBreakMode = .byTruncatingTail
        left.frame = NSRect(x: ear + 40, y: topBandY + (topH - 16) / 2, width: leftAvail, height: 16)
        host.addSubview(left)

        let rightStart = geo.hasNotch ? (totalW / 2.0 + geo.notchWidth / 2.0 + 10) : (totalW / 2.0)
        var rightLimit = totalW - ear - 16

        if queueExtra > 0 {
            let qText = "+\(queueExtra)"
            let qPill = makeLabel(qText, size: 10.5, weight: .semibold, color: .white)
            qPill.alignment = .center
            qPill.wantsLayer = true
            qPill.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.16).cgColor
            qPill.layer?.cornerRadius = 7
            let qW: CGFloat = 26
            rightLimit -= qW
            qPill.frame = NSRect(x: rightLimit, y: topBandY + (topH - 15) / 2, width: qW, height: 15)
            host.addSubview(qPill)
            rightLimit -= 6
        }

        let agentMaxW = max(60, rightLimit - rightStart - 12)
        let measured = ceil((identity.agent as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .medium)]).width) + 8
        let agentW = min(agentMaxW, measured)
        let agentLabel = makeLabel(identity.agent, size: 11.5, weight: .medium, color: NSColor(white: 1.0, alpha: 0.78))
        agentLabel.alignment = .right
        agentLabel.lineBreakMode = .byTruncatingTail
        agentLabel.frame = NSRect(x: rightLimit - agentW, y: topBandY + (topH - 15) / 2, width: agentW, height: 15)
        host.addSubview(agentLabel)

        let dot = NSView(frame: NSRect(x: rightLimit - agentW - 10, y: topBandY + (topH - 7) / 2, width: 7, height: 7))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.layer?.backgroundColor = identity.color.cgColor
        host.addSubview(dot)
    }

    private func addDivider(to host: NSView, x: CGFloat, y: CGFloat, width: CGFloat) {
        let line = NSView(frame: NSRect(x: x, y: y, width: width, height: 1))
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.08).cgColor
        host.addSubview(line)
    }

    private func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        return label
    }

    private func styleDarkInput(_ field: NSTextField, placeholder: String) {
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = .white
        field.font = .systemFont(ofSize: 12.5)
        field.wantsLayer = true
        field.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.11).cgColor
        field.layer?.cornerRadius = 8
        field.layer?.borderWidth = 1
        field.layer?.borderColor = NSColor(white: 1.0, alpha: 0.16).cgColor
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: NSColor(white: 1.0, alpha: 0.42), .font: NSFont.systemFont(ofSize: 12.5)]
        )
        if let cell = field.cell as? NSTextFieldCell {
            cell.usesSingleLineMode = true
            cell.isScrollable = true
        }
    }

    private func makeDarkTextField(placeholder: String, value: String) -> ClickableTextField {
        let field = ClickableTextField(string: value)
        styleDarkInput(field, placeholder: placeholder)
        return field
    }

    private func makeDarkSecureField(placeholder: String) -> ClickableSecureField {
        let field = ClickableSecureField(string: "")
        styleDarkInput(field, placeholder: placeholder)
        return field
    }

    private func makeDarkCheckbox(title: String, checked: Bool) -> NSButton {
        DarkCheckButton(title: title, checked: checked)
    }

    // MARK: Button & Keyboard Actions

    @objc private func onApproveClicked() {
        guard let active, case let .approve(title, _, _, _, canRemember, _, canRememberGlobal, _, requireTouchID, _) = active.kind else { return }
        let global = canRememberGlobal && approvalAlwaysOn
        let remember = (canRemember || canRememberGlobal) && approvalAlwaysOn
        if !requireTouchID {
            finishActive(.approved(remembered: remember, global: global))
            return
        }
        guard !authenticatingTouchID else { return }
        authenticatingTouchID = true
        renderPasskey(PasskeyBanner(identity: active.identity, prompt: "Please touch the key", detail: title))
        authenticateTouchID(reason: title) { [weak self] ok in
            DispatchQueue.main.async {
                guard let self, self.active?.id == active.id else { return }
                self.authenticatingTouchID = false
                if ok {
                    self.finishActive(.approved(remembered: remember, global: global))
                } else {
                    self.renderApproval(active, expanded: self.approvalExpanded)
                }
            }
        }
    }

    @objc private func onDenyClicked() {
        finishActive(.denied)
    }

    @objc private func onShowClicked() {
        finishActive(.show)
    }

    @objc private func onPasswordsAutoFillClicked() {
        guard let targetField: NSView = secretField ?? usernameField else { return }
        requestTextInputFocus()
        panel?.makeFirstResponder(targetField)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, let field: NSView = self.secretField ?? self.usernameField else { return }
            if let cls = NSClassFromString("NSAutoFillHeuristicController") as? NSObject.Type {
                let sharedSel = NSSelectorFromString("sharedInstance")
                let showSel = NSSelectorFromString("showAutoFillPasswordsForView:")
                if cls.responds(to: sharedSel),
                   let inst = cls.perform(sharedSel)?.takeUnretainedValue() as? NSObject,
                   inst.responds(to: showSel) {
                    _ = inst.perform(showSel, with: field)
                    return
                }
            }
            NSApp.sendAction(NSSelectorFromString("_handleInsertFromPasswordsCommand:"), to: nil, from: field)
        }
    }

    @objc private func onCredentialSubmit() {
        guard active != nil else { return }
        autoSubmitWork?.cancel()
        autoSubmitWork = nil
        let secret = secretField?.stringValue ?? ""
        let username = usernameField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !secret.isEmpty || !username.isEmpty else {
            NSSound.beep()
            return
        }
        let remember = rememberCheck?.state == .on
        finishActive(.filled(username: username, secret: secret, remember: remember))
    }

    // Detect Apple Passwords AutoFill populating both username and password at once and auto-save/submit cleanly.
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === usernameField {
            if field.stringValue.count >= 3 {
                lastUsernameAutoAt = Date()
            }
            return
        }
        if field === secretField {
            let newLen = field.stringValue.count
            let jumped = newLen - lastSecretLen
            lastSecretLen = newLen
            let hasUser = (usernameField == nil) || !(usernameField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            // Apple Passwords AutoFill inserts the full password in one atomic jump alongside or right after username.
            if jumped >= 6 && hasUser && (usernameField == nil || -lastUsernameAutoAt.timeIntervalSinceNow < 2.0) {
                autoSubmitWork?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.onCredentialSubmit() }
                autoSubmitWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
            }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if control === usernameField, let secretField {
                panel?.makeFirstResponder(secretField)
            } else {
                onCredentialSubmit()
            }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onDenyClicked()
            return true
        }
        return false
    }

    private func authenticateTouchID(reason: String, completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        let policy: LAPolicy = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
            ? .deviceOwnerAuthenticationWithBiometrics
            : .deviceOwnerAuthentication
        context.evaluatePolicy(policy, localizedReason: reason) { success, _ in
            completion(success)
        }
    }
}

// MARK: - Unix Domain Socket Daemon

final class IslandDaemon {
    let vault = VaultStore()
    let island = NotchIslandController()
    private var lastActivity = Date()
    private let activityLock = NSLock()
    private var lockFd: Int32 = -1

    private func touch() {
        activityLock.lock()
        lastActivity = Date()
        activityLock.unlock()
    }

    private func idleSeconds() -> TimeInterval {
        activityLock.lock(); defer { activityLock.unlock() }
        return -lastActivity.timeIntervalSinceNow
    }

    func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        try? FileManager.default.createDirectory(atPath: APP_SUPPORT, withIntermediateDirectories: true)

        // Single-instance lock so concurrent chats never race to bind island.sock.
        lockFd = Darwin.open(LOCK_PATH, O_CREAT | O_RDWR, 0o600)
        guard lockFd >= 0, flock(lockFd, LOCK_EX | LOCK_NB) == 0 else {
            exit(0)  // another daemon is already serving
        }

        _ = unlink(SOCKET_PATH)
        let oldMask = umask(0o177)
        let serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFd >= 0 else { fail("socket() failed") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(SOCKET_PATH.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            fail("socket path too long: \(SOCKET_PATH)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let bindLen = socklen_t(MemoryLayout<sa_family_t>.size + MemoryLayout<UInt8>.size + bytes.count + 1)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(serverFd, $0, bindLen) }
        }
        umask(oldMask)
        guard bound == 0, listen(serverFd, 32) == 0 else {
            fail("could not listen on \(SOCKET_PATH)")
        }
        _ = chmod(SOCKET_PATH, 0o600)

        var ownStat = stat()
        _ = stat(SOCKET_PATH, &ownStat)
        let ownInode = ownStat.st_ino

        Thread.detachNewThread { [self] in
            while true {
                let client = accept(serverFd, nil, nil)
                if client < 0 { continue }
                Thread.detachNewThread { [self] in self.serve(client) }
            }
        }

        // Auto-exit once idle and no active UCU chat sessions remain; sweep crashed/idle agents every 5s.
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [self] _ in
            island.sweepStaleAgents()
        }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [self] _ in
            guard !island.isBusy, idleSeconds() > IDLE_EXIT_SECONDS, !Self.hasLiveSessions() else { return }
            var current = stat()
            if stat(SOCKET_PATH, &current) == 0, current.st_ino == ownInode {
                _ = unlink(SOCKET_PATH)
            }
            exit(0)
        }

        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.run()
        exit(0)
    }

    private static func hasLiveSessions() -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: SESSIONS_DIR) else { return false }
        for name in names where name.hasSuffix(".json") {
            let stem = String(name.dropLast(5))
            if let pid = Int32(stem), kill(pid, 0) == 0 { return true }
        }
        return false
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        guard let line = readLine(from: fd),
              let data = line.data(using: .utf8),
              let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }
        touch()
        let reply = handle(request)
        touch()
        writeJSON(reply, to: fd)
    }

    private func readLine(from fd: Int32) -> String? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(chunk, count: n)
            if let nl = buffer.firstIndex(of: 10) {
                return String(data: buffer[..<nl], encoding: .utf8)
            }
            if buffer.count > 2_000_000 { return nil }
        }
        return buffer.isEmpty ? nil : String(data: buffer, encoding: .utf8)
    }

    private func writeJSON(_ dict: [String: Any], to fd: Int32) {
        guard var data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        data.append(10)
        data.withUnsafeBytes { ptr in
            var sent = 0
            while sent < data.count {
                let n = write(fd, ptr.baseAddress!.advanced(by: sent), data.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    private func awaitUI(_ timeout: TimeInterval, enqueue: @escaping (@escaping (IslandDecision) -> Void) -> UUID) -> IslandDecision {
        let sem = DispatchSemaphore(value: 0)
        var result: IslandDecision = .timeout
        var reqId: UUID?
        DispatchQueue.main.async {
            reqId = enqueue { decision in
                result = decision
                sem.signal()
            }
        }
        if sem.wait(timeout: .now() + max(1, min(timeout, 300))) == .timedOut {
            if let id = reqId {
                DispatchQueue.main.async { self.island.cancel(id: id) }
            }
            return .timeout
        }
        return result
    }

    // MARK: Request Router

    private func handle(_ req: [String: Any]) -> [String: Any] {
        guard let op = req["op"] as? String else {
            return ["ok": false, "error": "missing op"]
        }
        let identity = AgentIdentity.from(req)
        let timeout = (req["timeout_seconds"] as? Double) ?? 120.0

        do {
            switch op {
            case "ping":
                let ctx = LAContext()
                var err: NSError?
                let bio = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
                return ["ok": true, "version": VERSION, "biometrics": bio, "has_secrets": vault.hasSecrets()]

            case "passkey":
                let active = (req["active"] as? Bool) ?? true
                let prompt = req["prompt"] as? String
                let detail = req["detail"] as? String
                DispatchQueue.main.async {
                    self.island.setPasskey(active: active, identity: identity, prompt: prompt,
                                           detail: detail, timeout: timeout)
                }
                return ["ok": true, "active": active]

            case "toast":
                let text = req["text"] as? String ?? ""
                let icon = req["icon"] as? String ?? "key.fill"
                let duration = (req["duration"] as? Double) ?? 2.6
                DispatchQueue.main.async {
                    self.island.showToast(identity: identity, icon: icon, text: text, duration: duration)
                }
                return ["ok": true]

            case "agent_state":
                let sessionId = req["session_id"] as? String ?? (req["who"] as? String ?? "default")
                let pid = (req["pid"] as? Int).map(pid_t.init)
                let isActive = (req["active"] as? Bool) ?? true
                let app = req["app"] as? String
                let windowTitle = req["window_title"] as? String
                let wid = (req["window_id"] as? Int).map(CGWindowID.init)
                let action = req["action"] as? String
                var norm: CGPoint? = nil
                if let pair = req["cursor_norm"] as? [Double], pair.count == 2 {
                    norm = CGPoint(x: pair[0], y: pair[1])
                }
                DispatchQueue.main.async {
                    self.island.updateAgent(
                        sessionId: sessionId, pid: pid, identity: identity, active: isActive,
                        app: app, windowTitle: windowTitle, cgWindowId: wid, action: action, cursorNorm: norm
                    )
                }
                return ["ok": true]

            case "approve":
                let title = req["title"] as? String ?? "Agent asks to proceed"
                let detail = req["detail"] as? String ?? ""
                let badge = req["badge"] as? String ?? (req["domain"] as? String ?? (req["app"] as? String ?? "UCU"))
                let canShow = (req["can_show"] as? Bool) ?? false
                let touchID = (req["touch_id"] as? Bool) ?? false
                let icon = req["icon"] as? String ?? "hand.raised.fill"
                let rememberKey = req["remember_key"] as? String
                let globalKey = req["global_key"] as? String
                if let globalKey, !globalKey.isEmpty, vault.isRemembered(globalKey) {
                    DispatchQueue.main.async {
                        self.island.showToast(identity: identity, icon: "checkmark.circle.fill",
                                              text: title, duration: 2.2)
                    }
                    return ["ok": true, "decision": "approved", "remembered": true, "scope": "everywhere"]
                }
                if let rememberKey, !rememberKey.isEmpty, vault.isRemembered(rememberKey) {
                    DispatchQueue.main.async {
                        self.island.showToast(identity: identity, icon: "checkmark.circle.fill",
                                              text: title, duration: 2.2)
                    }
                    return ["ok": true, "decision": "approved", "remembered": true, "scope": "site"]
                }
                let decision = awaitUI(timeout) { done in
                    let item = InteractiveRequest(
                        identity: identity,
                        kind: .approve(
                            title: title,
                            detail: detail,
                            badge: badge,
                            canShow: canShow,
                            canRemember: rememberKey != nil && !rememberKey!.isEmpty,
                            rememberLabel: req["remember_label"] as? String ?? "Always allow on \(badge)",
                            canRememberGlobal: globalKey != nil && !globalKey!.isEmpty,
                            globalLabel: req["global_label"] as? String ?? "Always allow everywhere",
                            requireTouchID: touchID,
                            icon: icon
                        ),
                        completion: done
                    )
                    self.island.enqueue(item)
                    return item.id
                }
                switch decision {
                case .approved(let remembered, let global):
                    if global, let globalKey, !globalKey.isEmpty {
                        vault.rememberApproval(globalKey, persist: true)
                    } else if remembered, let rememberKey, !rememberKey.isEmpty {
                        vault.rememberApproval(rememberKey, persist: true)
                    }
                    // Automatically learn this site's preferred sign-in method (e.g. github.com -> oauth:google)!
                    if let dom = req["domain"] as? String, !dom.isEmpty {
                        let keyProbe = (globalKey ?? rememberKey ?? "").lowercased()
                        if keyProbe.hasPrefix("oauth:") {
                            let prov = String(keyProbe.dropFirst(6)).split(separator: ":").first.map(String.init)
                            vault.setAuthPref(domain: dom, method: "oauth", provider: prov, account: req["account"] as? String)
                        }
                    }
                    return ["ok": true, "decision": "approved", "remembered": remembered,
                            "scope": global ? "everywhere" : (remembered ? "site" : "once")]
                case .denied:
                    return ["ok": true, "decision": "denied"]
                case .show:
                    return ["ok": true, "decision": "show"]
                case .timeout, .filled, .chooseAuth:
                    return ["ok": true, "decision": "timeout"]
                }

            case "auth_plan":
                // Decide automatically how to sign into `domain` based on per-site memory, saved vault logins,
                // on-screen saved sessions, global OAuth rules, and optional requested `account`.
                guard let domain = normalizeHost(req["domain"] as? String) else {
                    return ["ok": true, "action": "ask"]
                }
                let domain_norm = domain
                let contextDomain = normalizeHost(req["context_domain"] as? String)
                let account = (req["account"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let availOAuth = (req["oauth"] as? [String]) ?? []
                let hasPasskey = (req["passkey"] as? Bool) ?? false
                let quickLogins = (req["quick_login"] as? [String]) ?? []
                let hasPasswordField = (req["password"] as? Bool) ?? false

                func matchOAuth(_ wanted: String) -> String? {
                    availOAuth.first { $0.lowercased() == wanted.lowercased() }
                }

                // 1) Remembered per-site preference (e.g. github.com -> always Sign in with Google, or Passkey)
                if let pref = vault.authPref(for: domain_norm) {
                    let learnedAcct = vault.bestAccount(domain: domain_norm, contextDomain: contextDomain,
                                                        provider: pref.provider, hint: account ?? pref.account)?.email
                    let chosenAccount = (account?.isEmpty == false ? account : (pref.account ?? learnedAcct))
                    if pref.method == "oauth", let prov = pref.provider, let liveProv = matchOAuth(prov) {
                        var out: [String: Any] = ["ok": true, "action": "oauth", "provider": liveProv,
                                                  "auto": true, "source": "site_pref"]
                        if let chosenAccount { out["account"] = chosenAccount }
                        return out
                    }
                    if pref.method == "passkey", hasPasskey {
                        return ["ok": true, "action": "passkey", "auto": true, "source": "site_pref"]
                    }
                    if pref.method == "password",
                       let entry = try vault.find(id: nil, domain: domain_norm, app: nil, kind: "login", account: chosenAccount) {
                        return ["ok": true, "action": "password", "entry": entry.metadata(), "auto": true, "source": "site_pref"]
                    }
                }

                // 2) Saved login in UCU Vault matching domain (and optional account)
                if let entry = try vault.find(id: nil, domain: domain_norm, app: nil, kind: "login", account: account) {
                    return ["ok": true, "action": "password", "entry": entry.metadata(), "auto": true, "source": "vault"]
                }

                // 3) On-screen remembered browser account ("Continue as Fernanda", matching requested account if any)
                if !quickLogins.isEmpty {
                    let picked: String = {
                        if let account, !account.isEmpty,
                           let match = quickLogins.first(where: { $0.localizedCaseInsensitiveContains(account) }) {
                            return match
                        }
                        return quickLogins[0]
                    }()
                    return ["ok": true, "action": "quick_login", "label": picked, "auto": true, "source": "page_session"]
                }

                // 4) Passkey available on the page -> auto-trigger immediately so the user only taps Touch ID!
                if hasPasskey {
                    return ["ok": true, "action": "passkey", "auto": true, "source": "passkey_auto"]
                }

                // 5) Globally approved OAuth provider (e.g. user enabled "Always allow everywhere" for Google)
                for prov in availOAuth {
                    if vault.isRemembered("oauth:\(prov.lowercased())") {
                        let chosen = vault.bestAccount(domain: domain_norm, contextDomain: contextDomain,
                                                       provider: prov, hint: account)?.email ?? account
                        var out: [String: Any] = ["ok": true, "action": "oauth", "provider": prov,
                                                  "auto": true, "source": "global_oauth"]
                        if let chosen, !chosen.isEmpty { out["account"] = chosen }
                        return out
                    }
                }

                // 5) 2-step identity page (e.g. accounts.google.com email step before Passkey/Touch ID)
                if !hasPasswordField,
                   let acct = vault.bestAccount(domain: domain_norm, contextDomain: contextDomain,
                                                provider: nil, hint: account, requireMatch: true) {
                    return ["ok": true, "action": "account", "email": acct.email, "label": acct.label,
                            "auto": true, "source": "learned_account"]
                }

                return ["ok": true, "action": "ask"]

            case "set_auth_pref":
                guard let domain = normalizeHost(req["domain"] as? String),
                      let method = req["method"] as? String, !method.isEmpty else {
                    return ["ok": false, "error": "missing domain or method"]
                }
                vault.setAuthPref(domain: domain, method: method, provider: req["provider"] as? String,
                                  account: req["account"] as? String)
                return ["ok": true]

            case "vault_list":
                let items = try vault.list(
                    domain: req["domain"] as? String,
                    app: req["app"] as? String,
                    kind: req["kind"] as? String
                )
                return ["ok": true, "items": items, "has_secrets": vault.hasSecrets()]

            case "vault_store":
                guard let secret = req["secret"] as? String, !secret.isEmpty else {
                    return ["ok": false, "error": "empty secret"]
                }
                let kind = req["kind"] as? String ?? "api_key"
                let label = req["label"] as? String ?? (req["id"] as? String ?? kind)
                let domains = (req["domains"] as? [String]) ?? ((req["domain"] as? String).map { [$0] } ?? [])
                // Persist in the Keychain-backed encrypted vault by default unless caller explicitly passes remember=false.
                let ephemeral = !((req["remember"] as? Bool) ?? true)
                let entry = try vault.store(
                    id: req["id"] as? String,
                    kind: kind,
                    label: label,
                    domains: domains,
                    app: req["app"] as? String,
                    username: req["username"] as? String,
                    secret: secret,
                    autoApprove: (req["auto_approve"] as? Bool) ?? true,
                    ephemeral: ephemeral,
                    allowedDestinations: (req["allowed_destinations"] as? [String]) ?? []
                )
                if (req["toast"] as? Bool) ?? true {
                    let msg = kind == "login" ? "Saved \(entry.label)" : "Captured \(entry.id)"
                    DispatchQueue.main.async {
                        self.island.showToast(identity: identity, icon: "key.fill", text: msg)
                    }
                }
                return ["ok": true, "entry": entry.metadata()]

            case "vault_request":
                let kind = req["kind"] as? String ?? "login"
                let domain = normalizeHost(req["domain"] as? String)
                let app = req["app"] as? String
                let targetName = domain ?? app ?? (req["label"] as? String ?? "secret")
                let label = req["label"] as? String ?? targetName
                let title = req["title"] as? String ?? (kind == "login" ? "Sign in to \(targetName)" : "Enter \(label)")
                let subtitle = req["subtitle"] as? String ?? "Stored encrypted in UCU Vault · hidden from agent"
                let defaultRemember = (req["remember"] as? Bool) ?? (kind != "otp")
                let rememberLabel = "Remember for \(targetName)"
                let availOAuth = (req["available_oauth"] as? [String]) ?? []
                let hasPasskey = (req["has_passkey"] as? Bool) ?? false
                let decision = awaitUI(timeout) { done in
                    let item = InteractiveRequest(
                        identity: identity,
                        kind: .credential(
                            kind: kind,
                            title: title,
                            subtitle: subtitle,
                            badge: targetName,
                            usernameHint: req["username_hint"] as? String ?? "",
                            canShow: (req["can_show"] as? Bool) ?? false,
                            defaultRemember: defaultRemember,
                            rememberLabel: rememberLabel,
                            availableOAuth: availOAuth,
                            hasPasskey: hasPasskey
                        ),
                        completion: done
                    )
                    self.island.enqueue(item)
                    return item.id
                }
                switch decision {
                case .chooseAuth(let method, let provider, let remember):
                    if remember, let domain {
                        vault.setAuthPref(domain: domain, method: method, provider: provider,
                                          account: req["account"] as? String)
                    }
                    var out: [String: Any] = [
                        "ok": true,
                        "decision": "choose_auth",
                        "method": method,
                        "remembered": remember,
                    ]
                    if let provider { out["provider"] = provider }
                    return out
                case .filled(let username, let secret, let remember):
                    let entry = try vault.store(
                        id: req["id"] as? String ?? slugify(label),
                        kind: kind == "otp" ? "secret" : kind,
                        label: label,
                        domains: domain.map { [$0] } ?? [],
                        app: app,
                        username: username.isEmpty ? nil : username,
                        secret: secret,
                        autoApprove: true,
                        ephemeral: !remember || kind == "otp"
                    )
                if remember, kind == "login", let domain {
                    vault.setAuthPref(domain: domain, method: "password", provider: nil,
                                      account: username.isEmpty ? nil : username)
                    if !username.isEmpty && username.contains("@") {
                        let prov = domain.contains("google") ? "google" : (domain.contains("apple") ? "apple" : "email")
                        _ = vault.saveAccount(email: username, provider: prov, domains: [domain])
                    }
                }
                    var out: [String: Any] = [
                        "ok": true,
                        "decision": "filled",
                        "entry": entry.metadata(),
                        "remembered": !entry.ephemeral,
                        "secret": secret,
                    ]
                    if !username.isEmpty { out["username"] = username }
                    return out
                case .show:
                    return ["ok": true, "decision": "show"]
                case .denied:
                    return ["ok": true, "decision": "denied"]
                case .timeout, .approved:
                    return ["ok": true, "decision": "timeout"]
                }

            case "account_list":
                return ["ok": true, "accounts": vault.listAccounts()]

            case "account_save":
                guard let email = req["email"] as? String, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return ["ok": false, "error": "missing email"]
                }
                let saved = vault.saveAccount(
                    email: email,
                    provider: req["provider"] as? String ?? "google",
                    label: req["label"] as? String ?? "",
                    purpose: req["purpose"] as? String ?? "",
                    domains: (req["domains"] as? [String]) ?? [],
                    isDefault: (req["is_default"] as? Bool) ?? false
                )
                return ["ok": true, "account": saved.toDict()]

            case "vault_resolve":
                let entryId = req["id"] as? String
                let targetDomain = normalizeHost(req["target_domain"] as? String)
                let contextDomain = normalizeHost(req["context_domain"] as? String)
                let targetApp = req["target_app"] as? String
                let targetFile = req["target_file"] as? String
                let kind = req["kind"] as? String
                let account = req["account"] as? String
                let hasPasswordField = (req["has_password"] as? Bool) ?? false
                guard let entry = try vault.find(id: entryId, domain: targetDomain, app: targetApp, kind: kind, account: account) else {
                    // For 2-step / Passkey identity pages (like accounts.google.com without a password field yet),
                    // resolve an explicitly matched learned account email so the agent doesn't prompt unnecessarily.
                    if (kind == nil || kind == "login"), targetDomain != nil, !hasPasswordField,
                       let acct = vault.bestAccount(domain: targetDomain, contextDomain: contextDomain,
                                                    provider: req["provider"] as? String, hint: account,
                                                    requireMatch: true) {
                        vault.recordAccountUse(email: acct.email, domain: targetDomain, contextDomain: contextDomain)
                        DispatchQueue.main.async {
                            self.island.showToast(identity: identity, icon: "person.fill",
                                                  text: "Using \(acct.email)")
                        }
                        return [
                            "ok": true,
                            "found": true,
                            "decision": "approved",
                            "kind": "account",
                            "username": acct.email,
                            "secret": "",
                            "entry": ["id": acct.id, "kind": "account", "label": acct.label, "username": acct.email],
                        ]
                    }
                    return ["ok": true, "found": false]
                }

                // Anti-phishing boundary: logins can NEVER be released to a different domain.
                if entry.kind == "login" {
                    if let targetDomain {
                        guard entry.domains.contains(where: { hostMatches(targetDomain, allowed: $0) }) else {
                            return [
                                "ok": false,
                                "error": "Domain mismatch: login \(entry.id) belongs to \(entry.domains.joined(separator: ", ")), not \(targetDomain).",
                            ]
                        }
                    } else if let targetApp, let entryApp = entry.app, !entryApp.isEmpty {
                        guard targetApp.lowercased() == entryApp.lowercased() else {
                            return ["ok": false, "error": "App mismatch: login \(entry.id) belongs to \(entryApp), not \(targetApp)."]
                        }
                    } else if !entry.domains.isEmpty {
                        return ["ok": false, "error": "Login \(entry.id) is bound to \(entry.domains.joined(separator: ", "))."]
                    }
                }

                let destinationKey = targetDomain.map { "domain:\($0)" }
                    ?? targetFile.map { "file:\($0)" }
                    ?? targetApp.map { "app:\($0.lowercased())" }
                    ?? "unknown"
                let destinationLabel = targetDomain
                    ?? targetFile.map { ($0 as NSString).lastPathComponent }
                    ?? targetApp
                    ?? "destination"

                let domainAlreadyBound = targetDomain.map { host in
                    entry.domains.contains { hostMatches(host, allowed: $0) }
                } ?? false
                let appAlreadyBound = targetApp.map { app in
                    entry.app?.lowercased() == app.lowercased()
                } ?? false
                let destinationRemembered = entry.allowedDestinations.contains(destinationKey)
                    || vault.isRemembered("paste:\(entry.id):\(destinationKey)")

                let forceConfirm = (req["confirm"] as? Bool) ?? false
                // Local `.env` environment variable writes are seamless (zero popup, Keychain-backed vault + toast).
                let isLocalEnvFile = targetFile != nil
                let autonomous = !forceConfirm && (
                    isLocalEnvFile
                    || (entry.autoApprove && (
                        (entry.kind == "login" && (domainAlreadyBound || appAlreadyBound))
                        || (entry.kind != "login" && (domainAlreadyBound || appAlreadyBound || destinationRemembered))
                    ))
                )

                if !autonomous {
                    let actionTitle = entry.kind == "login"
                        ? "Fill \(entry.label) login"
                        : "Paste \(entry.label) → \(destinationLabel)"
                    let actionDetail = req["reason"] as? String
                        ?? (targetFile ?? (targetDomain ?? (targetApp ?? "")))
                    let decision = awaitUI(timeout) { done in
                        let item = InteractiveRequest(
                            identity: identity,
                            kind: .approve(
                                title: actionTitle,
                                detail: actionDetail,
                                badge: destinationLabel,
                                canShow: (req["can_show"] as? Bool) ?? false,
                                canRemember: true,
                                rememberLabel: "Always allow for \(destinationLabel)",
                                canRememberGlobal: false,
                                globalLabel: "",
                                requireTouchID: (req["touch_id"] as? Bool) ?? false,
                                icon: "key.fill"
                            ),
                            completion: done
                        )
                        self.island.enqueue(item)
                        return item.id
                    }
                    switch decision {
                    case .approved(let remembered, _):
                        vault.recordUse(id: entry.id, addDestination: remembered ? destinationKey : nil)
                        if remembered { vault.rememberApproval("paste:\(entry.id):\(destinationKey)", persist: true) }
                    case .show:
                        return ["ok": true, "found": true, "decision": "show", "entry": entry.metadata()]
                    case .denied:
                        return ["ok": true, "found": true, "decision": "denied", "entry": entry.metadata()]
                    case .timeout, .filled, .chooseAuth:
                        return ["ok": true, "found": true, "decision": "timeout", "entry": entry.metadata()]
                    }
                } else {
                    vault.recordUse(id: entry.id)
                    let toastMsg = entry.kind == "login"
                        ? "Filled \(destinationLabel)"
                        : "Pasted \(entry.id) → \(destinationLabel)"
                    DispatchQueue.main.async {
                        self.island.showToast(identity: identity, icon: "key.fill", text: toastMsg)
                    }
                }

                var out: [String: Any] = [
                    "ok": true,
                    "found": true,
                    "decision": "approved",
                    "entry": entry.metadata(),
                    "secret": entry.secret,
                ]
                if let username = entry.username { out["username"] = username }
                return out

            case "vault_delete":
                guard let id = req["id"] as? String, !id.isEmpty else {
                    return ["ok": false, "error": "missing id"]
                }
                if (req["confirm"] as? Bool) ?? true {
                    let decision = awaitUI(timeout) { done in
                        let item = InteractiveRequest(
                            identity: identity,
                            kind: .approve(
                                title: "Delete vault item \"\(id)\"?",
                                detail: "This removes the saved secret from UCU Vault.",
                                badge: "Vault",
                                canShow: false,
                                canRemember: false,
                                rememberLabel: "",
                                canRememberGlobal: false,
                                globalLabel: "",
                                requireTouchID: false,
                                icon: "trash.fill"
                            ),
                            completion: done
                        )
                        self.island.enqueue(item)
                        return item.id
                    }
                    guard case .approved = decision else {
                        return ["ok": true, "deleted": false, "decision": "denied"]
                    }
                }
                let removed = try vault.delete(id: id)
                return ["ok": true, "deleted": removed]

            case "redact":
                let text = req["text"] as? String ?? ""
                return ["ok": true, "text": vault.redact(text)]

            default:
                return ["ok": false, "error": "unknown op: \(op)"]
            }
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }
}

// MARK: - Direct CLI Helpers (for `./ucu vault` and `./ucu island demo`)

func cliVault(_ args: [String]) -> Never {
    let store = VaultStore()
    guard let sub = args.first else {
        fail("usage: ucu-island vault list | add <id> [--kind ...] [--label ...] [--domain ...] [--app ...] [--username ...] | remove <id>")
    }
    do {
        switch sub {
        case "list":
            let items = try store.list()
            let data = try JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .sortedKeys])
            print(String(data: data, encoding: .utf8) ?? "[]")
            exit(0)
        case "add":
            guard args.count >= 2 else { fail("usage: ucu-island vault add <id> [options] (reads secret from stdin)") }
            let id = args[1]
            var kind = "login", label = id, domains: [String] = [], app: String? = nil, username: String? = nil
            var autoApprove = true
            var i = 2
            while i < args.count {
                let flag = args[i]
                func nextVal() -> String {
                    i += 1
                    guard i < args.count else { fail("missing value for \(flag)") }
                    return args[i]
                }
                switch flag {
                case "--kind": kind = nextVal()
                case "--label": label = nextVal()
                case "--domain": domains.append(nextVal())
                case "--app": app = nextVal()
                case "--username": username = nextVal()
                case "--ask": autoApprove = false
                default: fail("unknown option \(flag)")
                }
                i += 1
            }
            let raw = FileHandle.standardInput.readDataToEndOfFile()
            let secret = (String(data: raw, encoding: .utf8) ?? "").trimmingCharacters(in: .newlines)
            guard !secret.isEmpty else { fail("no secret provided on stdin") }
            let entry = try store.store(
                id: id, kind: kind, label: label, domains: domains, app: app,
                username: username, secret: secret, autoApprove: autoApprove, ephemeral: false
            )
            let data = try JSONSerialization.data(withJSONObject: entry.metadata(), options: [.sortedKeys])
            print(String(data: data, encoding: .utf8) ?? "{}")
            exit(0)
        case "remove":
            guard args.count >= 2 else { fail("usage: ucu-island vault remove <id>") }
            let removed = try store.delete(id: args[1])
            print(removed ? "removed \(args[1])" : "not found: \(args[1])")
            exit(removed ? 0 : 2)
        default:
            fail("unknown vault command \(sub)")
        }
    } catch {
        fail(error.localizedDescription)
    }
}

func runDemo(_ kind: String) -> Never {
    let controller = NotchIslandController()
    NSApplication.shared.setActivationPolicy(.accessory)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        switch kind {
        case "passkey":
            let id = AgentIdentity(harness: "Claude Code", harnessId: "claude", agent: "auth-agent",
                                   color: colorFromHex("#E8590C"))
            controller.setPasskey(active: true, identity: id, prompt: "Please touch the key",
                                  detail: "Passkey · github.com", timeout: 8)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) {
                controller.setPasskey(active: false, identity: id, prompt: nil, detail: nil, timeout: 0)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exit(0) }
            }
        case "pile":
            let a1 = AgentIdentity(harness: "Claude Code", harnessId: "claude", agent: "deploy-agent",
                                   color: colorFromHex("#E8590C"))
            let a2 = AgentIdentity(harness: "Cursor", harnessId: "cursor", agent: "backend-agent",
                                   color: colorFromHex("#3358D4"))
            let a3 = AgentIdentity(harness: "Codex", harnessId: "codex", agent: "api-setup",
                                   color: colorFromHex("#2B9A66"))
            controller.updateAgent(sessionId: "demo-1", pid: nil, identity: a1, active: true,
                                   app: "Google Chrome", windowTitle: "Vercel", cgWindowId: nil,
                                   action: "Clicking \"Deploy\" on vercel.com", cursorNorm: CGPoint(x: 0.72, y: 0.34))
            controller.updateAgent(sessionId: "demo-2", pid: nil, identity: a2, active: true,
                                   app: "Safari", windowTitle: "GitHub", cgWindowId: nil,
                                   action: "Creating API token on github.com", cursorNorm: CGPoint(x: 0.54, y: 0.62))
            controller.updateAgent(sessionId: "demo-3", pid: nil, identity: a3, active: true,
                                   app: "Terminal", windowTitle: "env", cgWindowId: nil,
                                   action: "Reading Stripe webhooks", cursorNorm: CGPoint(x: 0.38, y: 0.45))
            DispatchQueue.main.asyncAfter(deadline: .now() + 25.0) { exit(0) }
        case "toast":
            let id = AgentIdentity(harness: "Codex", harnessId: "codex", agent: "api-bot",
                                   color: colorFromHex("#2B9A66"))
            controller.showToast(identity: id, icon: "key.fill", text: "Filled github.com", duration: 3.0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { exit(0) }
        case "login":
            let id = AgentIdentity(harness: "Cursor", harnessId: "cursor", agent: "backend-agent",
                                   color: colorFromHex("#3358D4"))
            let req = InteractiveRequest(
                identity: id,
                kind: .credential(
                    kind: "login",
                    title: "Sign in to github.com",
                    subtitle: "Stored encrypted in UCU Vault · hidden from agent",
                    badge: "github.com",
                    usernameHint: "",
                    canShow: true,
                    defaultRemember: true,
                    rememberLabel: "Remember for github.com",
                    availableOAuth: ["Google", "Apple"],
                    hasPasskey: true
                )
            ) { decision in
                print("demo result: \(decision)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
            }
            controller.enqueue(req)
        case "showcase":
            let a1 = AgentIdentity(harness: "Claude Code", harnessId: "claude", agent: "deploy-agent",
                                   color: colorFromHex("#E8590C"))
            let a2 = AgentIdentity(harness: "Cursor", harnessId: "cursor", agent: "backend-agent",
                                   color: colorFromHex("#3358D4"))
            let a3 = AgentIdentity(harness: "Codex", harnessId: "codex", agent: "api-setup",
                                   color: colorFromHex("#2B9A66"))
            // 1) Left-side tight cursor pile springs out of notch
            controller.updateAgent(sessionId: "s1", pid: nil, identity: a1, active: true,
                                   app: "Google Chrome", windowTitle: "Vercel", cgWindowId: nil,
                                   action: "Clicking \"Deploy\" on vercel.com", cursorNorm: CGPoint(x: 0.72, y: 0.34))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                controller.updateAgent(sessionId: "s2", pid: nil, identity: a2, active: true,
                                       app: "Safari", windowTitle: "GitHub", cgWindowId: nil,
                                       action: "Saving OPENAI_API_KEY on vercel.com", cursorNorm: CGPoint(x: 0.80, y: 0.76))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                controller.updateAgent(sessionId: "s3", pid: nil, identity: a3, active: true,
                                       app: "Terminal", windowTitle: "env", cgWindowId: nil,
                                       action: "Reading webhooks on stripe.com", cursorNorm: CGPoint(x: 0.42, y: 0.50))
            }
            // 2) Touch ID biometric split with radar pulse & rose rim sweep
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                controller.setPasskey(active: true, identity: a1, prompt: "Please touch the key", detail: "", timeout: 4)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.6) {
                controller.setPasskey(active: false, identity: a1, prompt: nil, detail: nil, timeout: 0)
            }
            // 3) Autonomous toast sweep
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.4) {
                controller.showToast(identity: a3, icon: "key.fill", text: "Filled github.com", duration: 2.2)
            }
            // 4) Clear agents → futuristic staged close back into the notch
            DispatchQueue.main.asyncAfter(deadline: .now() + 9.4) {
                for sid in ["s1", "s2", "s3"] {
                    controller.updateAgent(sessionId: sid, pid: nil, identity: a1, active: false,
                                           app: nil, windowTitle: nil, cgWindowId: nil, action: nil, cursorNorm: nil)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.2) { exit(0) }
        default:
            let id = AgentIdentity(harness: "Claude Code", harnessId: "claude", agent: "deploy-agent",
                                   color: colorFromHex("#E8590C"))
            let req = InteractiveRequest(
                identity: id,
                kind: .approve(
                    title: "Click \"Continue with Google\"",
                    detail: "Sign in to vercel.com with your Google account",
                    badge: "vercel.com",
                    canShow: true,
                    canRemember: true,
                    rememberLabel: "Always allow on vercel.com",
                    canRememberGlobal: true,
                    globalLabel: "Always allow everywhere",
                    requireTouchID: false,
                    icon: "person.badge.key.fill"
                )
            ) { decision in
                print("demo result: \(decision)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
            }
            controller.enqueue(req)
        }
    }
    NSApplication.shared.run()
    exit(0)
}

// Render a 2x Retina storyboard PNG of the real Swift AppKit Notch Island views across all 4 states & harnesses.
func renderPreview(to outputPath: String) -> Never {
    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.prohibited)
    let controller = NotchIslandController()
    let screen = NSScreen.screens.first!
    let fakeGeo = NotchGeometry(screen: screen, hasNotch: true, notchWidth: 185, notchHeight: 32,
                                centerX: 460, topY: 300)

    final class StageView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                colors: [NSColor(srgbRed: 0.08, green: 0.09, blue: 0.13, alpha: 1).cgColor,
                                         NSColor(srgbRed: 0.04, green: 0.05, blue: 0.07, alpha: 1).cgColor] as CFArray,
                                locations: [0, 1])!
            ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: bounds.maxY), end: CGPoint(x: 0, y: 0), options: [])
        }
    }

    final class MacBarCard: NSView {
        let caption: String
        let subcaption: String
        let islandSize: CGSize
        let islandBackdrop: IslandBackdropView
        let notchW: CGFloat = 185
        let notchH: CGFloat = 32

        init(frame: NSRect, caption: String, subcaption: String, islandRect: NSRect, islandBackdrop: IslandBackdropView) {
            self.caption = caption
            self.subcaption = subcaption
            self.islandSize = islandRect.size
            self.islandBackdrop = islandBackdrop
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = 16
            layer?.masksToBounds = true
            layer?.borderWidth = 1
            layer?.borderColor = NSColor(white: 1.0, alpha: 0.10).cgColor

            islandBackdrop.frame = islandRect
            addSubview(islandBackdrop)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            let w = bounds.width, h = bounds.height
            let screenTop = h - 46
            // Header strip above simulated MacBook bezel
            ctx.setFillColor(NSColor(srgbRed: 0.10, green: 0.11, blue: 0.14, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: screenTop, width: w, height: 46))

            // Simulated macOS wallpaper area
            let wp = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                colors: [NSColor(srgbRed: 0.16, green: 0.24, blue: 0.42, alpha: 1).cgColor,
                                         NSColor(srgbRed: 0.28, green: 0.20, blue: 0.38, alpha: 1).cgColor,
                                         NSColor(srgbRed: 0.14, green: 0.20, blue: 0.30, alpha: 1).cgColor] as CFArray,
                                locations: [0, 0.55, 1])!
            ctx.drawLinearGradient(wp, start: CGPoint(x: 0, y: screenTop), end: CGPoint(x: w, y: 0), options: [])

            // Translucent macOS menu bar
            ctx.setFillColor(NSColor(white: 0.08, alpha: 0.38).cgColor)
            ctx.fill(CGRect(x: 0, y: screenTop - notchH, width: w, height: notchH))

            // Subtle menu bar text left & right so the notch sits in real context
            let barAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor(white: 1.0, alpha: 0.78),
            ]
            ("   Cursor   File   Edit" as NSString).draw(at: CGPoint(x: 16, y: screenTop - 22), withAttributes: barAttrs)
            let rightBar = "Wi-Fi   100%   11:48 AM" as NSString
            let rw = rightBar.size(withAttributes: barAttrs).width
            rightBar.draw(at: CGPoint(x: w - rw - 16, y: screenTop - 22), withAttributes: barAttrs)

            // Physical MacBook Pro center camera notch outline (flush at exact notchH = 32pt)
            let nx = (w - notchW) / 2
            let notchRect = CGRect(x: nx, y: screenTop - notchH, width: notchW, height: notchH + 12)
            ctx.setFillColor(NSColor.black.cgColor)
            let np = CGPath(roundedRect: notchRect, cornerWidth: 10, cornerHeight: 10, transform: nil)
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: 0, width: w, height: screenTop))
            ctx.addPath(np); ctx.fillPath()
            ctx.restoreGState()
            // Subtle webcam lens indicator inside the hardware notch
            ctx.setFillColor(NSColor(srgbRed: 0.14, green: 0.18, blue: 0.26, alpha: 0.9).cgColor)
            ctx.fillEllipse(in: CGRect(x: w / 2 - 4, y: screenTop - 20, width: 8, height: 8))
            ctx.setFillColor(NSColor(srgbRed: 0.25, green: 0.42, blue: 0.65, alpha: 0.5).cgColor)
            ctx.fillEllipse(in: CGRect(x: w / 2 - 1.5, y: screenTop - 17.5, width: 3, height: 3))

            // Caption strip
            let capAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13.5, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let subAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .regular),
                .foregroundColor: NSColor(white: 1.0, alpha: 0.58),
            ]
            (caption as NSString).draw(at: CGPoint(x: 18, y: screenTop + 21), withAttributes: capAttrs)
            (subcaption as NSString).draw(at: CGPoint(x: 18, y: screenTop + 5), withAttributes: subAttrs)
        }
    }

    func makeCentered(_ build: (NSView) -> CGSize) -> (CGFloat, CGFloat, IslandBackdropView) {
        let backdrop = IslandBackdropView(frame: .zero)
        backdrop.hasNotch = true
        backdrop.leftEar = true
        backdrop.rightEar = true
        backdrop.useShadowPadding = false
        let host = NSView(frame: .zero)
        host.autoresizingMask = [.width, .height]
        backdrop.contentContainer.addSubview(host)
        let inner = build(host)
        let fullW = inner.width + 24
        let full = NSRect(x: 0, y: 0, width: fullW, height: inner.height)
        backdrop.frame = full
        backdrop.contentContainer.frame = full
        host.frame = full
        backdrop.layoutSubtreeIfNeeded()
        return (fullW, inner.height, backdrop)
    }

    func makeLeftOnly(_ build: (NSView) -> (leftExtra: CGFloat, height: CGFloat)) -> (CGFloat, CGFloat, CGFloat, IslandBackdropView) {
        let backdrop = IslandBackdropView(frame: .zero)
        backdrop.hasNotch = true
        backdrop.leftEar = true
        backdrop.rightEar = false
        backdrop.useShadowPadding = false
        let host = NSView(frame: .zero)
        host.autoresizingMask = [.width, .height]
        backdrop.contentContainer.addSubview(host)
        let res = build(host)
        let fullW = 12 + res.leftExtra + fakeGeo.notchWidth
        let full = NSRect(x: 0, y: 0, width: fullW, height: res.height)
        backdrop.frame = full
        backdrop.contentContainer.frame = full
        host.frame = full
        backdrop.layoutSubtreeIfNeeded()
        return (res.leftExtra, fullW, res.height, backdrop)
    }

    // Crisp mock browser thumbnail for the preview card showing what an agent is seeing in its background tab.
    func makeSampleThumbnail() -> NSImage {
        let size = NSSize(width: 530, height: 372)
        return NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
            ctx.setFillColor(NSColor(srgbRed: 0.06, green: 0.07, blue: 0.09, alpha: 1).cgColor)
            ctx.fill(rect)
            // Browser chrome bar
            ctx.setFillColor(NSColor(srgbRed: 0.11, green: 0.12, blue: 0.15, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: rect.height - 34, width: rect.width, height: 34))
            for (i, c) in [NSColor.systemRed, NSColor.systemYellow, NSColor.systemGreen].enumerated() {
                ctx.setFillColor(c.withAlphaComponent(0.75).cgColor)
                ctx.fillEllipse(in: CGRect(x: 14 + CGFloat(i) * 14, y: rect.height - 21, width: 8, height: 8))
            }
            ctx.setFillColor(NSColor(white: 1.0, alpha: 0.08).cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 100, y: rect.height - 26, width: 330, height: 18), cornerWidth: 6, cornerHeight: 6, transform: nil))
            ctx.fillPath()
            ("vercel.com / universal-computer-use / settings" as NSString).draw(
                at: CGPoint(x: 116, y: rect.height - 24),
                withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 1.0, alpha: 0.65)]
            )
            // Mini dashboard card inside page
            ctx.setFillColor(NSColor(srgbRed: 0.10, green: 0.11, blue: 0.14, alpha: 1).cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 24, y: 26, width: rect.width - 48, height: rect.height - 84), cornerWidth: 14, cornerHeight: 14, transform: nil))
            ctx.fillPath()
            ctx.setStrokeColor(NSColor(white: 1.0, alpha: 0.10).cgColor)
            ctx.setLineWidth(1)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 24, y: 26, width: rect.width - 48, height: rect.height - 84), cornerWidth: 14, cornerHeight: 14, transform: nil))
            ctx.strokePath()
            ("Environment Variables" as NSString).draw(
                at: CGPoint(x: 42, y: rect.height - 96),
                withAttributes: [.font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: NSColor.white]
            )
            ("Add or update keys synced across deployments" as NSString).draw(
                at: CGPoint(x: 42, y: rect.height - 120),
                withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(white: 1.0, alpha: 0.50)]
            )
            // Fake key/value inputs
            ctx.setFillColor(NSColor(white: 1.0, alpha: 0.06).cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 42, y: 172, width: 190, height: 36), cornerWidth: 7, cornerHeight: 7, transform: nil))
            ctx.addPath(CGPath(roundedRect: CGRect(x: 242, y: 172, width: 246, height: 36), cornerWidth: 7, cornerHeight: 7, transform: nil))
            ctx.fillPath()
            ("OPENAI_API_KEY" as NSString).draw(
                at: CGPoint(x: 54, y: 183),
                withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .medium), .foregroundColor: NSColor(white: 1.0, alpha: 0.85)]
            )
            ("••••••••••••••••••••••••" as NSString).draw(
                at: CGPoint(x: 256, y: 183),
                withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(white: 1.0, alpha: 0.55)]
            )
            ctx.setFillColor(NSColor(white: 1.0, alpha: 0.04).cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 42, y: 122, width: 446, height: 34), cornerWidth: 7, cornerHeight: 7, transform: nil))
            ctx.fillPath()
            ("Production · Preview · Development" as NSString).draw(
                at: CGPoint(x: 54, y: 132),
                withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(white: 1.0, alpha: 0.58)]
            )
            // Primary Save & Deploy button where the blue cursor points
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 368, y: 52, width: 120, height: 36), cornerWidth: 9, cornerHeight: 9, transform: nil))
            ctx.fillPath()
            ("Save & Deploy" as NSString).draw(
                at: CGPoint(x: 386, y: 62),
                withAttributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: NSColor.black]
            )
            return true
        }
    }

    let demoAgents: [ActiveAgent] = [
        ActiveAgent(sessionId: "a1", pid: nil,
                    identity: AgentIdentity(harness: "Claude Code", harnessId: "claude", agent: "deploy-agent",
                                            color: colorFromHex("#E8590C")),
                    app: "Google Chrome", windowTitle: "Vercel", cgWindowId: nil,
                    action: "Clicking \"Deploy\" on vercel.com", cursorNorm: CGPoint(x: 0.72, y: 0.34), updatedAt: Date()),
        ActiveAgent(sessionId: "a2", pid: nil,
                    identity: AgentIdentity(harness: "Cursor", harnessId: "cursor", agent: "backend-agent",
                                            color: colorFromHex("#3358D4")),
                    app: "Google Chrome", windowTitle: "Vercel Settings", cgWindowId: nil,
                    action: "Saving OPENAI_API_KEY on vercel.com", cursorNorm: CGPoint(x: 0.80, y: 0.76), updatedAt: Date()),
        ActiveAgent(sessionId: "a3", pid: nil,
                    identity: AgentIdentity(harness: "Codex", harnessId: "codex", agent: "api-setup",
                                            color: colorFromHex("#2B9A66")),
                    app: "Safari", windowTitle: "Stripe", cgWindowId: nil,
                    action: "Reading webhooks on stripe.com", cursorNorm: CGPoint(x: 0.42, y: 0.50), updatedAt: Date()),
    ]

    let cardW: CGFloat = 900
    enum CardPlacement {
        case centered(CGFloat, CGFloat, IslandBackdropView)
        case leftOnly(CGFloat, CGFloat, CGFloat, IslandBackdropView)
        case asymmetric(CGFloat, CGFloat, CGFloat, IslandBackdropView)
    }

    let p0 = makeLeftOnly { host in
        controller.populateCursorPile(in: host, agents: demoAgents, geo: fakeGeo)
    }
    let p1 = makeCentered { host in
        controller.populateAgentHover(in: host, agents: demoAgents, selected: demoAgents[1],
                                      thumbnail: makeSampleThumbnail(), geo: fakeGeo)
    }
    let s1 = makeCentered { host in
        controller.populatePasskey(
            in: host,
            banner: PasskeyBanner(
                identity: demoAgents[0].identity,
                prompt: "Please touch the key",
                detail: ""
            ),
            geo: fakeGeo,
            animate: false
        )
    }
    let s2 = makeCentered { host in
        let req = InteractiveRequest(
            identity: demoAgents[0].identity,
            kind: .approve(
                title: "Click \"Continue with Google\"",
                detail: "Sign in to vercel.com with your Google account",
                badge: "vercel.com",
                canShow: true,
                canRemember: true,
                rememberLabel: "Always allow on vercel.com",
                canRememberGlobal: true,
                globalLabel: "Always allow everywhere",
                requireTouchID: false,
                icon: "person.badge.key.fill"
            )
        ) { _ in }
        return controller.populateApproval(in: host, request: req, queueExtra: 0, geo: fakeGeo, expanded: false)
    }
    let s2Hover = makeCentered { host in
        let req = InteractiveRequest(
            identity: demoAgents[0].identity,
            kind: .approve(
                title: "Click \"Continue with Google\"",
                detail: "Sign in to vercel.com with your Google account",
                badge: "vercel.com",
                canShow: true,
                canRemember: true,
                rememberLabel: "Always allow on vercel.com",
                canRememberGlobal: true,
                globalLabel: "Always allow everywhere",
                requireTouchID: false,
                icon: "person.badge.key.fill"
            )
        ) { _ in }
        return controller.populateApproval(in: host, request: req, queueExtra: 0, geo: fakeGeo, expanded: true)
    }
    let s3Compact = makeCentered { host in
        let req = InteractiveRequest(
            identity: demoAgents[1].identity,
            kind: .credential(
                kind: "login",
                title: "Sign in to github.com",
                subtitle: "Stored encrypted in UCU Vault · hidden from agent",
                badge: "github.com",
                usernameHint: "beto@company.com",
                canShow: true,
                defaultRemember: true,
                rememberLabel: "Remember for github.com",
                availableOAuth: ["Google", "Apple"],
                hasPasskey: true
            )
        ) { _ in }
        return controller.populateCredential(in: host, request: req, queueExtra: 0, geo: fakeGeo, expanded: false)
    }
    let s3 = makeCentered { host in
        let req = InteractiveRequest(
            identity: demoAgents[1].identity,
            kind: .credential(
                kind: "login",
                title: "Sign in to github.com",
                subtitle: "Stored encrypted in UCU Vault · hidden from agent",
                badge: "github.com",
                usernameHint: "beto@company.com",
                canShow: true,
                defaultRemember: true,
                rememberLabel: "Remember for github.com",
                availableOAuth: ["Google", "Apple"],
                hasPasskey: true
            )
        ) { _ in }
        return controller.populateCredential(in: host, request: req, queueExtra: 0, geo: fakeGeo, expanded: true)
    }

    let cards: [(String, String, CardPlacement, CGFloat)] = [
        ("1. Active Agent Cursors Piled Tight on Left of Notch (occasional subtle alive wiggle)",
         "Tightly stacked colored dart cursors; move near or glide across to cycle screens",
         .leftOnly(p0.0, p0.1, p0.2, p0.3), 124),
        ("2. Hover / Glide Preview — Symmetrical Under Notch, Bigger & Instant Pre-Warmed Live Screen",
         "Resting pile stays left-only; hovering expands symmetrically centered below notch with 120Hz proximity glide",
         .centered(p1.0, p1.1, p1.2), 404),
        ("3. Passkey / Touch ID Split — minimal with biometric radar pulse & rose rim sweep",
         "Only Touch ID on the left and \"Please touch the key\" on the right; auto-collapses on tap",
         .centered(s1.0, s1.1, s1.2), 126),
        ("4a. Quick Approval (Resting) — ONLY Google G logo on left, [✓ Allow] [✕] [⌄] on right",
         "Ultra-minimal single-liner; Always allow everywhere is ON by default; click ⌄ to toggle options",
         .asymmetric(54, s2.0, s2.1, s2.2), 126),
        ("4b. Quick Approval (Clicked ⌄) — Opens ∞ Always Everywhere + 👁 View Drawer",
         "Explicit click toggle (no accidental hover drops); toggle Always/Once or click View for frontmost tab",
         .centered(s2Hover.0, s2Hover.1, s2Hover.2), 166),
        ("5a. Compact Login Pill (Default) — Harness Logo on left, [Site Logo] Sign in ⌄ on right",
         "Takes zero vertical space over your app until you hover or click to expand",
         .asymmetric(52, s3Compact.0, s3Compact.1, s3Compact.2), 126),
        ("5b. Inline Vault Login (Hovered / Clicked) — One-Tap Google / Passkey + Apple Passwords",
         "Pick Google, Passkey, Passwords, or enter once — UCU remembers your preferred method per site forever",
         .centered(s3.0, s3.1, s3.2), 350),
    ]

    let pad: CGFloat = 24, gap: CGFloat = 18
    let totalH = pad * 2 + cards.reduce(0) { $0 + $1.3 } + gap * CGFloat(cards.count - 1)
    let stageW = cardW + pad * 2
    let stage = StageView(frame: NSRect(x: 0, y: 0, width: stageW, height: totalH))
    stage.wantsLayer = true

    var curY = totalH - pad
    for (cap, sub, placement, cardH) in cards {
        curY -= cardH
        let screenTop = cardH - 46
        let islandRect: NSRect
        let backdrop: IslandBackdropView
        switch placement {
        case let .centered(w, h, view):
            islandRect = NSRect(x: round((cardW - w) / 2), y: screenTop - h, width: w, height: h)
            backdrop = view
        case let .leftOnly(leftExtra, fullW, h, view):
            let notchLeft = (cardW - fakeGeo.notchWidth) / 2
            islandRect = NSRect(x: round(notchLeft - leftExtra - 12), y: screenTop - h, width: fullW, height: h)
            backdrop = view
        case let .asymmetric(leftExtra, fullW, h, view):
            let notchLeft = (cardW - fakeGeo.notchWidth) / 2
            islandRect = NSRect(x: round(notchLeft - leftExtra - 12), y: screenTop - h, width: fullW, height: h)
            backdrop = view
        }
        let card = MacBarCard(frame: NSRect(x: pad, y: curY, width: cardW, height: cardH),
                              caption: cap, subcaption: sub, islandRect: islandRect, islandBackdrop: backdrop)
        stage.addSubview(card)
        curY -= gap
    }

    // Attach to an offscreen window so CoreAnimation layers + AppKit controls render identically at 2x Retina.
    let win = NSWindow(contentRect: stage.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    win.contentView = stage
    stage.layoutSubtreeIfNeeded()
    stage.displayIfNeeded()

    let scale = 2
    let pxW = Int(stageW) * scale, pxH = Int(totalH) * scale
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fail("could not allocate bitmap") }
    rep.size = stage.frame.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    stage.cacheDisplay(in: stage.bounds, to: rep)
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else { fail("png encoding failed") }
    do {
        try png.write(to: URL(fileURLWithPath: outputPath))
        print("rendered \(outputPath) (\(pxW)x\(pxH))")
        exit(0)
    } catch {
        fail("could not write \(outputPath): \(error.localizedDescription)")
    }
}

// MARK: - Entry Point

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    fail("usage: ucu-island serve | version | vault <list|add|remove> | demo <passkey|approve|login|toast> | render-preview <out.png>")
}
switch command {
case "serve":
    IslandDaemon().run()
case "version":
    print(VERSION)
case "vault":
    cliVault(Array(args.dropFirst()))
case "demo":
    runDemo(args.dropFirst().first ?? "approve")
case "render-preview":
    guard args.count >= 2 else { fail("usage: ucu-island render-preview <output.png>") }
    renderPreview(to: args[1])
default:
    fail("unknown command \(command)")
}
