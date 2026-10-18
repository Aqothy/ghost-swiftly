/// A terminal size in cells.
public struct Grid: Hashable, Sendable, CustomStringConvertible {
    public var columns: UInt16
    public var rows: UInt16

    public init(columns: UInt16, rows: UInt16) {
        self.columns = columns
        self.rows = rows
    }

    public var description: String { "\(columns)x\(rows)" }
}
