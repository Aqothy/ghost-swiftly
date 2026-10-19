import GhosttyVt

/// One mouse event in surface pixels.
public struct MouseEvent: Sendable, Hashable {
    public enum Action: Sendable, Hashable {
        case press
        case release
        case motion
    }

    public enum Button: Sendable, Hashable {
        case left
        case right
        case middle
        /// Wheel up.
        case four
        /// Wheel down.
        case five
        /// Wheel left.
        case six
        /// Wheel right.
        case seven
        /// Back.
        case eight
        /// Forward.
        case nine
        case ten
        case eleven

        var ghostty: GhosttyMouseButton {
            switch self {
            case .left: GHOSTTY_MOUSE_BUTTON_LEFT
            case .right: GHOSTTY_MOUSE_BUTTON_RIGHT
            case .middle: GHOSTTY_MOUSE_BUTTON_MIDDLE
            case .four: GHOSTTY_MOUSE_BUTTON_FOUR
            case .five: GHOSTTY_MOUSE_BUTTON_FIVE
            case .six: GHOSTTY_MOUSE_BUTTON_SIX
            case .seven: GHOSTTY_MOUSE_BUTTON_SEVEN
            case .eight: GHOSTTY_MOUSE_BUTTON_EIGHT
            case .nine: GHOSTTY_MOUSE_BUTTON_NINE
            case .ten: GHOSTTY_MOUSE_BUTTON_TEN
            case .eleven: GHOSTTY_MOUSE_BUTTON_ELEVEN
            }
        }
    }

    public var action: Action
    /// The button pressed or released; for motion, the button held, if any.
    public var button: Button?
    public var modifiers: Modifiers
    /// Position in surface pixels from the top-left of the grid's surface.
    public var x: Double
    public var y: Double

    public init(action: Action, button: Button?, modifiers: Modifiers = [], x: Double, y: Double) {
        self.action = action
        self.button = button
        self.modifiers = modifiers
        self.x = x
        self.y = y
    }
}

/// The geometry the mouse encoder maps surface pixels to cells with.
public struct MouseGeometry: Sendable, Hashable {
    public var screenWidth: UInt32
    public var screenHeight: UInt32
    public var cellWidth: UInt32
    public var cellHeight: UInt32
    public var paddingTop: UInt32
    public var paddingBottom: UInt32
    public var paddingLeft: UInt32
    public var paddingRight: UInt32

    public init(
        screenWidth: UInt32, screenHeight: UInt32, cellWidth: UInt32, cellHeight: UInt32,
        paddingTop: UInt32 = 0, paddingBottom: UInt32 = 0, paddingLeft: UInt32 = 0, paddingRight: UInt32 = 0
    ) {
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.paddingTop = paddingTop
        self.paddingBottom = paddingBottom
        self.paddingLeft = paddingLeft
        self.paddingRight = paddingRight
    }
}
