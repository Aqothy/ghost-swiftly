import Foundation
import GhosttyVt

/// An incremental snapshot decode past READY: the decoder and the bytes it
/// borrows, which must outlive it (ghostty `snapshot.h`,
/// `ghostty_snapshot_decoder_new_buf`).
final class SnapshotRestore {
    private let bytes: UnsafeMutableRawBufferPointer
    private let decoder: OpaquePointer

    /// Decodes through READY and returns the restored terminal, which the
    /// caller owns. The decoder borrows it until ``next()`` finishes or this
    /// is released.
    init(snapshot: some ContiguousBytes) throws(GhosttyError) {
        let bytes = snapshot.withUnsafeBytes { source in
            let copy = UnsafeMutableRawBufferPointer.allocate(byteCount: max(source.count, 1), alignment: 1)
            copy.copyMemory(from: source)
            return UnsafeMutableRawBufferPointer(rebasing: copy[..<source.count])
        }
        var decoder: OpaquePointer?
        let result = ghostty_snapshot_decoder_new_buf(
            nil, &decoder, bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count)
        guard result == GHOSTTY_SUCCESS, let decoder else {
            bytes.deallocate()
            throw GhosttyError(result)
        }
        // The renderer draws no Kitty images (see Terminal.init); zero keeps
        // the restored terminal from storing them (ghostty snapshot.h,
        // GHOSTTY_SNAPSHOT_DECODER_OPT_KITTY_IMAGE_STORAGE_LIMIT).
        var noImages: UInt64 = 0
        let limit = ghostty_snapshot_decoder_set(
            decoder, GHOSTTY_SNAPSHOT_DECODER_OPT_KITTY_IMAGE_STORAGE_LIMIT, &noImages)
        guard limit == GHOSTTY_SUCCESS else {
            ghostty_snapshot_decoder_free(decoder)
            bytes.deallocate()
            throw GhosttyError(limit)
        }
        self.bytes = bytes
        self.decoder = decoder
    }

    deinit {
        ghostty_snapshot_decoder_free(decoder)
        bytes.deallocate()
    }

    func ready() throws(GhosttyError) -> OpaquePointer {
        var terminal: OpaquePointer?
        try check(ghostty_snapshot_decoder_ready(decoder, &terminal))
        guard let terminal else { throw .invalidValue }
        return terminal
    }

    /// Decodes up to and including the next history page. Kitty image
    /// records can arrive between pages; with storage off they are
    /// validated and dropped, so they're passed over.
    func next() throws(GhosttyError) -> HistoryPage {
        while true {
            let result = ghostty_snapshot_decoder_next(decoder)
            if result == GHOSTTY_NO_VALUE { return .finished }
            try check(result)
            var kind = GHOSTTY_SNAPSHOT_DECODER_PROGRESS_KIND_PAGE
            try check(ghostty_snapshot_decoder_get(decoder, GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_KIND, &kind))
            guard kind == GHOSTTY_SNAPSHOT_DECODER_PROGRESS_KIND_PAGE else { continue }
            var rows = 0
            try check(ghostty_snapshot_decoder_get(decoder, GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_ROWS, &rows))
            return rows == 0 ? .dropped : .restored(rows: rows)
        }
    }
}
