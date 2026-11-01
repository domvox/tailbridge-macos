import Foundation

/// The Tailscale App Store extension reads KEY=VALUE pairs from this file at start.
/// Managed as the user, never as root.
struct EnvFile {
    static let legacy = "# Local Mullvad coexistence test; remove this file to undo.\nTS_BIND_TO_INTERFACE_BY_ROUTE=1\n"
    static let ours = "# TailBridge managed: route-based interface selection (removed by TailBridge \"Wyłącz\")\nTS_BIND_TO_INTERFACE_BY_ROUTE=1\n"

    enum State: Equatable { case absent, ours, legacy, foreign(String) }

    var path: String
    var backupDir: String
    var owner: uid_t

    static func standard(home: String = NSHomeDirectory(), owner: uid_t = getuid()) -> EnvFile {
        EnvFile(path: home + "/Library/Containers/io.tailscale.ipn.macos.network-extension/Data/tailscaled-env.txt",
                backupDir: home + "/Library/Application Support/TailBridge/backups",
                owner: owner)
    }

    var dir: String { (path as NSString).deletingLastPathComponent }

    func state() -> State {
        let i = SafeFiles.info(path)
        switch i.kind {
        case .absent: return .absent
        case .regular:
            guard i.uid == owner else { return .foreign("nieoczekiwany właściciel") }
            guard let s = try? SafeFiles.read(path) else { return .foreign("nieczytelny") }
            if s == EnvFile.ours { return .ours }
            if s == EnvFile.legacy { return .legacy }
            return .foreign("nierozpoznana treść — może zawierać Twoje ustawienia")
        default: return .foreign("nie jest zwykłym plikiem")
        }
    }

    private func checkDir() throws {
        let i = SafeFiles.info(dir)
        guard i.kind == .directory, i.uid == owner else {
            throw FSError("katalog kontenera Tailscale nie istnieje lub nie należy do użytkownika (czy to wersja z App Store?)")
        }
    }

    /// Returns true if a new file was created (Tailscale restart needed).
    func apply() throws -> Bool {
        switch state() {
        case .ours, .legacy: return false
        case .foreign(let why): throw FSError("\(path): \(why); odmowa nadpisania")
        case .absent:
            try checkDir()
            try SafeFiles.createExclusive(path, EnvFile.ours, mode: 0o600)
            return true
        }
    }

    /// Moves a recognised file to backups. Returns backup path, nil if already absent.
    func remove() throws -> String? {
        switch state() {
        case .absent: return nil
        case .foreign(let why): throw FSError("\(path): \(why); pozostawiony bez zmian")
        case .ours, .legacy:
            try FileManager.default.createDirectory(atPath: backupDir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            return try SafeFiles.moveToBackup(path, backupDir: backupDir, label: "tailscaled-env.txt")
        }
    }
}
