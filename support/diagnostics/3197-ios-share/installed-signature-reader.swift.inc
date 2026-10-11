// Insert these members inside each existing observer class. The caller invokes
// installedSignature3197() once and adds role/PID/bundle ID; this never logs.

private enum InstalledSignatureObservationError: Error {
    case invalid(String)
}

private static func installedSignature3197() -> [String: Any] {
    var xmlPresent = false
    var derPresent = false
    func result(_ status: String, groups: [String]? = nil) -> [String: Any] {
        var value: [String: Any] = ["status": status, "xmlPresent": xmlPresent, "derPresent": derPresent]
        if let groups = groups { value["groups"] = groups }
        return value
    }
    let fileLimit = 256 * 1024 * 1024
    let signatureLimit = 16 * 1024 * 1024
    guard let url = Bundle.main.executableURL, url.isFileURL else { return result("no_executable_url") }
    let data: Data
    do {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else { return result("executable_unreadable") }
        guard size.int64Value >= 0, size.int64Value <= Int64(fileLimit) else { return result("file_too_large") }
        data = try Data(contentsOf: url, options: [.mappedIfSafe])
    } catch {
        return result("executable_unreadable")
    }
    guard data.count <= fileLimit else { return result("file_too_large") }
    do {
        // Int conversion of UInt32 is safe on this explicitly 64-bit parser.
        guard MemoryLayout<Int>.size == 8 else { return result("unsupported_macho") }
        guard data.count >= 32 else { return result("unsupported_macho") }
        guard try installedSignatureWord(data, 0, bigEndian: false) == 0xfeedfacf,
              try installedSignatureWord(data, 4, bigEndian: false) == 0x0100000c,
              try installedSignatureWord(data, 12, bigEndian: false) == 2 else {
            return result("unsupported_macho")
        }
        let commandCount = Int(try installedSignatureWord(data, 16, bigEndian: false))
        let commandBytes = Int(try installedSignatureWord(data, 20, bigEndian: false))
        guard commandCount <= 4096, installedSignatureFits(32, commandBytes, in: data.count) else {
            throw InstalledSignatureObservationError.invalid("malformed_macho")
        }
        let commandEnd = 32 + commandBytes
        var cursor = 32
        var signature: (offset: Int, length: Int)?
        for _ in 0..<commandCount {
            guard installedSignatureFits(cursor, 8, in: commandEnd) else {
                throw InstalledSignatureObservationError.invalid("malformed_macho")
            }
            let command = try installedSignatureWord(data, cursor, bigEndian: false)
            let length = Int(try installedSignatureWord(data, cursor + 4, bigEndian: false))
            guard length >= 8, length % 8 == 0, installedSignatureFits(cursor, length, in: commandEnd) else {
                throw InstalledSignatureObservationError.invalid("malformed_macho")
            }
            if command == 0x1d {
                guard signature == nil, length == 16 else {
                    throw InstalledSignatureObservationError.invalid("malformed_signature")
                }
                signature = (Int(try installedSignatureWord(data, cursor + 8, bigEndian: false)),
                             Int(try installedSignatureWord(data, cursor + 12, bigEndian: false)))
            }
            cursor += length // Validated against commandEnd above.
        }
        guard cursor == commandEnd else { throw InstalledSignatureObservationError.invalid("malformed_macho") }
        guard let signature = signature else { return result("no_embedded_signature") }
        guard signature.length <= signatureLimit else { return result("signature_too_large") }
        guard signature.offset >= commandEnd, signature.length >= 12,
              installedSignatureFits(signature.offset, signature.length, in: data.count) else {
            throw InstalledSignatureObservationError.invalid("malformed_signature")
        }
        let base = signature.offset
        guard try installedSignatureWord(data, base, bigEndian: true) == 0xfade0cc0 else {
            return result("unsupported_signature")
        }
        let blobLength = Int(try installedSignatureWord(data, base + 4, bigEndian: true))
        let blobCount = Int(try installedSignatureWord(data, base + 8, bigEndian: true))
        guard blobLength >= 12, blobLength <= signature.length, blobCount <= 4096 else {
            throw InstalledSignatureObservationError.invalid("malformed_signature")
        }
        let indexEnd = 12 + blobCount * 8 // Count cap makes multiplication bounded.
        guard indexEnd <= blobLength else { throw InstalledSignatureObservationError.invalid("malformed_signature") }
        var regions: [(start: Int, end: Int)] = []
        var xmlPayload: Range<Int>?
        for index in 0..<blobCount {
            let entry = base + 12 + index * 8
            let type = try installedSignatureWord(data, entry, bigEndian: true)
            let offset = Int(try installedSignatureWord(data, entry + 4, bigEndian: true))
            guard offset >= indexEnd, installedSignatureFits(offset, 8, in: blobLength) else {
                throw InstalledSignatureObservationError.invalid("malformed_signature")
            }
            let child = base + offset
            let magic = try installedSignatureWord(data, child, bigEndian: true)
            let length = Int(try installedSignatureWord(data, child + 4, bigEndian: true))
            guard length >= 8, installedSignatureFits(offset, length, in: blobLength) else {
                throw InstalledSignatureObservationError.invalid("malformed_signature")
            }
            regions.append((offset, offset + length))
            if type == 5 {
                guard !xmlPresent, magic == 0xfade7171, length > 8 else {
                    throw InstalledSignatureObservationError.invalid("malformed_signature")
                }
                xmlPresent = true
                xmlPayload = (child + 8)..<(child + length)
            } else if type == 7 {
                guard !derPresent, magic == 0xfade7172, length > 8 else {
                    throw InstalledSignatureObservationError.invalid("malformed_signature")
                }
                derPresent = true
            }
        }
        regions.sort { $0.start < $1.start }
        var previousEnd = indexEnd
        for region in regions {
            guard region.start >= previousEnd else { throw InstalledSignatureObservationError.invalid("malformed_signature") }
            previousEnd = region.end
        }
        guard let payload = xmlPayload else {
            return result(derPresent ? "der_only_unparsed" : "no_entitlement_slots")
        }
        var format = PropertyListSerialization.PropertyListFormat.xml
        let decoded: Any
        do {
            decoded = try PropertyListSerialization.propertyList(from: data.subdata(in: payload), options: [], format: &format)
        } catch {
            return result("malformed_xml_entitlements")
        }
        guard format == .xml, let dictionary = decoded as? [String: Any] else {
            return result("malformed_xml_entitlements")
        }
        guard let rawGroups = dictionary["com.apple.security.application-groups"] else {
            return result(derPresent ? "xml_key_absent_der_unverified" : "xml_key_absent")
        }
        guard let groups = rawGroups as? [String] else { return result("xml_groups_wrong_type") }
        // Bound diagnostic output without logging any other entitlement values.
        guard groups.count <= 128, groups.allSatisfy({ $0.utf8.count <= 1024 }) else {
            return result("xml_groups_output_limit")
        }
        if derPresent { return result("xml_extracted_der_unverified", groups: groups) }
        return result(groups.isEmpty ? "xml_groups_empty" : "xml_groups_extracted", groups: groups)
    } catch let error as InstalledSignatureObservationError {
        switch error {
        case .invalid(let status): return result(status)
        }
    } catch {
        return result("malformed_signature")
    }
}

private static func installedSignatureFits(_ offset: Int, _ length: Int, in limit: Int) -> Bool {
    return offset >= 0 && length >= 0 && offset <= limit && length <= limit - offset
}

private static func installedSignatureWord(_ data: Data, _ offset: Int, bigEndian: Bool) throws -> UInt32 {
    guard installedSignatureFits(offset, 4, in: data.count) else {
        throw InstalledSignatureObservationError.invalid("malformed_signature")
    }
    let first = UInt32(data[offset])
    let second = UInt32(data[offset + 1])
    let third = UInt32(data[offset + 2])
    let fourth = UInt32(data[offset + 3])
    return bigEndian ? (first << 24 | second << 16 | third << 8 | fourth)
                     : (first | second << 8 | third << 16 | fourth << 24)
}
