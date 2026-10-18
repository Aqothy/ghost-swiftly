import GhosttyVt

/// Compile-time facts about the linked libghostty-vt.
public enum BuildInfo {
    /// The Ghostty commit the library was built from, stamped by
    /// Script/build-xcframework.sh. Snapshots are only compatible between
    /// libraries built from the same commit (ghostty snapshot.h: "format
    /// version 1 ... does not yet carry a binary-compatibility guarantee").
    public static let commit: String = {
        var value = GhosttyString()
        guard ghostty_build_info(GHOSTTY_BUILD_INFO_VERSION_BUILD, &value) == GHOSTTY_SUCCESS else {
            return ""
        }
        return String(ghostty: value)
    }()
}
