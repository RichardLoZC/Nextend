import Foundation

func diagnosticsSelfTest() throws {
    func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "Nextend.DiagnosticsTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("nextend-diagnostic-test-" + UUID().uuidString + ".noindex")
    defer { try? fm.removeItem(at: root) }
    let logs = root.appendingPathComponent("logs")
    let first = DiagnosticJournal(directory: logs, limit: 4096)
    let second = DiagnosticJournal(directory: logs, limit: 4096)
    DispatchQueue.concurrentPerform(iterations: 1000) { index in
        (index % 2 == 0 ? first : second).record("load", fields: ["index": index, "message": String(repeating: "x", count: 200)])
    }
    try require(first.flush() && second.flush(), "concurrent writers did not drain")
    let active = logs.appendingPathComponent("events.jsonl")
    try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: active.path)
    first.record("unwritable")
    try require(first.flush(), "a read-only file stalled logging")
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: active.path)
    let partialText = "{\"event\":\"padding\",\"message\":\"" + String(repeating: "x", count: 3900) + "\"}\n{\"incomplete"
    try Data(partialText.utf8).write(to: active)
    first.record("privacy", fields: ["message": "quote \" newline\n用户 192.168.2.42 /Users/private/file token=do-not-export device 'ABCDEF0123456789'",
        "password": "do-not-export", "number": Double.nan])
    try require(first.flush(), "privacy record did not drain")
    try Data("PAIRING-SECRET".utf8).write(to: logs.appendingPathComponent("pairing.key"))
    let export = root.appendingPathComponent("snapshot")
    try first.snapshot(to: export)
    let files = try fm.contentsOfDirectory(at: export, includingPropertiesForKeys: nil)
    try require(!files.isEmpty && files.count <= 5, "rotation or export allowlist failed")
    let health = try JSONSerialization.jsonObject(with: Data(contentsOf: export.appendingPathComponent("storage-status.json"))) as! [String: Any]
    try require((health["writeFailures"] as? Int ?? 0) > 0, "export hid a write failure")
    var found = false
    for file in files {
        let data = try Data(contentsOf: file)
        try require(data.count <= 4096, "storage exceeded the file limit")
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            if row["event"] as? String == "privacy" {
                found = true
                let fields = row["details"] as! [String: Any]
                let text = fields["message"] as! String
                try require(text.contains("用户") && text.contains("\n"), "Unicode or newline was corrupted")
                try require(!text.contains("192.168.2.42") && !text.contains("/Users/private") && !text.contains("do-not-export") && !text.contains("ABCDEF0123456789") && fields["password"] == nil, "redaction failed")
            }
        }
    }
    try require(found, "the last record was lost")
    let bad = root.appendingPathComponent("not-a-directory")
    try Data().write(to: bad)
    let broken = DiagnosticJournal(directory: bad)
    broken.record("storage-failure")
    try require(broken.flush(), "storage failure blocked the writer")
    do { try broken.snapshot(to: root.appendingPathComponent("bad-export")); throw NSError(domain: "expected snapshot failure", code: 1) }
    catch let error as NSError { try require(error.domain != "expected snapshot failure", "export falsely reported success") }
    print("PASS: diagnostic concurrent rotation, JSON validity, export allowlist, privacy, storage failure isolation")
}
