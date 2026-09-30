//
//  ToolTrust.swift
//  Downloady
//
//  What a downloaded tool has to prove before Downloady runs it. A child
//  process runs with Droppy's privacy permissions and a URLSession download
//  is never seen by Gatekeeper, so nothing that comes from the same server as
//  the file counts: only a key or a Team ID compiled into the droplet.
//
//  - Deno and ffmpeg are signed with their publishers' Developer ID
//    certificates: the unpacked executable must carry that Team ID.
//  - yt-dlp's macOS build is signed ad hoc only, but every release's
//    `SHA2-256SUMS` carries an OpenPGP signature (`SHA2-256SUMS.sig`) from
//    yt-dlp's signing key, which is pinned below.
//

import CryptoKit
import Foundation
import Security

/// Developer ID code signatures, checked with the Security framework.
public enum CodeSignature {
    /// Deno Land Inc.
    public static let denoTeam = "2H4KBF436B"
    /// Martin Riedl, who builds ffmpeg.martin-riedl.de's binaries.
    public static let ffmpegTeam = "KU3N25YGLU"

    /// Whether `executable` is validly signed, every architecture, with a
    /// Developer ID Application certificate issued to `team`.
    public static func isDeveloperID(_ executable: URL, team: String) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess, let code else { return false }
        // Apple's anchor, the Developer ID intermediate, a Developer ID
        // Application leaf, and the team.
        let text = """
        anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
        and certificate leaf[field.1.2.840.113635.100.6.1.13] exists \
        and certificate leaf[subject.OU] = "\(team)"
        """
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }
}

/// Just enough OpenPGP (RFC 4880) to check a detached binary signature made
/// with an RSA key: yt-dlp's `SHA2-256SUMS.sig`.
public enum OpenPGP {
    /// yt-dlp's release signing key, verbatim from
    /// https://github.com/yt-dlp/yt-dlp/blob/master/public.key
    /// (Simon Sawicki, fingerprint AC0C BBE6 848D 6A87 3464 AF4E 57CF 6593 3B5A 7581).
    /// A new key means a new Downloady release, never a download.
    public static let ytDlpKey = """
    -----BEGIN PGP PUBLIC KEY BLOCK-----

    mQINBGP78C4BEAD0rF9zjGPAt0thlt5C1ebzccAVX7Nb1v+eqQjk+WEZdTETVCg3
    WAM5ngArlHdm/fZqzUgO+pAYrB60GKeg7ffUDf+S0XFKEZdeRLYeAaqqKhSibVal
    DjvOBOztu3W607HLETQAqA7wTPuIt2WqmpL60NIcyr27LxqmgdN3mNvZ2iLO+bP0
    nKR/C+PgE9H4ytywDa12zMx6PmZCnVOOOu6XZEFmdUxxdQ9fFDqd9LcBKY2LDOcS
    Yo1saY0YWiZWHtzVoZu1kOzjnS5Fjq/yBHJLImDH7pNxHm7s/PnaurpmQFtDFruk
    t+2lhDnpKUmGr/I/3IHqH/X+9nPoS4uiqQ5HpblB8BK+4WfpaiEg75LnvuOPfZIP
    KYyXa/0A7QojMwgOrD88ozT+VCkKkkJ+ijXZ7gHNjmcBaUdKK7fDIEOYI63Lyc6Q
    WkGQTigFffSUXWHDCO9aXNhP3ejqFWgGMtCUsrbkcJkWuWY7q5ARy/05HbSM3K4D
    U9eqtnxmiV1WQ8nXuI9JgJQRvh5PTkny5LtxqzcmqvWO9TjHBbrs14BPEO9fcXxK
    L/CFBbzXDSvvAgArdqqlMoncQ/yicTlfL6qzJ8EKFiqW14QMTdAn6SuuZTodXCTi
    InwoT7WjjuFPKKdvfH1GP4bnqdzTnzLxCSDIEtfyfPsIX+9GI7Jkk/zZjQARAQAB
    tDdTaW1vbiBTYXdpY2tpICh5dC1kbHAgc2lnbmluZyBrZXkpIDxjb250YWN0QGdy
    dWI0ay54eXo+iQJOBBMBCgA4FiEErAy75oSNaoc0ZK9OV89lkztadYEFAmP78C4C
    GwMFCwkIBwIGFQoJCAsCBBYCAwECHgECF4AACgkQV89lkztadYEVqQ//cW7TxhXg
    7Xbh2EZQzXml0egn6j8QaV9KzGragMiShrlvTO2zXfLXqyizrFP4AspgjSn/4NrI
    8mluom+Yi+qr7DXT4BjQqIM9y3AjwZPdywe912Lxcw52NNoPZCm24I9T7ySc8lmR
    FQvZC0w4H/VTNj/2lgJ1dwMflpwvNRiWa5YzcFGlCUeDIPskLx9++AJE+xwU3LYm
    jQQsPBqpHHiTBEJzMLl+rfd9Fg4N+QNzpFkTDW3EPerLuvJniSBBwZthqxeAtw4M
    UiAXh6JvCc2hJkKCoygRfM281MeolvmsGNyQm+axlB0vyldiPP6BnaRgZlx+l6MU
    cPqgHblb7RW5j9lfr6OYL7SceBIHNv0CFrt1OnkGo/tVMwcs8LH3Ae4a7UJlIceL
    V54aRxSsZU7w4iX+PB79BWkEsQzwKrUuJVOeL4UDwWajp75OFaUqbS/slDDVXvK5
    OIeuth3mA/adjdvgjPxhRQjA3l69rRWIJDrqBSHldmRsnX6cvXTDy8wSXZgy51lP
    m4IVLHnCy9m4SaGGoAsfTZS0cC9FgjUIyTyrq9M67wOMpUxnuB0aRZgJE1DsI23E
    qdvcSNVlO+39xM/KPWUEh6b83wMn88QeW+DCVGWACQq5N3YdPnAJa50617fGbY6I
    gXIoRHXkDqe23PZ/jURYCv0sjVtjPoVC+bg=
    =bJkn
    -----END PGP PUBLIC KEY BLOCK-----
    """

