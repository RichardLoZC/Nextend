import AppKit
import ApplicationServices

// Isolated test windows: no user application content is inspected or changed.
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let name = CommandLine.arguments[2]
let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
let app = NSApplication.shared
app.setActivationPolicy(.regular)
func record(_ row: [String: Any]) {
    let url = folder.appendingPathComponent(name + ".events")
    let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([10])
    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
    let handle = try! FileHandle(forWritingTo: url); defer { try? handle.close() }
    try! handle.seekToEnd(); try! handle.write(contentsOf: data)
}
var windows = [NSWindow]()
let frames = name == "A" ? [CGRect(x: 70, y: 200, width: 500, height: 300)] :
    [CGRect(x: 950, y: 120, width: 500, height: 300), CGRect(x: 950, y: 650, width: 500, height: 300)]
var centers = [[String: Any]]()
for (index, frame) in frames.enumerated() {
    let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Nextend zoom fixture " + name + String(index + 1)
    window.isReleasedWhenClosed = false
    window.contentView = NSTextField(labelWithString: window.title)
    window.makeKeyAndOrderFront(nil); windows.append(window)
    centers.append(["x": frame.midX, "y": primaryHeight - frame.midY, "title": window.title])
}
let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
    if event.modifierFlags.contains(.command) && [24, 27].contains(Int(event.keyCode)) {
        record(["type": "zoom", "key": Int(event.keyCode), "window": event.window?.title ?? app.keyWindow?.title ?? "unknown"])
        return nil
    }
    return event
}
app.activate(ignoringOtherApps: true)
record(["type": "ready", "pid": ProcessInfo.processInfo.processIdentifier, "windows": centers])
let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
    if FileManager.default.fileExists(atPath: folder.appendingPathComponent("stop").path) { app.terminate(nil) }
}
app.run()
