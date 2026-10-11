import Foundation
import Testing
@testable import ConfCore

/// Cases from the official yaml-test-suite (release data-2022-01-17), in `Fixtures/yaml/`.
///
/// Each case is classified by the reference parser's events (`test.event`) and by its text:
/// - **error**: the suite says the YAML is invalid (`error` file) — must be rejected;
/// - **outside** the subset: anchor, alias, tag, multiple documents, directive, complex
///   key (`? ` or a collection as key), empty or null key, `<<` merge — must be
///   rejected (preferably with `outsideSubset`) or read the same as `in.json`;
/// - **inside**: everything else — must be read the same as `in.json`.
enum YAMLSuite {
    static let folder = Suite.folder.appendingPathComponent("yaml")

    static let cases: [String] = ((try? FileManager.default.subpathsOfDirectory(atPath: folder.path)) ?? [])
        .filter { ($0 as NSString).lastPathComponent == "in.yaml" }
        .map { ($0 as NSString).deletingLastPathComponent }
        .sorted()

    static func file(_ testCase: String, _ name: String) -> Data? {
        try? Data(contentsOf: folder.appendingPathComponent(testCase).appendingPathComponent(name))
    }

    static func bytes(_ testCase: String) -> [UInt8] { [UInt8](file(testCase, "in.yaml")!) }

    enum Category: String { case error, outside, inside }

    /// Why the case is outside the subset (`nil` if it is inside).
    static func outsideReason(_ testCase: String) -> String? {
        let events = String(decoding: file(testCase, "test.event") ?? Data(), as: UTF8.self)
            .split(separator: "\n").map(String.init)
        let yaml = String(decoding: bytes(testCase), as: UTF8.self)
        if events.filter({ $0.hasPrefix("+DOC") }).count > 1 { return "multiple documents" }
        if events.contains(where: { $0.hasPrefix("=ALI") }) { return "alias" }
        // stack: in each map, the children alternate between key and value
        var stack: [(map: Bool, n: Int)] = []
        for ev in events {
            let parts = ev.split(separator: " ", maxSplits: 1).map(String.init)
            let kind = parts[0]
            let rest = parts.count > 1 ? parts[1] : ""
            if ["+MAP", "+SEQ", "=VAL"].contains(kind) {
                var props = rest
                if kind == "+MAP" || kind == "+SEQ" { props = props.replacingOccurrences(of: "{}", with: "").replacingOccurrences(of: "[]", with: "") }
                // properties come before the value: `&anchor`, `<tag>`
                var r = Substring(props)
                while r.hasPrefix(" ") { r = r.dropFirst() }
                while r.hasPrefix("&") || r.hasPrefix("<") {
                    if r.hasPrefix("&") { return "anchor" }
                    return "tag"
                }
                let isKey = stack.last.map { $0.map && $0.n % 2 == 0 } ?? false
                if isKey {
                    if kind != "=VAL" { return "complex key" }
                    if r.hasPrefix(":") {
                        let k = String(r.dropFirst())
                        if k == "<<" { return "merge" }
                        if case .null = YAMLReader.resolver(k) { return "empty or null key" }
                    }
                }
                if !stack.isEmpty { stack[stack.count - 1].n += 1 }
                if kind != "=VAL" { stack.append((kind == "+MAP", 0)) }
            } else if kind == "-MAP" || kind == "-SEQ" {
                stack.removeLast()
            }
        }
        for l in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            if l.hasPrefix("%") { return "directive" }
            let t = l.drop { $0 == " " || $0 == "-" || $0 == "\t" }
            if t == "?" || t.hasPrefix("? ") || t.hasPrefix("?\t") { return "complex key" }
            if l.contains("[? ") || l.contains("{? ") || l.contains(", ? ") { return "complex key" }
        }
        return nil
    }

    static func category(_ testCase: String) -> Category {
        if file(testCase, "error") != nil { return .error }
        return outsideReason(testCase) == nil ? .inside : .outside
    }

    static let inside = cases.filter { category($0) == .inside }
    static let outside = cases.filter { category($0) == .outside }
    static let errors = cases.filter { category($0) == .error }

    /// Cases inside the subset that Konfig rejects, each with its reason. Must stay
    /// empty or with a documented reason (the test checks both directions).
    static let rejectedInside: [String: String] = [:]

    /// Expected value from `in.json`. `nil` if the case has none (the suite gives no JSON for it).
    static func expected(_ testCase: String) -> Any?? {
        guard let d = file(testCase, "in.json") else { return .none }
        if d.allSatisfy({ $0 == 0x20 || $0 == 0x0A }) { return .some(nil) }        // no document
        return .some(try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]))
    }
}

