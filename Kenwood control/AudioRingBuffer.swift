import Foundation
import os

/// A simple thread-safe ring buffer for mono Float samples.
/// This is good enough for MVP audio monitoring; if we hit glitches, we can replace it with a lock-free buffer.
final class AudioRingBuffer {
    private var storage: [Float]
    private var readIndex: Int = 0
    private var writeIndex: Int = 0
    private var count: Int = 0
    private var lock = os_unfair_lock_s()

    init(capacitySamples: Int) {
        storage = Array(repeating: 0, count: max(1, capacitySamples))
    }

    var capacity: Int { storage.count }

    func availableToRead() -> Int {
        os_unfair_lock_lock(&lock)
        let v = count
        os_unfair_lock_unlock(&lock)
        return v
    }

    func clear() {
        os_unfair_lock_lock(&lock)
        readIndex = 0
        writeIndex = 0
        count = 0
        os_unfair_lock_unlock(&lock)
    }

    /// Writes as many samples as possible. Returns the number written.
    func write(from ptr: UnsafePointer<Float>, count n: Int) -> Int {
        guard n > 0 else { return 0 }
        os_unfair_lock_lock(&lock)
        let space = storage.count - count
        let toWrite = min(space, n)
        guard toWrite > 0 else {
            os_unfair_lock_unlock(&lock)
            return 0
        }

        let first = min(toWrite, storage.count - writeIndex)
        storage.withUnsafeMutableBufferPointer { buf in
            buf.baseAddress!.advanced(by: writeIndex).update(from: ptr, count: first)
            if first < toWrite {
                buf.baseAddress!.update(from: ptr.advanced(by: first), count: toWrite - first)
            }
        }

        writeIndex = (writeIndex + toWrite) % storage.count
        count += toWrite
        os_unfair_lock_unlock(&lock)
        return toWrite
    }

    /// Reads as many samples as possible. Returns the number read.
    func read(into ptr: UnsafeMutablePointer<Float>, count n: Int) -> Int {
        guard n > 0 else { return 0 }
        os_unfair_lock_lock(&lock)
        let toRead = min(count, n)
        guard toRead > 0 else {
            os_unfair_lock_unlock(&lock)
            return 0
        }

        let first = min(toRead, storage.count - readIndex)
        storage.withUnsafeBufferPointer { buf in
            ptr.update(from: buf.baseAddress!.advanced(by: readIndex), count: first)
            if first < toRead {
                ptr.advanced(by: first).update(from: buf.baseAddress!, count: toRead - first)
            }
        }

        readIndex = (readIndex + toRead) % storage.count
        count -= toRead
        os_unfair_lock_unlock(&lock)
        return toRead
    }
}
