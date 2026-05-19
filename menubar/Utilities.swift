import Foundation

// MARK: - Shared Helpers

func toLatin(_ s: String) -> String {
    let mutable = NSMutableString(string: s)
    CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
    CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
    return (mutable as String).lowercased()
}

func instanceIdSuffix(_ id: String) -> String {
    id.split(separator: "-", maxSplits: 1).last.map(String.init) ?? id
}

func augmentedEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    let extra = "/opt/homebrew/bin:/usr/local/bin:\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin"
    if let existing = env["PATH"] {
        env["PATH"] = "\(extra):\(existing)"
    } else {
        env["PATH"] = "\(extra):/usr/bin:/bin"
    }
    env["PYTHONIOENCODING"] = "utf-8"
    return env
}

// MARK: - Validation

private let uuidRegex = try! NSRegularExpression(
    pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)

func isValidUUID(_ s: String) -> Bool {
    let range = NSRange(s.startIndex..<s.endIndex, in: s)
    return uuidRegex.firstMatch(in: s, range: range) != nil
}
