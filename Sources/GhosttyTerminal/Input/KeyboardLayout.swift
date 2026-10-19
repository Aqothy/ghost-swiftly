// Ported from ghostty src/input/keyboard.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.

#if os(macOS)
import Carbon
#endif
import GhosttyVT

/// The current keyboard layout, for Ghostty's option-as-alt default.
enum KeyboardLayout {
    /// The input source id, e.g. `com.apple.keylayout.US`; nil off macOS.
    static var id: String? {
        #if os(macOS)
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        else { return nil }
        return Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String
        #else
        return nil
        #endif
    }

    /// Ghostty's `detectOptionAsAlt`: Alt on the US layouts, else Option
    /// composes characters.
    static var optionAsAlt: OptionAsAlt {
        switch id {
        case "com.apple.keylayout.US", "com.apple.keylayout.USInternational": .both
        default: .none
        }
    }
}
