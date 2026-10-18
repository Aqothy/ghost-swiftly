import GhosttyVt

extension String {
    /// Copies a borrowed libghostty-vt string, repairing invalid UTF-8.
    init(ghostty value: GhosttyString) {
        guard let pointer = value.ptr, value.len > 0 else {
            self = ""
            return
        }
        self = String(decoding: UnsafeBufferPointer(start: pointer, count: value.len), as: UTF8.self)
    }
}