    public enum VerifyError: Error, Equatable {
        case malformed
        case unsupported
    }

    /// Whether `signature`, a binary detached OpenPGP signature, is a valid
    /// signature of `data` by the RSA primary key in `armoredKey`.
    public static func verify(_ data: Data, signature: Data, armoredKey: String) throws -> Bool {
        let key = try rsaKey(armoredKey)
        guard let packet = try packets([UInt8](signature)).first, packet.tag == 2 else { throw VerifyError.malformed }
        let body = packet.body
        // v4, a signature of a binary document, by an RSA key.
        guard body.count > 6, body[0] == 4 else { throw VerifyError.unsupported }
        guard body[1] == 0x00, body[2] == 1 else { throw VerifyError.unsupported }
        let algorithm: SecKeyAlgorithm
        let hashed: Data
        switch body[3] {
        case 8: (algorithm, hashed) = (.rsaSignatureDigestPKCS1v15SHA256, digest(SHA256.self, data, body))
        case 10: (algorithm, hashed) = (.rsaSignatureDigestPKCS1v15SHA512, digest(SHA512.self, data, body))
        default: throw VerifyError.unsupported
        }
        let hashedEnd = 6 + int(body, 4, 2)
        guard hashedEnd + 2 <= body.count else { throw VerifyError.malformed }
        let unhashedEnd = hashedEnd + 2 + int(body, hashedEnd, 2)
        // Skip the two-octet digest prefix; the MPI after it is the signature.
        let (value, _) = try mpi(body, unhashedEnd + 2)
        // An MPI drops leading zeros; RSA wants the modulus's length.
        let size = SecKeyGetBlockSize(key)
        guard value.count <= size else { throw VerifyError.malformed }
        let padded = Data(repeating: 0, count: size - value.count) + value
        return SecKeyVerifySignature(key, algorithm, hashed as CFData, padded as CFData, nil)
    }

    /// The v4 fingerprint of the primary key in `armoredKey`, uppercase hex.
    public static func fingerprint(_ armoredKey: String) throws -> String {
        let body = try primaryKeyPacket(armoredKey)
        var bytes: [UInt8] = [0x99, UInt8(body.count >> 8), UInt8(body.count & 0xFF)]
        bytes += body
        return Insecure.SHA1.hash(data: bytes).map { String(format: "%02X", $0) }.joined()
    }

    // MARK: Packets

    struct Packet { let tag: Int; let body: [UInt8] }

