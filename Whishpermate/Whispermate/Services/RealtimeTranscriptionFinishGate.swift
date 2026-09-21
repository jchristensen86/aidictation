import Foundation

/// Deterministic attempt policy for rebuilding a failed capture graph without
/// ending the user's recording. Its owner supplies serialization.
struct MacCaptureRecoveryPolicy {
    private(set) var attemptCount = 0
    private(set) var isRecovering = false

    mutating func begin(maximumAttempts: Int) -> Int? {
        guard !isRecovering, attemptCount < maximumAttempts else { return nil }
        isRecovering = true
        attemptCount += 1
        return attemptCount
    }

    mutating func finish() {
        isRecovering = false
    }

    mutating func noteHealthyBuffer() {
        attemptCount = 0
        isRecovering = false
    }

    func isExhausted(maximumAttempts: Int) -> Bool {
        !isRecovering && attemptCount >= maximumAttempts
    }
}

/// Buffers only an active recording's first PCM chunks while app context resolves.
/// Overflow disables streaming so recognition falls back to the complete file.
nonisolated final class MacRealtimeStartupAudio: @unchecked Sendable {
    typealias Handler = @Sendable (Data) -> Void

    private let lock = NSLock()
    private let maximumBytes: Int
    private var chunks: [Data] = []
    private var byteCount = 0
    private var handler: Handler?
    private var discarded = false

    // Two seconds of the recorder's 24 kHz, mono, Int16 streaming format.
    init(maximumBytes: Int = 96_000) {
        self.maximumBytes = maximumBytes
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !discarded else { return }
        if let handler {
            handler(chunk)
        } else if chunk.count <= maximumBytes - byteCount {
            chunks.append(chunk)
            byteCount += chunk.count
        } else {
            discarded = true
            chunks.removeAll()
            byteCount = 0
        }
    }

    /// The destination must enqueue without blocking or reentering this buffer.
    /// Holding the lock through replay keeps new chunks behind the saved head.
    func connect(to handler: @escaping Handler) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !discarded, self.handler == nil else { return false }
        self.handler = handler
        for chunk in chunks { handler(chunk) }
        chunks.removeAll()
        byteCount = 0
        return true
    }

    func discardPending() {
        lock.lock()
        defer { lock.unlock() }
        guard handler == nil else { return }
        discarded = true
        chunks.removeAll()
        byteCount = 0
    }
}
