import Foundation

/// A QR code, made here so the pairing link can be shown in a terminal for
/// a phone to scan. Bytes only, the lowest error correction, up to about
/// 850 characters, which is several pairing links' worth.
public struct QRCode {
    public let size: Int
    /// True where a module is dark, row by row.
    public let modules: [[Bool]]

    // Per version, at error correction level L: correction codewords per
    // block, then how many blocks of each length of data.
    private static let layouts: [(ec: Int, blocks: [(count: Int, data: Int)])] = [
        (7, [(1, 19)]), (10, [(1, 34)]), (15, [(1, 55)]), (20, [(1, 80)]), (26, [(1, 108)]),
        (18, [(2, 68)]), (20, [(2, 78)]), (24, [(2, 97)]), (30, [(2, 116)]), (18, [(2, 68), (2, 69)]),
        (20, [(4, 81)]), (24, [(2, 92), (2, 93)]), (26, [(4, 107)]), (30, [(3, 115), (1, 116)]), (22, [(5, 87), (1, 88)]),
        (24, [(5, 98), (1, 99)]), (28, [(1, 107), (5, 108)]), (30, [(5, 120), (1, 121)]), (28, [(3, 113), (4, 114)]), (28, [(3, 107), (5, 108)]),
    ]
    private static let alignments: [[Int]] = [
        [], [6, 18], [6, 22], [6, 26], [6, 30], [6, 34], [6, 22, 38], [6, 24, 42], [6, 26, 46], [6, 28, 50],
        [6, 30, 54], [6, 32, 58], [6, 34, 62], [6, 26, 46, 66], [6, 26, 48, 70], [6, 26, 50, 74], [6, 30, 54, 78],
        [6, 30, 56, 82], [6, 30, 58, 86], [6, 34, 62, 90],
    ]

    /// Nil when the text is too long to fit.
    public init?(_ text: String) {
        let bytes = Array(text.utf8)
        var chosen: Int?
        for version in 1...Self.layouts.count {
            let capacity = Self.layouts[version - 1].blocks.reduce(0) { $0 + $1.count * $1.data }
            let header = 4 + (version < 10 ? 8 : 16)
            if bytes.count * 8 + header <= capacity * 8 { chosen = version; break }
        }
        guard let version = chosen else { return nil }
        let layout = Self.layouts[version - 1]
        let capacity = layout.blocks.reduce(0) { $0 + $1.count * $1.data }

        // The message: "bytes" mode, the length, the bytes, then padding.
        var bits: [Bool] = []
        func append(_ value: Int, _ count: Int) {
            for shift in stride(from: count - 1, through: 0, by: -1) { bits.append((value >> shift) & 1 == 1) }
        }
        append(0b0100, 4)
        append(bytes.count, version < 10 ? 8 : 16)
        for byte in bytes { append(Int(byte), 8) }
        append(0, min(4, capacity * 8 - bits.count))
        while bits.count % 8 != 0 { bits.append(false) }
        var data = stride(from: 0, to: bits.count, by: 8).map { start in
            (0..<8).reduce(UInt8(0)) { $0 << 1 | (bits[start + $1] ? 1 : 0) }
        }
        var pad: UInt8 = 0xEC
        while data.count < capacity { data.append(pad); pad = pad == 0xEC ? 0x11 : 0xEC }

        // Split into blocks, each with its own correction codewords, then
        // deal them out a byte at a time.
        var dataBlocks: [[UInt8]] = [], ecBlocks: [[UInt8]] = []
        var offset = 0
        let generator = Self.generator(degree: layout.ec)
        for group in layout.blocks {
            for _ in 0..<group.count {
                let block = Array(data[offset..<offset + group.data])
                offset += group.data
                dataBlocks.append(block)
                ecBlocks.append(Self.remainder(block, generator))
            }
        }
        var stream: [UInt8] = []
        for index in 0..<(dataBlocks.map(\.count).max() ?? 0) {
            for block in dataBlocks where index < block.count { stream.append(block[index]) }
        }
        for index in 0..<layout.ec {
            for block in ecBlocks { stream.append(block[index]) }
        }

        let size = version * 4 + 17
        var modules = Array(repeating: Array(repeating: false, count: size), count: size)
        var reserved = modules
        func set(_ x: Int, _ y: Int, _ dark: Bool) {
            modules[y][x] = dark
            reserved[y][x] = true
        }

        // Timing lines, the three corner squares, the small squares.
        for i in 0..<size {
            set(6, i, i % 2 == 0)
            set(i, 6, i % 2 == 0)
        }
        for (cx, cy) in [(3, 3), (size - 4, 3), (3, size - 4)] {
            for dy in -4...4 {
                for dx in -4...4 {
                    let x = cx + dx, y = cy + dy
                    guard x >= 0, x < size, y >= 0, y < size else { continue }
                    let ring = max(abs(dx), abs(dy))
                    set(x, y, ring != 2 && ring != 4)
                }
            }
        }
        let centers = Self.alignments[version - 1]
        for (i, cy) in centers.enumerated() {
            for (j, cx) in centers.enumerated() {
                // Not on top of the corner squares.
                if (i == 0 && j == 0) || (i == 0 && j == centers.count - 1) || (i == centers.count - 1 && j == 0) { continue }
                for dy in -2...2 {
                    for dx in -2...2 { set(cx + dx, cy + dy, max(abs(dx), abs(dy)) != 1) }
                }
            }
        }

        // Which mask and correction level this is, written twice.
        let mask = 0
        let formatData = 0b01 << 3 | mask
        var rem = formatData
        for _ in 0..<10 { rem = (rem << 1) ^ ((rem >> 9) * 0x537) }
        let format = (formatData << 10 | rem) ^ 0x5412
        func formatBit(_ i: Int) -> Bool { (format >> i) & 1 == 1 }
        for i in 0...5 { set(8, i, formatBit(i)) }
        set(8, 7, formatBit(6))
        set(8, 8, formatBit(7))
        set(7, 8, formatBit(8))
        for i in 9..<15 { set(14 - i, 8, formatBit(i)) }
        for i in 0..<8 { set(size - 1 - i, 8, formatBit(i)) }
        for i in 8..<15 { set(8, size - 15 + i, formatBit(i)) }
        set(8, size - 8, true)

        // Bigger codes say their version too.
        if version >= 7 {
            var rem = version
            for _ in 0..<12 { rem = (rem << 1) ^ ((rem >> 11) * 0x1F25) }
            let info = version << 12 | rem
            for i in 0..<18 {
                let dark = (info >> i) & 1 == 1
                let a = size - 11 + i % 3, b = i / 3
                set(a, b, dark)
                set(b, a, dark)
            }
        }

        // The data, zigzagging up and down in pairs of columns from the
        // right, flipped by the mask so it doesn't make large plain areas.
        var index = 0
        var right = size - 1
        while right >= 1 {
            if right == 6 { right = 5 }
            for vertical in 0..<size {
                for j in 0..<2 {
                    let x = right - j
                    let upward = (right + 1) & 2 == 0
                    let y = upward ? size - 1 - vertical : vertical
                    guard !reserved[y][x] else { continue }
                    var dark = false
                    if index < stream.count * 8 {
                        dark = (stream[index >> 3] >> (7 - UInt8(index & 7))) & 1 == 1
                    }
                    index += 1
                    if (x + y) % 2 == 0 { dark.toggle() }
                    modules[y][x] = dark
                }
            }
            right -= 2
        }
        self.size = size
        self.modules = modules
    }

