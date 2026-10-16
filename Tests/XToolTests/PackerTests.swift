import Testing
import Foundation
@testable import PackLib

@Test func cfBundleSupportedPlatformsFollowsBuildTriple() {
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-ios") == ["iPhoneOS"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-ios-simulator") == ["iPhoneSimulator"])

    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-ios17.0") == ["iPhoneOS"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-ios17.0-simulator") == ["iPhoneSimulator"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "x86_64-apple-ios-simulator") == ["iPhoneSimulator"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "arm64-apple-macosx") == ["MacOSX"])
    #expect(Packer.cfBundleSupportedPlatforms(for: "x86_64-apple-macosx") == ["MacOSX"])

    #expect(Packer.cfBundleSupportedPlatforms(for: "unknown-triple") == ["iPhoneOS"])
}

// MARK: - Static archive detection

private let arSlice = Data("!<arch>\n".utf8) + Data(repeating: 0, count: 8)
// MH_MAGIC_64 as stored on disk by a little-endian arm64 slice.
private let machOSlice = Data([0xCF, 0xFA, 0xED, 0xFE]) + Data(repeating: 0, count: 12)

private func bigEndian<T: FixedWidthInteger>(_ value: T) -> Data {
    withUnsafeBytes(of: value.bigEndian) { Data($0) }
}

/// Builds a fat file with one slice per entry, laid out right after the header.
private func fatFile(_ slices: [Data], is64: Bool = false) -> Data {
    let entrySize = is64 ? 32 : 20
    var offset = 8 + slices.count * entrySize
    var data = bigEndian(is64 ? UInt32(0xCAFEBABF) : UInt32(0xCAFEBABE)) + bigEndian(UInt32(slices.count))
    for slice in slices {
        data += bigEndian(UInt32(0x0100_000C)) + bigEndian(UInt32(0)) // CPU_TYPE_ARM64, subtype
        if is64 {
            data += bigEndian(UInt64(offset)) + bigEndian(UInt64(slice.count))
            data += bigEndian(UInt32(0)) + bigEndian(UInt32(0)) // align, reserved
        } else {
            data += bigEndian(UInt32(offset)) + bigEndian(UInt32(slice.count)) + bigEndian(UInt32(0))
        }
        offset += slice.count
    }
    for slice in slices { data += slice }
    return data
}

@Test func thinArchiveIsStatic() {
    #expect(Packer.isStaticArchive(data: arSlice))
    #expect(Packer.isStaticArchive(data: Data("!<thin>\n".utf8)))
}

@Test func thinMachOIsNotStatic() {
    #expect(!Packer.isStaticArchive(data: machOSlice))
}

@Test func fatFileOfArchivesIsStatic() {
    #expect(Packer.isStaticArchive(data: fatFile([arSlice])))
    #expect(Packer.isStaticArchive(data: fatFile([arSlice, arSlice])))
    #expect(Packer.isStaticArchive(data: fatFile([arSlice, arSlice], is64: true)))
}

@Test func fatFileWithMachOSliceIsNotStatic() {
    #expect(!Packer.isStaticArchive(data: fatFile([machOSlice])))
    #expect(!Packer.isStaticArchive(data: fatFile([machOSlice], is64: true)))
    #expect(!Packer.isStaticArchive(data: fatFile([arSlice, machOSlice])))
}

@Test func malformedFatFileIsNotStatic() {
    // Java class file: same magic, major version 65 where nfat_arch would be.
    #expect(!Packer.isStaticArchive(data: bigEndian(UInt32(0xCAFEBABE)) + bigEndian(UInt32(65))))
    // Truncated arch table.
    #expect(!Packer.isStaticArchive(data: fatFile([arSlice]).prefix(12)))
    // Slice offset past the end of the file.
    var pastEnd = fatFile([arSlice])
    pastEnd.replaceSubrange(16..<20, with: bigEndian(UInt32(10_000)))
    #expect(!Packer.isStaticArchive(data: pastEnd))
    #expect(!Packer.isStaticArchive(data: Data()))
}

@Test func staticArchiveCheckReadsFiles() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xtool-packer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let staticURL = dir.appendingPathComponent("static")
    try fatFile([arSlice, arSlice]).write(to: staticURL)
    #expect(Packer.isStaticArchive(at: staticURL) == true)

    let dynamicURL = dir.appendingPathComponent("dynamic")
    try fatFile([machOSlice]).write(to: dynamicURL)
    #expect(Packer.isStaticArchive(at: dynamicURL) == false)

    #expect(Packer.isStaticArchive(at: dir.appendingPathComponent("missing")) == nil)
}

// MARK: - Linker settings

private func product(_ type: Plan.ProductType) -> Plan.Product {
    Plan.Product(
        type: type,
        product: "Example",
        deploymentTarget: "17.0",
        bundleID: "com.example.Example",
        infoPlist: [:],
        resources: [],
        iconPath: nil,
        entitlementsPath: nil
    )
}

@Test func appExtensionKeepsItsOwnCode() {
    // the extension library is an archive nothing references, so its members must be force-loaded
    let settings = product(.appExtension).linkerSettings
    #expect(settings.contains(#""-Xlinker", "-e", "-Xlinker", "_NSExtensionMain""#))
    #expect(settings.contains(#""-Xlinker", "-all_load""#))
    #expect(!product(.application).linkerSettings.contains("-all_load"))
}
