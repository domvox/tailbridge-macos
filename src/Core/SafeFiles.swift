import Foundation

struct FSError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

enum FileKind: Equatable { case absent, regular, directory, symlink, other }

struct FileInfo {
    var kind: FileKind
    var uid: uid_t = 0
    var mode: mode_t = 0
}

/// Symlink-refusing, exclusive-create, atomic-replace file helpers.
enum SafeFiles {
    static func info(_ path: String) -> FileInfo {
        var st = stat()
        guard lstat(path, &st) == 0 else { return FileInfo(kind: .absent) }
        let kind: FileKind
        switch st.st_mode & S_IFMT {
        case S_IFREG: kind = .regular
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symlink
        default: kind = .other
        }
        return FileInfo(kind: kind, uid: st.st_uid, mode: st.st_mode & 0o7777)
    }

    /// Reads a small regular file without following symlinks. nil if absent.
    static func read(_ path: String, max: Int = 64 * 1024) throws -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw FSError("nie można otworzyć \(path): \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { throw FSError("\(path) nie jest zwykłym plikiem") }
        guard st.st_size <= max else { throw FSError("\(path) jest za duży") }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n < 0 { throw FSError("błąd odczytu \(path)") }
            if n == 0 { break }
            data.append(contentsOf: buf[0..<n])
            if data.count > max { throw FSError("\(path) jest za duży") }
        }
        guard let s = String(data: data, encoding: .utf8) else { throw FSError("\(path) nie jest UTF-8") }
        return s
    }

    private static func writeAll(_ fd: Int32, _ content: String, _ path: String) throws {
        let bytes = Array(content.utf8)
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { throw FSError("błąd zapisu \(path)") }
            off += n
        }
        guard fsync(fd) == 0 else { throw FSError("fsync \(path) nie powiódł się") }
    }

    /// Creates a new file; fails if anything (including a symlink) already exists at path.
    static func createExclusive(_ path: String, _ content: String, mode: mode_t) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw FSError("nie można utworzyć \(path): \(String(cString: strerror(errno)))") }
        do {
            try writeAll(fd, content, path)
            guard fchmod(fd, mode) == 0 else { throw FSError("chmod \(path) nie powiódł się") }
            close(fd)
        } catch {
            close(fd); unlink(path); throw error
        }
    }

    /// Writes a temp file in the same directory, then rename(2)s it over path.
    /// Refuses to replace anything that is not a regular file.
    static func replaceAtomic(_ path: String, _ content: String, mode: mode_t) throws {
        let k = info(path).kind
        guard k == .absent || k == .regular else { throw FSError("\(path) nie jest zwykłym plikiem; odmowa nadpisania") }
        let tmp = path + ".tmp-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        try createExclusive(tmp, content, mode: mode)
        guard rename(tmp, path) == 0 else { unlink(tmp); throw FSError("rename \(path) nie powiódł się") }
    }

    /// True if the path itself (not a symlink target) carries any extended ACL entry, or if that
    /// cannot be determined. macOS reports "no ACL" as NULL with ENOENT (checked on 27.2);
    /// any other failure is treated as untrusted. System directories used here carry none.
    static func hasACL(_ path: String) -> Bool {
        errno = 0
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return errno != ENOENT }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        return acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) == 0
    }

    /// nil if `path` and every component from `base` down are real directories owned by
    /// `owner` (or root), not writable by group/other and without ACLs. Otherwise a reason.
    static func untrustedDirReason(_ path: String, owner: uid_t, base: String = "/") -> String? {
        guard path.hasPrefix(base) else { return "\(path) poza \(base)" }
        var comps: [String] = [base]
        var cur = base
        for c in path.dropFirst(base.count).split(separator: "/") {
            cur = (cur.hasSuffix("/") ? cur : cur + "/") + c
            comps.append(cur)
        }
        for d in comps {
            let i = info(d)
            if i.kind != .directory { return "\(d) nie jest katalogiem (lub jest symlinkiem)" }
            if i.uid != owner && i.uid != 0 { return "\(d) ma nieoczekiwanego właściciela \(i.uid)" }
            if i.mode & 0o022 != 0 { return "\(d) jest zapisywalny dla grupy/innych" }
            if hasACL(d) { return "\(d) ma wpisy ACL" }
        }
        return nil
    }

    static func timestamp(_ d: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: d)
    }

    /// Moves a regular file or directory into backupDir under a unique name. Returns the new path.
    static func moveToBackup(_ path: String, backupDir: String, label: String) throws -> String {
        let k = info(path).kind
        guard k == .regular || k == .directory else { throw FSError("\(path): odmowa przeniesienia (typ \(k))") }
        let dest = "\(backupDir)/\(timestamp())-\(UInt16.random(in: 0...UInt16.max))-\(label)"
        guard info(dest).kind == .absent else { throw FSError("kolizja kopii \(dest)") }
        if rename(path, dest) == 0 { return dest }
        let e = errno
        guard e == EXDEV, k == .regular, let content = try read(path) else {
            throw FSError("nie można przenieść \(path): \(String(cString: strerror(e)))")
        }
        try createExclusive(dest, content, mode: 0o600)
        guard try read(dest) == content, unlink(path) == 0 else { throw FSError("kopia \(path) niepełna; oryginał zostawiony") }
        return dest
    }

    static func ensureDir(_ path: String, mode: mode_t) throws {
        switch info(path).kind {
        case .directory: return
        case .absent:
            guard mkdir(path, mode) == 0 || info(path).kind == .directory else { throw FSError("mkdir \(path) nie powiódł się") }
            chmod(path, mode)
        default: throw FSError("\(path) istnieje i nie jest katalogiem")
        }
    }
}
