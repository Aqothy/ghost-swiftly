// Ported from ghostty src/font/Atlas.zig @ 81598385d608dda4946093d6d6a234d204a2f225
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.
//
// A texture atlas: skyline bin packing ("A Thousand Ways to Pack the Bin",
// Jukka Jylänki, via freetype-gl). Square, packed rows, a 1px border.
// Confined to the renderer's thread, so the modified counter is a plain
// integer rather than an atomic.

/// Glyph bitmaps packed into one square texture.
final class Atlas {
    enum Format {
        /// 1 byte per pixel.
        case grayscale
        /// 4 bytes per pixel, BGRA premultiplied.
        case bgra

        var depth: Int {
            switch self {
            case .grayscale: 1
            case .bgra: 4
            }
        }
    }

    struct Region: Equatable {
        var x: UInt32
        var y: UInt32
        var width: UInt32
        var height: UInt32
    }

    struct Full: Error {}

    private struct Node {
        var x: UInt32
        var y: UInt32
        var width: UInt32
    }

    private(set) var data: [UInt8]
    /// Width and height.
    private(set) var size: UInt32
    let format: Format
    /// Incremented on every write, so the GPU copy knows when to re-upload.
    private(set) var modified = 0
    private var nodes: [Node] = []

    init(size: UInt32, format: Format) {
        self.size = size
        self.format = format
        data = [UInt8](repeating: 0, count: Int(size) * Int(size) * format.depth)
        // A 1px border avoids sampling artifacts.
        nodes = [Node(x: 1, y: 1, width: size - 2)]
    }

    /// Reserves a region; throws ``Full`` when the atlas must grow first.
    func reserve(width: UInt32, height: UInt32) throws(Full) -> Region {
        var region = Region(x: 0, y: 0, width: width, height: height)
        // Empty regions are returned as is; this simplifies callers writing
        // empty data.
        if width == 0, height == 0 { return region }

        var bestHeight = UInt32.max
        var bestWidth = UInt32.max
        var chosen: Int?
        for index in nodes.indices {
            guard let y = fit(index, width: width, height: height) else { continue }
            let node = nodes[index]
            if y + height < bestHeight || (y + height == bestHeight && node.width > 0 && node.width < bestWidth) {
                chosen = index
                bestWidth = node.width
                bestHeight = y + height
                region.x = node.x
                region.y = y
            }
        }
        guard let bestIndex = chosen else { throw Full() }

        nodes.insert(Node(x: region.x, y: region.y + height, width: width), at: bestIndex)

        // Shrink the nodes the new one overlaps.
        let index = bestIndex + 1
        while index < nodes.count {
            let previous = nodes[index - 1]
            if nodes[index].x < previous.x + previous.width {
                let shrink = previous.x + previous.width - nodes[index].x
                nodes[index].x += shrink
                nodes[index].width = nodes[index].width > shrink ? nodes[index].width - shrink : 0
                if nodes[index].width == 0 {
                    nodes.remove(at: index)
                    continue
                }
            }
            break
        }
        merge()
        return region
    }

    /// The y at which a width × height rectangle fits at the node, if it does.
    private func fit(_ index: Int, width: UInt32, height: UInt32) -> UInt32? {
        let node = nodes[index]
        if node.x + width > size - 1 { return nil }
        var y = node.y
        var i = index
        var widthLeft = width
        while widthLeft > 0 {
            guard i < nodes.count else { return nil }
            let n = nodes[i]
            if n.y > y { y = n.y }
            if y + height > size - 1 { return nil }
            widthLeft = widthLeft > n.width ? widthLeft - n.width : 0
            i += 1
        }
        return y
    }

    /// Merges adjacent nodes at the same y.
    private func merge() {
        var index = 0
        while index < nodes.count - 1 {
            if nodes[index].y == nodes[index + 1].y {
                nodes[index].width += nodes[index + 1].width
                nodes.remove(at: index + 1)
                continue
            }
            index += 1
        }
    }

    /// Writes packed pixel rows into a reserved region.
    func set(_ region: Region, _ pixels: UnsafeRawBufferPointer) {
        let depth = format.depth
        let rowBytes = Int(region.width) * depth
        data.withUnsafeMutableBytes { texture in
            for row in 0..<Int(region.height) {
                let textureOffset = ((Int(region.y) + row) * Int(size) + Int(region.x)) * depth
                let sourceOffset = row * rowBytes
                texture.baseAddress!.advanced(by: textureOffset)
                    .copyMemory(from: pixels.baseAddress!.advanced(by: sourceOffset), byteCount: rowBytes)
            }
        }
        modified += 1
    }

    /// Grows the texture, keeping everything already written.
    func grow(to newSize: UInt32) {
        precondition(newSize >= size)
        guard newSize != size else { return }
        let oldData = data
        let oldSize = size
        data = [UInt8](repeating: 0, count: Int(newSize) * Int(newSize) * format.depth)
        size = newSize
        // Copy full rows except the border rows; the side borders come along
        // so no stride is needed.
        oldData.withUnsafeBytes { old in
            set(
                Region(x: 0, y: 1, width: oldSize, height: oldSize - 2),
                UnsafeRawBufferPointer(rebasing: old[(Int(oldSize) * format.depth)...]))
        }
        // The new space on the right.
        nodes.append(Node(x: oldSize - 1, y: 1, width: newSize - oldSize))
        modified += 1
    }
}
