#if canImport(CryptoKit)
import CryptoKit
#else
@preconcurrency import Crypto
#endif
import Foundation

/// Builds the Mac's self-signed TLS certificate: X.509 v3, ECDSA P-256 with SHA-256.
public enum SelfSignedCertificate {
    public static func make(key: P256.Signing.PrivateKey, commonName: String, serial: UInt64, notBefore: Date, years: Int) throws -> Data {
        try make(publicKey: key.publicKey.x963Representation, commonName: commonName, serial: serial, notBefore: notBefore, years: years) {
            try key.signature(for: $0).derRepresentation
        }
    }

    /// For a key that can't leave where it lives, such as the keychain.
    /// `publicKey` is the uncompressed X9.63 point, and `sign` returns the
    /// DER ECDSA-SHA256 signature of the bytes it's given.
    public static func make(publicKey: Data, commonName: String, serial: UInt64, notBefore: Date, years: Int,
                            sign: (Data) throws -> Data) throws -> Data {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = .gmt
        let notAfter = gregorian.date(byAdding: .year, value: years, to: notBefore) ?? notBefore

        let signatureAlgorithm = DER.sequence([DER.oid([1, 2, 840, 10045, 4, 3, 2])])
        let name = DER.sequence([DER.set([DER.sequence([DER.oid([2, 5, 4, 3]), DER.utf8(commonName)])])])
        let publicKeyInfo = DER.sequence([
            DER.sequence([DER.oid([1, 2, 840, 10045, 2, 1]), DER.oid([1, 2, 840, 10045, 3, 1, 7])]),
            DER.bitString(publicKey),
        ])
        // Not a CA. cA defaults to false, and DER leaves defaults out.
        let basicConstraints = DER.sequence([
            DER.oid([2, 5, 29, 19]),
            DER.octetString(DER.sequence([])),
        ])
        let dnsName = DER.tagged(0x82, Data("workbench.local".utf8))
        let alternativeNames = DER.sequence([
            DER.oid([2, 5, 29, 17]),
            DER.octetString(DER.sequence([dnsName])),
        ])
        let extensions = DER.tagged(0xA3, DER.sequence([basicConstraints, alternativeNames]))

        let tbs = DER.sequence([
            DER.tagged(0xA0, DER.integer(2)),
            DER.integer(serial),
            signatureAlgorithm,
            name,
            DER.sequence([DER.time(notBefore, calendar: gregorian), DER.time(notAfter, calendar: gregorian)]),
            name,
            publicKeyInfo,
            extensions,
        ])
        let signature = try sign(tbs)
        return DER.sequence([tbs, signatureAlgorithm, DER.bitString(signature)])
    }
}

/// The few DER encodings a certificate needs.
private enum DER {
    static func tagged(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        let count = content.count
        if count < 0x80 {
            out.append(UInt8(count))
        } else {
            var bytes: [UInt8] = []
            var rest = count
            while rest > 0 {
                bytes.insert(UInt8(rest & 0xff), at: 0)
                rest >>= 8
            }
            out.append(0x80 | UInt8(bytes.count))
            out.append(contentsOf: bytes)
        }
        return out + content
    }

    static func sequence(_ parts: [Data]) -> Data { tagged(0x30, parts.reduce(Data(), +)) }
    static func set(_ parts: [Data]) -> Data { tagged(0x31, parts.reduce(Data(), +)) }
    static func octetString(_ content: Data) -> Data { tagged(0x04, content) }
    static func utf8(_ text: String) -> Data { tagged(0x0C, Data(text.utf8)) }

    static func bitString(_ content: Data) -> Data { tagged(0x03, Data([0]) + content) }

    static func integer(_ value: UInt64) -> Data {
        var bytes: [UInt8] = []
        var rest = value
        repeat {
            bytes.insert(UInt8(rest & 0xff), at: 0)
            rest >>= 8
        } while rest > 0
        // A leading high bit would read as negative.
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tagged(0x02, Data(bytes))
    }

    static func oid(_ arcs: [UInt]) -> Data {
        var bytes: [UInt8] = [UInt8(arcs[0] * 40 + arcs[1])]
        for arc in arcs.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(arc & 0x7f)]
            var rest = arc >> 7
            while rest > 0 {
                chunk.insert(UInt8(rest & 0x7f) | 0x80, at: 0)
                rest >>= 7
            }
            bytes.append(contentsOf: chunk)
        }
        return tagged(0x06, Data(bytes))
    }

    // UTCTime through 2049, GeneralizedTime after that.
    static func time(_ date: Date, calendar: Calendar) -> Data {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = parts.year ?? 1970
        let rest = String(format: "%02d%02d%02d%02d%02dZ", parts.month ?? 1, parts.day ?? 1, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        if year < 2050 {
            return tagged(0x17, Data((String(format: "%02d", year % 100) + rest).utf8))
        }
        return tagged(0x18, Data((String(format: "%04d", year) + rest).utf8))
    }
}
