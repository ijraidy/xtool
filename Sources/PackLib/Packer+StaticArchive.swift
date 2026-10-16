import Foundation

// Detects static libraries that SwiftPM binary targets ship as `.framework` bundles.
//
// A static framework is linked into the executable at build time, so it must not be
// copied into the app's Frameworks/ folder: codesigning such a bundle fails with
// "Invalid arch file in fat mach-o file!". Binary targets ship the library either as a
// plain ar archive, or as a universal (fat) Mach-O whose slices are each an ar archive
// (ONNX Runtime does the latter).
extension Packer {
    // https://github.com/apple/llvm-project/blob/e716ff14c46490d2da6b240806c04e2beef01f40/llvm/include/llvm/Object/Archive.h#L33
    private static let archiveMagics = [Data("!<arch>\n".utf8), Data("!<thin>\n".utf8)]

    // <mach-o/fat.h>: FAT_MAGIC and FAT_MAGIC_64, stored big-endian on disk.
    private static let fatMagic: UInt32 = 0xCAFEBABE
    private static let fatMagic64: UInt32 = 0xCAFEBABF
    // sizeof(struct fat_arch) and sizeof(struct fat_arch_64).
    private static let fatArchSize = 20
    private static let fatArch64Size = 32
    // Java class files share FAT_MAGIC, with their major version (45 or more) where
    // nfat_arch sits. Real fat files have a handful of slices, so a small cap tells them apart.
    private static let maxFatArchs: UInt32 = 30

    /// Whether the file at `url` is a static library that should not be embedded.
    ///
    /// Returns `true` for a thin ar archive, or for a fat file where every slice is an
    /// ar archive. Returns `false` for anything else (dylibs, fat files with any Mach-O
    /// slice, malformed fat headers). Returns `nil` if the file can't be opened.
    static func isStaticArchive(at url: URL) -> Bool? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return isStaticArchive { offset, count in
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: count) ?? Data()
        }
    }

    /// Same check over an in-memory buffer. Used by tests.
    static func isStaticArchive(data: Data) -> Bool {
        isStaticArchive { offset, count in
            guard offset < UInt64(data.count) else { return Data() }
            let start = data.startIndex + Int(offset)
            return data[start..<min(start + count, data.endIndex)]
        } ?? false
    }

    /// Core check. `read(offset, count)` returns up to `count` bytes at `offset`.
    /// Returns `nil` only when the very first read throws.
    private static func isStaticArchive(read: (UInt64, Int) throws -> Data) -> Bool? {
        guard let head = try? read(0, 8) else { return nil }
        if archiveMagics.contains(head) { return true }

        guard head.count == 8 else { return false }
        let magic = head.bigEndianUInt32(at: 0)
        let nfatArch = head.bigEndianUInt32(at: 4)
        let is64: Bool
        switch magic {
        case fatMagic: is64 = false
        case fatMagic64: is64 = true
        default: return false
        }
        guard nfatArch > 0, nfatArch <= maxFatArchs else { return false }

        let entrySize = is64 ? fatArch64Size : fatArchSize
        let tableSize = Int(nfatArch) * entrySize
        guard let table = try? read(8, tableSize), table.count == tableSize else { return false }

        for index in 0..<Int(nfatArch) {
            let entry = index * entrySize
            // cputype (4) and cpusubtype (4) come first, then the slice offset.
            let offset = is64
                ? table.bigEndianUInt64(at: entry + 8)
                : UInt64(table.bigEndianUInt32(at: entry + 8))
            guard let sliceHead = try? read(offset, 8), archiveMagics.contains(sliceHead) else {
                return false
            }
        }
        return true
    }
}

extension Data {
    fileprivate func bigEndianUInt32(at offset: Int) -> UInt32 {
        let start = startIndex + offset
        return self[start..<(start + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    fileprivate func bigEndianUInt64(at offset: Int) -> UInt64 {
        let start = startIndex + offset
        return self[start..<(start + 8)].reduce(0) { $0 << 8 | UInt64($1) }
    }
}
