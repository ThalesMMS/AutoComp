import Foundation

public struct AutoCompTokenFlags: OptionSet, Equatable, Hashable, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let control = Self(rawValue: 1 << 0)
    public static let special = Self(rawValue: 1 << 1)
    public static let stop = Self(rawValue: 1 << 2)
    public static let endOfGeneration = Self(rawValue: 1 << 3)
    public static let whitespace = Self(rawValue: 1 << 4)
    public static let printable = Self(rawValue: 1 << 5)
}

public enum AutoCompTokenByteClass: UInt8, Equatable, Sendable {
    case empty = 0
    case asciiControl = 1
    case asciiWhitespace = 2
    case asciiPunctuation = 3
    case asciiDigit = 4
    case asciiLetter = 5
    case utf8Continuation = 6
    case utf8Leading = 7
    case other = 8

    public init(byte: UInt8?) {
        guard let byte else {
            self = .empty
            return
        }
        switch byte {
        case 32, 9...13:
            self = .asciiWhitespace
        case 0..<32, 127:
            self = .asciiControl
        case 48...57:
            self = .asciiDigit
        case 65...90, 97...122:
            self = .asciiLetter
        case 33...47, 58...64, 91...96, 123...126:
            self = .asciiPunctuation
        case 128...191:
            self = .utf8Continuation
        case 192...247:
            self = .utf8Leading
        default:
            self = .other
        }
    }
}

public struct AutoCompTokenRecord: Equatable, Sendable {
    public var id: Int32
    public var bytes: Data
    public var flags: AutoCompTokenFlags
    public var approximateDisplayWidth: UInt16

    public init(
        id: Int32,
        bytes: Data,
        flags: AutoCompTokenFlags = [],
        approximateDisplayWidth: UInt16? = nil
    ) {
        self.id = id
        self.bytes = bytes
        self.flags = flags
        self.approximateDisplayWidth = approximateDisplayWidth
            ?? Self.displayWidth(of: bytes)
    }

    public var firstByte: UInt8? { bytes.first }
    public var lastByte: UInt8? { bytes.last }
    public var firstByteClass: AutoCompTokenByteClass { .init(byte: firstByte) }
    public var lastByteClass: AutoCompTokenByteClass { .init(byte: lastByte) }

    private static func displayWidth(of bytes: Data) -> UInt16 {
        guard let text = String(data: bytes, encoding: .utf8) else { return 0 }
        let width = text.reduce(into: 0) { result, character in
            if character == "\t" {
                result += 4
            } else if !character.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }) {
                result += 1
            }
        }
        return UInt16(clamping: width)
    }
}

public struct AutoCompTokenProfile: Equatable, Sendable {
    public static let schemaVersion: UInt16 = 1

    public var modelFamily: String
    public var tokenizerDigest: Data
    public var records: [AutoCompTokenRecord]
    public var specialTokenIDs: Set<Int32>
    public var stopTokenIDs: Set<Int32>

    public init(
        modelFamily: String,
        tokenizerDigest: Data,
        records: [AutoCompTokenRecord],
        specialTokenIDs: Set<Int32> = [],
        stopTokenIDs: Set<Int32> = []
    ) {
        self.modelFamily = modelFamily
        self.tokenizerDigest = tokenizerDigest
        self.records = records
        self.specialTokenIDs = specialTokenIDs
        self.stopTokenIDs = stopTokenIDs
    }

    public var vocabularySize: Int { records.count }
}

public enum AutoCompTokenProfileError: LocalizedError, Equatable, Sendable {
    case invalidMagic
    case unsupportedVersion(UInt16)
    case endiannessMismatch
    case truncated
    case lengthMismatch
    case checksumMismatch
    case invalidUTF8Metadata
    case invalidVocabulary
    case tokenizerDigestMismatch
    case vocabularySizeMismatch(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidMagic: return "Token profile magic is invalid."
        case .unsupportedVersion(let version): return "Token profile schema version \(version) is unsupported."
        case .endiannessMismatch: return "Token profile endianness marker is invalid."
        case .truncated: return "Token profile is truncated."
        case .lengthMismatch: return "Token profile declared length does not match the file."
        case .checksumMismatch: return "Token profile checksum does not match its payload."
        case .invalidUTF8Metadata: return "Token profile metadata is not valid UTF-8."
        case .invalidVocabulary: return "Token profile vocabulary is not contiguous and unique."
        case .tokenizerDigestMismatch: return "Token profile tokenizer digest does not match the loaded model."
        case .vocabularySizeMismatch(let expected, let actual):
            return "Token profile vocabulary size \(expected) does not match runtime size \(actual)."
        }
    }
}

