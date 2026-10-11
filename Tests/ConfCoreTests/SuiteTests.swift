import Foundation
import Testing
@testable import ConfCore

/// Cases from the official toml-test suite (TOML 1.0), copied into `Fixtures/`.
enum Suite {
    static let folder: URL = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!

    /// Paths relative to `folder`. Built from `subpathsOfDirectory` rather than by trimming
    /// absolute paths, which breaks when the bundle path goes through a symlink (/tmp → /private/tmp).
    static func cases(_ sub: String) -> [String] {
        let root = folder.appendingPathComponent(sub)
        return ((try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? [])
            .filter { ($0 as NSString).pathExtension == "toml" }
            .map { sub + "/" + $0 }
            .sorted()
    }

    static let valids = cases("valid")
    static let invalids = cases("invalid")

    static func bytes(_ testCase: String) -> [UInt8] {
        Array(try! Data(contentsOf: folder.appendingPathComponent(testCase)))
    }
}

@Test func suiteHasTheCases() {
    #expect(Suite.valids.count == 208)
    #expect(Suite.invalids.count == 501)
}

@Test(arguments: Suite.valids)
func validCase(_ testCase: String) throws {
    let doc: ConfDocument
    do { doc = try TOMLReader.parse(Suite.bytes(testCase)) } catch {
        Issue.record("rejected a valid case: \(error)")
        return
    }
    let jsonURL = Suite.folder.appendingPathComponent(String(testCase.dropLast(5)) + ".json")
    let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL), options: [.fragmentsAllowed])
    let diffs = Compare.table(doc.root, expected, "")
    #expect(diffs.isEmpty, "\(diffs.prefix(5).joined(separator: "\n"))")
}

@Test(arguments: Suite.invalids)
func invalidCase(_ testCase: String) {
    do {
        let doc = try TOMLReader.parse(Suite.bytes(testCase))
        Issue.record("accepted an invalid case: \(doc.root)")
    } catch {
        #expect(error.line >= 1 && error.column >= 1)
    }
}

/// Compares the structure read with the suite's JSON (same rules as toml-test:
/// floats by value, dates by instant).
enum Compare {
    static func table(_ t: Table, _ j: Any, _ place: String) -> [String] {
        guard let obj = j as? NSDictionary else { return ["\(place): expected object"] }
        var r: [String] = []
        if obj.count != t.pairs.count {
            r.append("\(place): \(t.pairs.count) keys, expected \(obj.count)")
        }
        for case let (k as NSString, v) in obj {
            let ks = k as String
            guard let pair = t.pairs.first(where: { ($0.key as NSString).isEqual(to: ks) }) else {
                r.append("\(place): missing key \(ks)")
                continue
            }
            r += value(pair.value, v, place + "." + ks)
        }
        return r
    }

    static func value(_ v: Value, _ j: Any, _ place: String) -> [String] {
        if let arr = j as? [Any] {
            guard case .array(let l) = v else { return ["\(place): expected array, got \(v.kind)"] }
            guard l.count == arr.count else { return ["\(place): \(l.count) items, expected \(arr.count)"] }
            return zip(l, arr).enumerated().flatMap { i, p in value(p.0, p.1, "\(place)[\(i)]") }
        }
        guard let obj = j as? NSDictionary else { return ["\(place): unexpected JSON"] }
        guard let kind = obj["type"] as? String, let text = obj["value"] as? String, obj.count == 2 else {
            if case .table(let t) = v { return table(t, obj, place) }
            return ["\(place): expected table, got \(v.kind)"]
        }
        switch (kind, v) {
        case ("string", .text(let s)):
            return (s as NSString).isEqual(to: text) ? [] : ["\(place): string \(s.debugDescription) ≠ \(text.debugDescription)"]
        case ("integer", .integer(let n)):
            return String(n) == text ? [] : ["\(place): \(n) ≠ \(text)"]
        case ("float", .decimal(let d)):
            if text.lowercased().hasSuffix("nan") { return d.isNaN ? [] : ["\(place): \(d) ≠ nan"] }
            let e: Double = text == "inf" || text == "+inf" ? .infinity : text == "-inf" ? -.infinity : Double(text)!
            return d == e ? [] : ["\(place): \(d) ≠ \(text)"]
        case ("bool", .boolean(let b)):
            return String(b) == text ? [] : ["\(place): \(b) ≠ \(text)"]
        case ("datetime", .dateTime(let dh)) where dh.kind == .withOffset,
             ("datetime-local", .dateTime(let dh)) where dh.kind == .local,
             ("date-local", .dateTime(let dh)) where dh.kind == .date,
             ("time-local", .dateTime(let dh)) where dh.kind == .time:
            guard let a = Instant(dh.iso, dh.kind), let b = Instant(text, dh.kind) else {
                return ["\(place): unreadable date \(dh.iso) / \(text)"]
            }
            return a == b ? [] : ["\(place): \(dh.iso) ≠ \(text)"]
        default:
            return ["\(place): type \(v.kind) ≠ \(kind)"]
        }
    }
}

/// Independent RFC 3339 reader for comparing dates (absolute instant when there is an offset).
struct Instant: Equatable {
    var seconds: Int64
    var nanos: Int

    init?(_ s0: String, _ kind: DateTime.Kind) {
        let s = Array(s0.replacingOccurrences(of: " ", with: "T").replacingOccurrences(of: "t", with: "T")
            .replacingOccurrences(of: "z", with: "Z").utf8)
        func n(_ i: Int, _ k: Int) -> Int? {
            guard i + k <= s.count else { return nil }
            var v = 0
            for c in s[i..<(i + k)] { guard c >= 48 && c <= 57 else { return nil }; v = v * 10 + Int(c - 48) }
            return v
        }
        var i = 0
        var y = 1970, mo = 1, d = 1, h = 0, mi = 0, sec = 0, ns = 0, off = 0
        if kind != .time {
            guard let a = n(0, 4), let b = n(5, 2), let c = n(8, 2) else { return nil }
            y = a; mo = b; d = c; i = 10
            if kind != .date { i += 1 }
        }
        if kind != .date {
            guard let a = n(i, 2), let b = n(i + 3, 2), let c = n(i + 6, 2) else { return nil }
            h = a; mi = b; sec = c; i += 8
            if i < s.count, s[i] == 46 {
                i += 1
                var digitStr = ""
                while i < s.count, s[i] >= 48, s[i] <= 57 { digitStr.append(Character(UnicodeScalar(s[i]))); i += 1 }
                digitStr = String((digitStr + "000000000").prefix(9))
                ns = Int(digitStr)!
            }
            if kind == .withOffset {
                guard i < s.count else { return nil }
                if s[i] == 90 { i += 1 } else {
                    guard let a = n(i + 1, 2), let b = n(i + 4, 2) else { return nil }
                    off = (a * 60 + b) * (s[i] == 45 ? -1 : 1)
                    i += 6
                }
            }
        }
        guard i == s.count else { return nil }
        // days since 1970-01-01 (Howard Hinnant's algorithm)
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468
        seconds = Int64(days) * 86400 + Int64(h * 3600 + mi * 60 + sec) - Int64(off * 60)
        nanos = ns
    }
}
