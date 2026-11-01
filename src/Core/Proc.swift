import Foundation

struct ProcResult: Equatable {
    var status: Int32
    var out: String
    var err: String
    var timedOut: Bool = false
    /// Output went past Proc.maxOutput and the rest was discarded; such a result is never a success.
    var truncated: Bool = false
    var ok: Bool { status == 0 && !timedOut && !truncated }
    var lines: [String] {
        out.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// One pipe(2) pair; both ends close-on-exec and owned (closed) by Proc.run.
private struct PipePair {
    let read: FileHandle
    let write: FileHandle

    /// nil when no descriptor is free. Foundation's `Pipe()` does not report that: it hands out
    /// fd 0 for both ends, so a child's output silently disappears and the run looks successful.
    static func make() -> PipePair? {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return nil }
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        return PipePair(read: FileHandle(fileDescriptor: fds[0], closeOnDealloc: false),
                        write: FileHandle(fileDescriptor: fds[1], closeOnDealloc: false))
    }

    func close() { try? read.close(); try? write.close() }
}

/// Runs a fixed absolute executable with arguments as an argv array (no shell),
/// a fixed minimal environment, cwd "/" and bounded output. After `timeout` the child gets SIGTERM,
/// then SIGKILL 2 s later, and run returns only once the child's exit is confirmed. That wait has no
/// upper bound: kill(2) only sends the signal, so a child that does not exit (e.g. stuck in the kernel)
/// blocks the caller, and with it the engine lock, the monitor and cleanup, until it does. In exchange
/// a command, such as a PF change, never outlives the call that started it, so the next step runs
/// only after the previous one has ended.
/// Every descriptor it opens is closed before it returns, except an output read end whose drain is
/// still blocked by a leftover grandchild; that drain closes its own end when the pipe reaches EOF.
enum Proc {
    static let safePath = "/usr/bin:/bin:/usr/sbin:/sbin"
    static let maxOutput = 1 << 20

    static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 15,
                    stdin: Data? = nil, extraEnv: [String: String] = [:]) -> ProcResult {
        guard exe.hasPrefix("/") else { return ProcResult(status: -1, out: "", err: "not absolute: \(exe)") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: "/")
        var env = ["PATH": safePath, "LANG": "C", "LC_ALL": "C"]
        for (k, v) in extraEnv { env[k] = v }
        p.environment = env
        guard let outPipe = PipePair.make() else { return pipeFailure(exe, errno) }
        guard let errPipe = PipePair.make() else { let e = errno; outPipe.close(); return pipeFailure(exe, e) }
        var inPipe: PipePair?
        if stdin != nil {
            guard let i = PipePair.make() else { let e = errno; outPipe.close(); errPipe.close(); return pipeFailure(exe, e) }
            inPipe = i
        }
        p.standardOutput = outPipe.write
        p.standardError = errPipe.write
        p.standardInput = inPipe?.read ?? FileHandle.nullDevice
        let lock = NSLock()
        let group = DispatchGroup()
        /// Reads until EOF with read(2) (no Objective-C exceptions), appending as it goes so a result
        /// returned early still holds what arrived; then closes its own read end.
        /// Blocking work runs on its own thread, not in the shared dispatch pool: callers that run on
        /// that pool and wait here could otherwise use up every pool thread and starve the reads.
        /// Past maxOutput it keeps reading (so the child is not blocked) but discards and flags the rest.
        func drain(_ h: FileHandle, into keyPath: ReferenceWritableKeyPath<Box, Data>,
                   cut: ReferenceWritableKeyPath<Box, Bool>, _ box: Box) {
            group.enter()
            Thread.detachNewThread {
                var buf = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let n = Darwin.read(h.fileDescriptor, &buf, buf.count)
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { break }
                    lock.lock()
                    let room = maxOutput - box[keyPath: keyPath].count
                    if room > 0 { box[keyPath: keyPath].append(contentsOf: buf[0..<min(n, room)]) }
                    if n > room { box[keyPath: cut] = true }
                    lock.unlock()
                }
                try? h.close()
                group.leave()
            }
        }
        // terminationHandler, not waitUntilExit: waitUntilExit spins a run loop on a pool thread and
        // stalled for good when several runs were made at once from dispatch queues.
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch {
            outPipe.close(); errPipe.close(); inPipe?.close()
            return ProcResult(status: -1, out: "", err: "cannot run \(exe): \(error.localizedDescription)")
        }
        // The child has its own copies now. Process does not close handles it was given, and the
        // parent's write ends must be closed or the reads below never see EOF.
        try? outPipe.write.close()
        try? errPipe.write.close()
        try? inPipe?.read.close()
        let box = Box()
        drain(outPipe.read, into: \.out, cut: \.outCut, box)
        drain(errPipe.read, into: \.err, cut: \.errCut, box)
        // stdin is written in the background so the timeout below still applies to a child that never
        // reads; EPIPE instead of SIGPIPE when the child exits early. The writer is non-blocking and
        // checks `box.stopWriting`, so it ends (and closes its end) before run returns, even when a leftover
        // process holds stdin open without reading.
        let writerDone = DispatchSemaphore(value: 0)
        if let stdin = stdin, let inPipe = inPipe {
            let fd = inPipe.write.fileDescriptor
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            Thread.detachNewThread {
                let bytes = [UInt8](stdin)
                var off = 0
                while off < bytes.count {
                    lock.lock(); let stop = box.stopWriting; lock.unlock()
                    if stop { break }
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let ready = poll(&pfd, 1, 50)
                    if ready < 0 && errno == EINTR { continue }
                    if ready < 0 { break }
                    if ready == 0 { continue }
                    let n = bytes[off...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                    if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                    if n <= 0 { break }
                    off += n
                }
                try? inPipe.write.close()
                writerDone.signal()
            }
        } else {
            writerDone.signal()
        }
        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            // Deliberately unbounded (see above): returning before the exit is confirmed would let a PF
            // change still in progress overlap a rollback or the next change.
            if done.wait(timeout: .now() + 2) == .timedOut { kill(p.processIdentifier, SIGKILL); done.wait() }
        }
        // The child is gone; input nobody read is dropped. Ends within one poll interval.
        lock.lock(); box.stopWriting = true; lock.unlock()
        writerDone.wait()
        // A leftover grandchild could hold the pipes open; never block forever on them. If it does,
        // the output may be incomplete, so the result must not count as a success.
        var note = ""
        if group.wait(timeout: .now() + 2) == .timedOut {
            timedOut = true
            note = "\noutput incomplete: a leftover process kept the output open"
        }
        lock.lock(); defer { lock.unlock() }
        for (cut, name) in [(box.outCut, "stdout"), (box.errCut, "stderr")] where cut {
            note += "\noutput truncated: \(name) exceeded the \(maxOutput)-byte limit; the rest was discarded"
        }
        return ProcResult(status: p.terminationStatus,
                          out: String(decoding: box.out, as: UTF8.self),
                          err: String(decoding: box.err, as: UTF8.self) + note,
                          timedOut: timedOut,
                          truncated: box.outCut || box.errCut)
    }

    /// Output collected by the drains, whether either was cut, and the stdin writer's stop flag;
    /// guarded by Proc.run's lock.
    private final class Box {
        var out = Data(), err = Data()
        var outCut = false, errCut = false
        var stopWriting = false
    }

    private static func pipeFailure(_ exe: String, _ code: Int32) -> ProcResult {
        ProcResult(status: -1, out: "", err: "cannot run \(exe): no pipe (\(String(cString: strerror(code))))")
    }
}
