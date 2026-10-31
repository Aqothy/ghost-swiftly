/// Facts about the linked libghostty-vt.
public enum BuildInfo {
    /// The Ghostty commit the library was built from: Package.swift's binary
    /// target, which Script/bump-ghostty.sh sets with it. Ghostty's CI build
    /// doesn't record its commit in the library's build info. Snapshots are
    /// only compatible between libraries built from the same commit (ghostty
    /// snapshot.h: "format version 1 ... does not yet carry a
    /// binary-compatibility guarantee").
    public static let commit = "f54340ad77814fe319d136e5e915d6a48de8dd23"
}
