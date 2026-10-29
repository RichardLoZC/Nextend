// Concatenate after the unmodified production TouchInput/TouchZoomTarget sources.
// Only error/log plumbing is stubbed; the real controller posts to test windows.
struct BridgeError: Error { init(_ text: String) {} }
enum Diagnostics { static func event(_ name: String) {} }
let testFolder = URL(fileURLWithPath: CommandLine.arguments[1])
func rows(_ name: String) -> [[String: Any]] {
    let text = (try? String(contentsOf: testFolder.appendingPathComponent(name + ".events"))) ?? ""
    return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
}
func wait(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
let readyA = rows("A").first { $0["type"] as? String == "ready" }!
let readyB = rows("B").first { $0["type"] as? String == "ready" }!
let pidA = pid_t(readyA["pid"] as! Int), pidB = pid_t(readyB["pid"] as! Int)
let targets = readyB["windows"] as! [[String: Any]]
let bounds = CGDisplayBounds(CGMainDisplayID())
let controller = TouchInputController()
controller.attach(display: CGMainDisplayID())
var mode = controller.setEnabled(true)
check(mode["enabled"] as? Bool == true, "test interpreter requires existing Accessibility authorization")
func send(_ phase: String, _ target: [String: Any], dx: Double = 0, dy: Double = 0) throws {
    try controller.receive(["phase": phase, "epoch": mode["epoch"] as! Int,
        "x": ((target["x"] as! Double) - bounds.minX) / (bounds.width - 1),
        "y": ((target["y"] as! Double) - bounds.minY) / (bounds.height - 1), "dx": dx, "dy": dy])
}
defer { controller.close(); try? Data().write(to: testFolder.appendingPathComponent("stop")) }
_ = NSRunningApplication(processIdentifier: pidA)?.activate(options: []); wait(0.2)
try send("begin", targets[0]); wait(0.1)
let anchor = CGEvent(source: nil)!.location
try send("scroll", targets[0], dy: 0.05); wait(0.1)
let afterScroll = CGEvent(source: nil)!.location
check(hypot(anchor.x - afterScroll.x, anchor.y - afterScroll.y) < 1, "scroll moved the anchored pointer")
try send("zoom-in", targets[0]); wait(0.6)
let first = rows("B").filter { $0["type"] as? String == "zoom" }
check(first.count == 1 && first[0]["window"] as? String == targets[0]["title"] as? String, "wrong cross-application zoom target")
check(rows("A").filter { $0["type"] as? String == "zoom" }.isEmpty, "unrelated foreground app received zoom")
if let second = TouchZoomTarget.resolve(at: CGPoint(x: targets[1]["x"] as! Double, y: targets[1]["y"] as! Double)) {
    _ = second.requestFocus(); wait(0.2)
}
try send("begin", targets[0]); try send("zoom-out", targets[0]); wait(0.6)
let both = rows("B").filter { $0["type"] as? String == "zoom" }
check(both.count == 2 && both.allSatisfy { $0["window"] as? String == targets[0]["title"] as? String }, "wrong window within same application")
// Pause only our child fixture so target resolution cannot finish before revoke.
kill(pidB, SIGSTOP)
try send("begin", targets[0]); try send("zoom-in", targets[0]); wait(0.005)
let a = (readyA["windows"] as! [[String: Any]])[0]
try send("down", a)
kill(pidB, SIGCONT); wait(0.3)
try send("up", a)
check(rows("B").filter { $0["type"] as? String == "zoom" }.count == 2, "old zoom survived new drag")
kill(pidB, SIGSTOP)
try send("begin", targets[0]); try send("zoom-in", targets[0]); wait(0.005)
mode = controller.setEnabled(false)
kill(pidB, SIGCONT); wait(0.3)
check(rows("B").filter { $0["type"] as? String == "zoom" }.count == 2, "disabled touch still posted zoom")
let report: [String: Any] = ["passed": true, "pointerFixedDuringScroll": true, "crossApplicationTarget": true,
    "sameApplicationWindowTarget": true, "newDragRevokesQueuedZoom": true, "disabledRevokesQueuedZoom": true]
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: testFolder.appendingPathComponent("result.json"))
print("PASS: fixed pointer, cross-app/same-app window zoom, new-drag and disabled-input revocation")
