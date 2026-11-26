import Foundation

/// The entitlements a binary was signed with, read from its code signature: what `codesign -d --entitlements`
/// shows. iOS has no API for reading them, for this process or another bundle. Only a thin 64-bit Mach-O is
/// read, which is what Xcode builds for a phone.
struct SignedEntitlements {
    private let bytes: [UInt8]

    private static let machO64: UInt32 = 0xfeed_facf
    private static let codeSignatureCommand: UInt32 = 0x1d
    private static let superBlob: UInt32 = 0xfade_0cc0
    private static let entitlementsSlot: UInt32 = 5
    private static let entitlementsBlob: UInt32 = 0xfade_7171

    /// Nil if the binary isn't a thin 64-bit Mach-O, or isn't signed with entitlements (simulator builds aren't).
    static func of(_ executable: URL) throws -> [String: Any]? {
        try SignedEntitlements(bytes: [UInt8](Data(contentsOf: executable))).read()
    }

    private func read() -> [String: Any]? {
        guard little(0) == Self.machO64, let commandCount = little(16) else { return nil }
        var command = 32  // past the header
        for _ in 0..<commandCount {
            guard let kind = little(command), let size = little(command + 4) else { return nil }
            if kind == Self.codeSignatureCommand, let signature = little(command + 8) {
                return entitlements(inSignatureAt: Int(signature))
            }
            command += Int(size)
        }
        return nil
    }

    /// The signature is a big-endian index of blobs; the entitlements are one of them, as an XML property list.
    private func entitlements(inSignatureAt start: Int) -> [String: Any]? {
        guard big(start) == Self.superBlob, let count = big(start + 8) else { return nil }
        for index in 0..<Int(count) {
            let entry = start + 12 + index * 8
            guard big(entry) == Self.entitlementsSlot, let offset = big(entry + 4) else { continue }
            let blob = start + Int(offset)
            guard big(blob) == Self.entitlementsBlob, let length = big(blob + 4), blob + Int(length) <= bytes.count
            else { return nil }
            let xml = Data(bytes[(blob + 8)..<(blob + Int(length))])
            return try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any]
        }
        return nil
    }

    private func word(_ at: Int) -> [UInt8]? {
        at >= 0 && at + 4 <= bytes.count ? Array(bytes[at..<(at + 4)]) : nil
    }

    private func little(_ at: Int) -> UInt32? {
        word(at)?.reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }

    private func big(_ at: Int) -> UInt32? {
        word(at)?.reduce(0) { $0 << 8 | UInt32($1) }
    }
}
