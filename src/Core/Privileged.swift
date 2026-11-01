import Foundation

/// Builds the only shell commands ever passed to the macOS administrator prompt.
/// Every variable part is validated and single-quoted.
enum Privileged {
    static let label = "com.tailbridge.helper"
    static let helperPath = "/Library/PrivilegedHelperTools/com.tailbridge.helper"
    static let plistPath = "/Library/LaunchDaemons/com.tailbridge.helper.plist"
    static let base = "/Library/Application Support/TailBridge"

    static func shQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func enableCommand(_ id: Identity) -> String? {
        guard id.fieldsValid else { return nil }
        return [helperPath, "enable", "--iface", id.iface, "--ip4", id.ip4, "--ip6", id.ip6, "--domain", id.domain]
            .map(shQuote).joined(separator: " ")
    }

    static var disableCommand: String { [helperPath, "disable"].map(shQuote).joined(separator: " ") }
    static var uninstallCommand: String { [helperPath, "uninstall"].map(shQuote).joined(separator: " ") }

    /// Shell functions. `chk DIR`: a real directory (not a symlink), owned by root, not writable
    /// by group/other, without ACL entries. `chkf FILE`: the same for a regular file. Otherwise abort.
    static let dirCheckFunction =
        "ok_owner() { [ -z \"$(/usr/bin/find \"$1\" -maxdepth 0 \\( ! -user root -o -perm +022 \\))\" ] "
        + "&& [ \"$(/bin/ls -lde \"$1\" | /usr/bin/wc -l | /usr/bin/tr -d ' ')\" = 1 ]; }; "
        + "chk() { [ -d \"$1\" ] && [ ! -L \"$1\" ] && ok_owner \"$1\" || { echo \"niebezpieczny katalog: $1\" >&2; exit 1; }; }; "
        + "chkf() { [ -f \"$1\" ] && [ ! -L \"$1\" ] && ok_owner \"$1\" || { echo \"niezaufany plik: $1 — usuń go ręcznie po sprawdzeniu\" >&2; exit 1; }; }"

    /// Verifies every parent directory and any existing helper, copies the bundled helper into a
    /// root-only temp file, checks its SHA-256 there, installs it atomically and runs only the
    /// protected copy. A trusted previous helper is kept aside and restored if the new one fails.
    static func installCommand(source: String, sha256: String) -> String? {
        guard source.hasPrefix("/"), !source.contains("\n"), !source.contains("\0"),
              Validate.full(sha256, "[0-9a-f]{64}") else { return nil }
        let d = "/Library/PrivilegedHelperTools"
        let dst = shQuote(helperPath)
        let prev = shQuote(d + "/.com.tailbridge.helper.previous")
        return [
            "set -eu",
            "umask 077",
            dirCheckFunction,
            "chk /", "chk /Library",
            "[ -e \(d) ] || [ -L \(d) ] || /bin/mkdir -m 755 \(d)",
            "chk \(d)",
            "if [ -e \(dst) ] || [ -L \(dst) ]; then chkf \(dst); fi",
            "T=$(/usr/bin/mktemp \(d)/.tailbridge.XXXXXX)",
            "trap '/bin/rm -f \"$T\"' EXIT",
            "/bin/cat \(shQuote(source)) > \"$T\"",
            "HASH=$(/usr/bin/shasum -a 256 \"$T\" | /usr/bin/cut -c1-64)",
            "[ \"$HASH\" = \(shQuote(sha256)) ] || { echo 'SHA-256 niezgodny; przerwano' >&2; exit 1; }",
            "/usr/sbin/chown root:wheel \"$T\"",
            "/bin/chmod 755 \"$T\"",
            "/bin/rm -f \(prev)",
            "if [ -e \(dst) ]; then /bin/mv -f \(dst) \(prev); fi",
            "/bin/mv -f \"$T\" \(dst)",
            "trap - EXIT",
            "if \(dst) install-daemon; then /bin/rm -f \(prev); exit 0; fi",
            "echo 'Nowy pomocnik nie uruchomił monitora.' >&2",
            "if [ -f \(prev) ]; then /bin/mv -f \(prev) \(dst); if \(dst) install-daemon; then echo 'Przywrócono poprzednią wersję; jej monitor działa.' >&2; "
                + "else echo 'Przywrócono plik poprzedniej wersji, ale jej monitor NIE działa.' >&2; fi; "
                + "else /bin/rm -f \(dst); echo 'Pierwsza instalacja wycofana: usunięto nową binarkę.' >&2; fi",
            "exit 1",
        ].joined(separator: "; ")
    }

    /// Runs the command in a subshell with stderr merged, always returning its output and an
    /// explicit exit-status line (do shell script would otherwise drop stdout on failure).
    static func appleScript(command: String, prompt: String) -> String {
        let wrapped = "( \(command) ) 2>&1; echo \"TAILBRIDGE_EXIT=$?\""
        return "do shell script \(appleScriptString(wrapped)) with prompt \(appleScriptString(prompt)) "
            + "with administrator privileges without altering line endings"
    }

    /// Exit status from the last `TAILBRIDGE_EXIT=` line, or nil if absent.
    static func exitStatus(_ output: String) -> Int32? {
        guard let line = output.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("TAILBRIDGE_EXIT=") }) else { return nil }
        return Int32(line.dropFirst("TAILBRIDGE_EXIT=".count))
    }

    /// Final line and exit status of an otherwise completed uninstall. Unrecognized items teardown left
    /// untouched (e.g. a resolver someone edited) are named, and the status is 2 (partial), as for disable.
    static func uninstallSummary(leftovers: [String], backups: String) -> (status: Int32, line: String) {
        let done = "ODINSTALOWANO. Kopie zapasowe pozostają w \(backups)."
        guard !leftovers.isEmpty else { return (0, done) }
        return (2, done + " POZOSTAWIONO nierozpoznane elementy (nie usunięto; monitor już ich nie pilnuje): "
                   + leftovers.joined(separator: "; "))
    }

    static func sha256Hex(_ path: String) -> String? {
        let r = Proc.run("/usr/bin/shasum", ["-a", "256", path], timeout: 20)
        guard r.ok else { return nil }
        let h = String(r.out.prefix(64))
        return Validate.full(h, "[0-9a-f]{64}") ? h : nil
    }

    static func launchdPlist(helper: String = helperPath) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>Label</key>
        \t<string>\(label)</string>
        \t<key>ProgramArguments</key>
        \t<array>
        \t\t<string>\(helper)</string>
        \t\t<string>watch</string>
        \t</array>
        \t<key>RunAtLoad</key>
        \t<true/>
        \t<key>KeepAlive</key>
        \t<true/>
        \t<key>WorkingDirectory</key>
        \t<string>/</string>
        \t<key>StandardErrorPath</key>
        \t<string>/Library/Logs/TailBridge-helper.log</string>
        \t<key>StandardOutPath</key>
        \t<string>/Library/Logs/TailBridge-helper.log</string>
        </dict>
        </plist>

        """
    }
}