/// Compares the value read with the suite's JSON (numbers by value).
enum CompareYAML {
    static func value(_ v: Value, _ j: Any, _ place: String) -> [String] {
        if let x = CompareJSON.boolean(j) {
            if case .boolean(let b) = v, b == x { return [] }
            return ["\(place): expected \(x), got \(v)"]
        }
        switch j {
        case is NSNull:
            if case .null = v { return [] }
            return ["\(place): expected null, got \(v)"]
        case let n as NSNumber:
            switch v {
            case .integer(let x): return Double(x) == n.doubleValue ? [] : ["\(place): \(x) ≠ \(n)"]
            case .decimal(let x): return x == n.doubleValue ? [] : ["\(place): \(x) ≠ \(n)"]
            default: return ["\(place): expected number \(n), got \(v)"]
            }
        case let s as String:
            if case .text(let t) = v, (t as NSString).isEqual(to: s) { return [] }
            return ["\(place): expected \(s.debugDescription), got \(v)"]
        case let a as [Any]:
            guard case .array(let l) = v else { return ["\(place): expected array, got \(v)"] }
            guard l.count == a.count else { return ["\(place): \(l.count) items, expected \(a.count)"] }
            return zip(l, a).enumerated().flatMap { i, p in value(p.0, p.1, "\(place)[\(i)]") }
        case let d as NSDictionary:
            guard case .table(let t) = v else { return ["\(place): expected map, got \(v)"] }
            var r: [String] = []
            if d.count != t.pairs.count { r.append("\(place): \(t.pairs.count) keys, expected \(d.count)") }
            for case let (k as NSString, x) in d {
                guard let pair = t.pairs.first(where: { ($0.key as NSString).isEqual(to: k as String) }) else {
                    r.append("\(place): missing key \(k)")
                    continue
                }
                r += value(pair.value, x, place + "." + (k as String))
            }
            return r
        default:
            return ["\(place): unexpected JSON"]
        }
    }
}

