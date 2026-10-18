/// The outcome of restoring one history page of a snapshot.
public enum HistoryPage: Sendable, Hashable {
    /// The page's rows were prepended to scrollback.
    case restored(rows: Int)
    /// The page was valid but no longer fits the terminal, typically after a
    /// resize changed what it would attach to (ghostty `snapshot.h`,
    /// `ghostty_snapshot_decoder_next`). History is now incomplete; get a
    /// fresh snapshot to recover it.
    case dropped
    /// Every page has been restored.
    case finished
}