    // MARK: Error correction (Reed-Solomon over GF(256))

    private static func multiply(_ x: UInt8, _ y: UInt8) -> UInt8 {
        var z = 0
        for i in stride(from: 7, through: 0, by: -1) {
            z = (z << 1) ^ ((z >> 7) * 0x11D)
            z ^= ((Int(y) >> i) & 1) * Int(x)
        }
        return UInt8(z & 0xFF)
    }

    private static func generator(degree: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: degree)
        result[degree - 1] = 1
        var root: UInt8 = 1
        for _ in 0..<degree {
            for j in 0..<degree {
                result[j] = multiply(result[j], root)
                if j + 1 < degree { result[j] ^= result[j + 1] }
            }
            root = multiply(root, 2)
        }
        return result
    }

    private static func remainder(_ data: [UInt8], _ generator: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: generator.count)
        for byte in data {
            let factor = byte ^ result.removeFirst()
            result.append(0)
            for (i, coefficient) in generator.enumerated() { result[i] ^= multiply(coefficient, factor) }
        }
        return result
    }

    // MARK: Drawing

    /// The code as lines of text, two rows of modules per line, dark on
    /// light whatever the terminal's colors are.
    public func terminalLines(margin: Int = 3) -> [String] {
        func dark(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && y >= 0 && x < size && y < size && modules[y][x]
        }
        var lines: [String] = []
        var y = -margin
        while y < size + margin {
            var line = "\u{1B}[38;5;16;48;5;231m"
            for x in -margin..<(size + margin) {
                switch (dark(x, y), dark(x, y + 1)) {
                case (true, true): line += "█"
                case (true, false): line += "▀"
                case (false, true): line += "▄"
                case (false, false): line += " "
                }
            }
            lines.append(line + "\u{1B}[0m")
            y += 2
        }
        return lines
    }
}
