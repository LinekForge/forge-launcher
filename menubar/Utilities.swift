import Foundation

// MARK: - Shared Helpers

func toLatin(_ s: String) -> String {
    let mutable = NSMutableString(string: s)
    CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
    CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
    return (mutable as String).lowercased()
}

/// Hub instance ID 格式为 `<prefix>-<PID>`（如 "forge-12345"），提取最后一个 `-` 之后的部分。
func instanceIdSuffix(_ id: String) -> String {
    guard let idx = id.lastIndex(of: "-") else { return id }
    return String(id[id.index(after: idx)...])
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

func isValidUUID(_ s: String) -> Bool {
    UUID(uuidString: s) != nil
}