@Test func yamlSuiteHasTheCases() {
    #expect(YAMLSuite.cases.count == 402)
    #expect(YAMLSuite.inside.count + YAMLSuite.outside.count + YAMLSuite.errors.count == 402)
    // the counts go into the report (swift test shows the print output)
    print("yaml-test-suite: \(YAMLSuite.cases.count) cases; inside \(YAMLSuite.inside.count), outside \(YAMLSuite.outside.count), error \(YAMLSuite.errors.count)")
    var reasons: [String: Int] = [:]
    for c in YAMLSuite.outside { reasons[YAMLSuite.outsideReason(c)!, default: 0] += 1 }
    print("outside the subset, by reason: \(reasons.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
}

@Test(arguments: YAMLSuite.inside)
func yamlInside(_ testCase: String) throws {
    let doc: ConfDocument
    do { doc = try YAMLReader.parse(YAMLSuite.bytes(testCase)) } catch {
        if let reason = YAMLSuite.rejectedInside[testCase] {
            print("inside and rejected \(testCase): \(reason)")
            return
        }
        Issue.record("rejected a case inside the subset: \(error)")
        return
    }
    #expect(YAMLSuite.rejectedInside[testCase] == nil, "accepted now: remove it from rejectedInside")
    switch YAMLSuite.expected(testCase) {
    case .none:
        break                                                               // the suite gives no JSON
    case .some(nil):
        #expect(doc.empty, "expected a file with no document")
    case .some(let j?):
        let d = CompareYAML.value(doc.rootValue, j, "")
        #expect(d.isEmpty, "\(d.prefix(5).joined(separator: "\n"))")
    }
}

@Test(arguments: YAMLSuite.outside)
func yamlOutside(_ testCase: String) throws {
    let doc: ConfDocument
    do { doc = try YAMLReader.parse(YAMLSuite.bytes(testCase)) } catch {
        return                                                              // rejected: as expected
    }
    // accepted: only fine if the values match in.json
    switch YAMLSuite.expected(testCase) {
    case .none:
        Issue.record("outside the subset (\(YAMLSuite.outsideReason(testCase)!)), accepted with no JSON to check against")
    case .some(nil):
        #expect(doc.empty)
    case .some(let j?):
        let d = CompareYAML.value(doc.rootValue, j, "")
        #expect(d.isEmpty, "outside the subset (\(YAMLSuite.outsideReason(testCase)!)), accepted with different values: \(d.prefix(5).joined(separator: "\n"))")
    }
}

@Test(arguments: YAMLSuite.errors)
func yamlError(_ testCase: String) {
    do {
        let doc = try YAMLReader.parse(YAMLSuite.bytes(testCase))
        Issue.record("accepted an invalid case: \(doc.rootValue)")
    } catch {
        #expect(error.line >= 1 && error.column >= 1)
    }
}

/// Counts for the report: how many cases of each class were accepted or rejected, and how.
@Test func yamlSuiteCounts() {
    var insideAccepted = 0, insideRejected = 0
    for c in YAMLSuite.inside { if (try? YAMLReader.parse(YAMLSuite.bytes(c))) != nil { insideAccepted += 1 } else { insideRejected += 1 } }
    var outsideAsOutside = 0, outsideAsError = 0, outsideAccepted = 0
    for c in YAMLSuite.outside {
        do { _ = try YAMLReader.parse(YAMLSuite.bytes(c)); outsideAccepted += 1 } catch {
            if error.outsideSubset { outsideAsOutside += 1 } else { outsideAsError += 1 }
        }
    }
    var errorsRejected = 0, errorsAsOutside = 0
    for c in YAMLSuite.errors {
        do { _ = try YAMLReader.parse(YAMLSuite.bytes(c)) } catch {
            errorsRejected += 1
            if error.outsideSubset { errorsAsOutside += 1 }
        }
    }
    print("""
        yaml-test-suite — inside: \(YAMLSuite.inside.count) (accepted \(insideAccepted), rejected \(insideRejected)); \
        outside: \(YAMLSuite.outside.count) (rejected as outside the subset \(outsideAsOutside), rejected as error \(outsideAsError), \
        accepted with the in.json values \(outsideAccepted)); error: \(YAMLSuite.errors.count) (rejected \(errorsRejected), \
        of which \(errorsAsOutside) via the outside-the-subset notice)
        """)
    #expect(insideRejected == YAMLSuite.rejectedInside.count)
    #expect(errorsRejected == YAMLSuite.errors.count)
}

/// Broken input must not hang or go out of bounds: every prefix of every case, and every
/// case with one byte removed, is read (accepted or rejected) without a runtime error.
@Test func yamlReaderIsRobust() {
    var readCount = 0
    for c in YAMLSuite.cases {
        let bytes = YAMLSuite.bytes(c)
        for n in 0..<bytes.count {
            _ = try? YAMLReader.parse(Array(bytes.prefix(n)))
            var without = bytes
            without.remove(at: n)
            _ = try? YAMLReader.parse(without)
            readCount += 2
        }
    }
    #expect(readCount > 10_000)
}