public enum AutoCompTokenProfileCodec {
    private static let magic = Data([0x41, 0x43, 0x54, 0x4B, 0x50, 0x30, 0x31, 0x00]) // ACTKP01\0
    private static let endianMarker: UInt32 = 0x0102_0304
    private static let checksumBytes = 4
    private static let minimumEncodedRecordBytes = 16

    public static func encode(_ profile: AutoCompTokenProfile) throws -> Data {
        try validateVocabulary(profile.records)
        var writer = BinaryWriter()
        writer.append(magic)
        writer.append(AutoCompTokenProfile.schemaVersion)
        writer.append(endianMarker)
        let lengthOffset = writer.data.count
        writer.append(UInt64(0))
        writer.append(UInt32(profile.records.count))
        try writer.appendLengthPrefixed(Data(profile.modelFamily.utf8), lengthType: UInt16.self)
        try writer.appendLengthPrefixed(profile.tokenizerDigest, lengthType: UInt16.self)
        writer.append(UInt32(profile.specialTokenIDs.count))
        for id in profile.specialTokenIDs.sorted() { writer.append(id) }
        writer.append(UInt32(profile.stopTokenIDs.count))
        for id in profile.stopTokenIDs.sorted() { writer.append(id) }
        for record in profile.records.sorted(by: { $0.id < $1.id }) {
            writer.append(record.id)
            writer.append(record.flags.rawValue)
            writer.append(record.approximateDisplayWidth)
            writer.append(record.firstByte ?? 0)
            writer.append(record.lastByte ?? 0)
            writer.append(record.firstByteClass.rawValue)
            writer.append(record.lastByteClass.rawValue)
            try writer.appendLengthPrefixed(record.bytes, lengthType: UInt32.self)
        }
        let finalLength = UInt64(writer.data.count + checksumBytes)
        writer.replaceUInt64(at: lengthOffset, with: finalLength)
        writer.append(crc32(writer.data))
        return writer.data
    }

    public static func decode(_ data: Data) throws -> AutoCompTokenProfile {
        guard data.count >= magic.count + 2 + 4 + 8 + checksumBytes else {
            throw AutoCompTokenProfileError.truncated
        }
        let payload = data.dropLast(checksumBytes)
        let expectedChecksum = try BinaryReader(data: data).uint32(at: data.count - checksumBytes)
        guard crc32(Data(payload)) == expectedChecksum else {
            throw AutoCompTokenProfileError.checksumMismatch
        }
        var reader = BinaryReader(data: Data(payload))
        guard try reader.readData(count: magic.count) == magic else {
            throw AutoCompTokenProfileError.invalidMagic
        }
        let version: UInt16 = try reader.read()
        guard version == AutoCompTokenProfile.schemaVersion else {
            throw AutoCompTokenProfileError.unsupportedVersion(version)
        }
        let marker: UInt32 = try reader.read()
        guard marker == endianMarker else { throw AutoCompTokenProfileError.endiannessMismatch }
        let declaredLength: UInt64 = try reader.read()
        guard declaredLength == UInt64(data.count) else { throw AutoCompTokenProfileError.lengthMismatch }
        let vocabularySize = Int(try reader.read() as UInt32)
        let familyData = try reader.readLengthPrefixed(UInt16.self)
        let digest = try reader.readLengthPrefixed(UInt16.self)
        guard let family = String(data: familyData, encoding: .utf8) else {
            throw AutoCompTokenProfileError.invalidUTF8Metadata
        }
        let specialCount = Int(try reader.read() as UInt32)
        var specialIDs = Set<Int32>()
        for _ in 0..<specialCount { specialIDs.insert(try reader.read()) }
        let stopCount = Int(try reader.read() as UInt32)
        var stopIDs = Set<Int32>()
        for _ in 0..<stopCount { stopIDs.insert(try reader.read()) }

        guard vocabularySize <= reader.remainingByteCount / minimumEncodedRecordBytes else {
            throw AutoCompTokenProfileError.truncated
        }
        var records: [AutoCompTokenRecord] = []
        records.reserveCapacity(vocabularySize)
        for _ in 0..<vocabularySize {
            let id: Int32 = try reader.read()
            let flags = AutoCompTokenFlags(rawValue: try reader.read())
            let width: UInt16 = try reader.read()
            _ = try reader.read() as UInt8
            _ = try reader.read() as UInt8
            _ = try reader.read() as UInt8
            _ = try reader.read() as UInt8
            let bytes = try reader.readLengthPrefixed(UInt32.self)
            records.append(AutoCompTokenRecord(id: id, bytes: bytes, flags: flags, approximateDisplayWidth: width))
        }
        guard reader.isAtEnd else { throw AutoCompTokenProfileError.lengthMismatch }
        try validateVocabulary(records)
        return AutoCompTokenProfile(
            modelFamily: family,
            tokenizerDigest: digest,
            records: records,
            specialTokenIDs: specialIDs,
            stopTokenIDs: stopIDs
        )
    }