    static func packets(_ bytes: [UInt8]) throws -> [Packet] {
        var packets: [Packet] = []
        var i = 0
        while i < bytes.count {
            let header = bytes[i]
            guard header & 0x80 != 0 else { throw VerifyError.malformed }
            let tag: Int, length: Int, headerSize: Int
            if header & 0x40 != 0 {
                // New format; partial lengths never appear in keys or signatures.
                tag = Int(header & 0x3F)
                guard i + 1 < bytes.count else { throw VerifyError.malformed }
                let first = Int(bytes[i + 1])
                switch first {
                case ..<192: (length, headerSize) = (first, 2)
                case ..<224: (length, headerSize) = (((first - 192) << 8) + int(bytes, i + 2, 1) + 192, 3)
                case 255: (length, headerSize) = (int(bytes, i + 2, 4), 6)
                default: throw VerifyError.unsupported
                }
            } else {
                tag = Int((header >> 2) & 0x0F)
                let octets = [1, 2, 4, 0][Int(header & 0x03)]
                guard octets > 0 else { throw VerifyError.unsupported }
                (length, headerSize) = (int(bytes, i + 1, octets), 1 + octets)
            }
            let start = i + headerSize
            guard start + length <= bytes.count else { throw VerifyError.malformed }
            packets.append(Packet(tag: tag, body: Array(bytes[start ..< start + length])))
            i = start + length
        }
        return packets
    }

    static func dearmor(_ armored: String) throws -> [UInt8] {
        var inside = false, base64 = ""
        for line in armored.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("-----BEGIN") { inside = true; continue }
            if line.hasPrefix("-----END") { break }
            // Armor headers ("Key: value") and the CRC line ("=abcd") are not data.
            guard inside, !line.isEmpty, !line.contains(":"), !line.hasPrefix("=") else { continue }
            base64 += line
        }
        guard let data = Data(base64Encoded: base64) else { throw VerifyError.malformed }
        return [UInt8](data)
    }

    static func primaryKeyPacket(_ armoredKey: String) throws -> [UInt8] {
        guard let key = try packets(dearmor(armoredKey)).first(where: { $0.tag == 6 }) else { throw VerifyError.malformed }
        return key.body
    }

    /// The RSA primary key as a Security framework key.
    static func rsaKey(_ armoredKey: String) throws -> SecKey {
        let body = try primaryKeyPacket(armoredKey)
        // v4, then a four-octet creation time, then the algorithm: RSA.
        guard body.count > 6, body[0] == 4, body[5] == 1 else { throw VerifyError.unsupported }
        let (modulus, next) = try mpi(body, 6)
        let (exponent, _) = try mpi(body, next)
        // PKCS #1 RSAPublicKey: SEQUENCE { INTEGER n, INTEGER e }.
        let der = DER.sequence(DER.integer(modulus) + DER.integer(exponent))
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        guard let key = SecKeyCreateWithData(Data(der) as CFData, attributes as CFDictionary, nil) else {
            throw VerifyError.malformed
        }
        return key
    }

    // MARK: Helpers

    /// The v4 signature digest: the data, the signature's hashed part, and
    /// the trailer `04 FF <length of the hashed part>`.
    private static func digest<H: HashFunction>(_: H.Type, _ data: Data, _ body: [UInt8]) -> Data {
        let hashedPart = Array(body.prefix(6 + int(body, 4, 2)))
        let count = hashedPart.count
        var hasher = H()
        hasher.update(data: data)
        hasher.update(data: hashedPart)
        hasher.update(data: [0x04, 0xFF, UInt8(count >> 24 & 0xFF), UInt8(count >> 16 & 0xFF), UInt8(count >> 8 & 0xFF), UInt8(count & 0xFF)])
        return Data(hasher.finalize())
    }

    /// A multiprecision integer at `offset` and the offset after it.
    private static func mpi(_ bytes: [UInt8], _ offset: Int) throws -> (Data, Int) {
        guard offset + 2 <= bytes.count else { throw VerifyError.malformed }
        let end = offset + 2 + (int(bytes, offset, 2) + 7) / 8
        guard end <= bytes.count else { throw VerifyError.malformed }
        return (Data(bytes[offset + 2 ..< end]), end)
    }

    /// A big-endian unsigned integer of `count` octets; 0 past the end.
    private static func int(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> Int {
        guard offset >= 0, offset + count <= bytes.count else { return 0 }
        return bytes[offset ..< offset + count].reduce(0) { $0 << 8 | Int($1) }
    }

    private enum DER {
        static func length(_ n: Int) -> [UInt8] {
            if n < 128 { return [UInt8(n)] }
            let octets = stride(from: (n.bitWidth - n.leadingZeroBitCount + 7) / 8 - 1, through: 0, by: -1).map { UInt8(n >> ($0 * 8) & 0xFF) }
            return [0x80 | UInt8(octets.count)] + octets
        }
        static func integer(_ value: Data) -> [UInt8] {
            // A leading 1 bit would read as negative.
            let bytes = (value.first ?? 0) & 0x80 != 0 ? [0] + [UInt8](value) : [UInt8](value)
            return [0x02] + length(bytes.count) + bytes
        }
        static func sequence(_ content: [UInt8]) -> [UInt8] { [0x30] + length(content.count) + content }
    }
}