    public static func load(from url: URL, mappedIfSafe: Bool = true) throws -> AutoCompTokenProfile {
        let options: Data.ReadingOptions = mappedIfSafe ? [.mappedIfSafe] : []
        return try decode(Data(contentsOf: url, options: options))
    }

    public static func validate(
        _ profile: AutoCompTokenProfile,
        tokenizerDigest: Data,
        vocabularySize: Int
    ) throws {
        guard profile.vocabularySize == vocabularySize else {
            throw AutoCompTokenProfileError.vocabularySizeMismatch(
                expected: profile.vocabularySize,
                actual: vocabularySize
            )
        }
        guard profile.tokenizerDigest == tokenizerDigest else {
            throw AutoCompTokenProfileError.tokenizerDigestMismatch
        }
    }

    public static func tokenizerDigest(records: [AutoCompTokenRecord]) -> Data {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for record in records.sorted(by: { $0.id < $1.id }) {
            for byte in withUnsafeBytes(of: record.id.littleEndian, Array.init) + record.bytes {
                hash ^= UInt64(byte)
                hash &*= 0x0000_0100_0000_01B3
            }
        }
        var value = hash.littleEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    private static func validateVocabulary(_ records: [AutoCompTokenRecord]) throws {
        let ids = records.map(\.id).sorted()
        guard ids.count == Set(ids).count,
              ids.enumerated().allSatisfy({ $0.offset == Int($0.element) }) else {
            throw AutoCompTokenProfileError.invalidVocabulary
        }
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1)))
            }
        }
        return ~crc
    }
}

public struct AutoCompTokenPrefixIndex: Sendable {
    private struct Node: Sendable {
        var children: [UInt8: Int] = [:]
        var tokenIDs: [Int32] = []
    }

    private var nodes: [Node] = [Node()]

    public init(records: [AutoCompTokenRecord]) {
        for record in records where !record.bytes.isEmpty {
            var nodeIndex = 0
            for byte in record.bytes {
                if let next = nodes[nodeIndex].children[byte] {
                    nodeIndex = next
                } else {
                    let next = nodes.count
                    nodes.append(Node())
                    nodes[nodeIndex].children[byte] = next
                    nodeIndex = next
                }
                nodes[nodeIndex].tokenIDs.append(record.id)
            }
        }
    }

    public func tokenIDs(startingWith prefix: Data) -> [Int32] {
        var index = 0
        for byte in prefix {
            guard let next = nodes[index].children[byte] else { return [] }
            index = next
        }
        return Array(Set(nodes[index].tokenIDs)).sorted()
    }
}

private protocol BinaryIntegerValue: FixedWidthInteger {}
extension UInt8: BinaryIntegerValue {}
extension UInt16: BinaryIntegerValue {}
extension UInt32: BinaryIntegerValue {}
extension UInt64: BinaryIntegerValue {}
extension Int32: BinaryIntegerValue {}

private struct BinaryWriter {
    var data = Data()

    mutating func append(_ bytes: Data) { data.append(bytes) }

    mutating func append<T: BinaryIntegerValue>(_ value: T) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func appendLengthPrefixed<T: BinaryIntegerValue>(_ bytes: Data, lengthType: T.Type) throws {
        guard let length = T(exactly: bytes.count) else { throw AutoCompTokenProfileError.lengthMismatch }
        append(length)
        append(bytes)
    }

    mutating func replaceUInt64(at offset: Int, with value: UInt64) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }
    }
}

private struct BinaryReader {
    let data: Data
    private(set) var offset = 0
    var isAtEnd: Bool { offset == data.count }
    var remainingByteCount: Int { data.count - offset }

    mutating func read<T: BinaryIntegerValue>() throws -> T {
        let size = MemoryLayout<T>.size
        guard offset + size <= data.count else { throw AutoCompTokenProfileError.truncated }
        let value = data.withUnsafeBytes { raw -> T in
            var result: T = 0
            withUnsafeMutableBytes(of: &result) { destination in
                destination.copyBytes(from: raw[offset..<(offset + size)])
            }
            return T(littleEndian: result)
        }
        offset += size
        return value
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else { throw AutoCompTokenProfileError.truncated }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    mutating func readLengthPrefixed<T: BinaryIntegerValue>(_ type: T.Type) throws -> Data {
        let raw: T = try read()
        guard let count = Int(exactly: raw) else { throw AutoCompTokenProfileError.lengthMismatch }
        return try readData(count: count)
    }

    func uint32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { throw AutoCompTokenProfileError.truncated }
        return data.withUnsafeBytes { raw in
            var result: UInt32 = 0
            withUnsafeMutableBytes(of: &result) { $0.copyBytes(from: raw[offset..<(offset + 4)]) }
            return UInt32(littleEndian: result)
        }
    }
}
