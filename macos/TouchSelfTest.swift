import Foundation

// Runs only pure parsing/state transitions. Never posts OS input during tests.
func touchSelfTest() throws {
    func check(_ value: Bool, _ name: String) throws { if !value { throw BridgeError(AppMessage(raw: "Touch: " + name)) } }
    func packet(_ phase: String, _ epoch: Int, x: Any = 0.5, y: Any = 0.5) throws -> TouchPacket {
        try TouchPacket(["type": "touch", "phase": phase, "epoch": epoch, "x": x, "y": y, "dx": 0.25, "dy": -0.5])
    }
    var gate = TouchGate()
    let bounds = CGRect(x: -1600, y: -500, width: 1600, height: 1068)
    try check(gate.accept(try packet("down", 1), bounds: bounds).isEmpty, "off by default")
    _ = gate.setEnabled(true)
    let down = gate.accept(try packet("down", gate.epoch, x: 0, y: 1), bounds: bounds)
    try check(down == [TouchEffect(kind: .down, point: CGPoint(x: -1600, y: 567))], "HiDPI, negative origins and exclusive edge")
    let previousEpoch = gate.epoch
    try check(gate.setEnabled(false) == [TouchEffect(kind: .up, point: down[0].point)], "off releases held mouse")
    _ = gate.setEnabled(true)
    try check(gate.accept(try packet("down", previousEpoch), bounds: bounds).isEmpty, "old enabled epoch is revoked after re-enable")
    try check(gate.accept(try packet("move", gate.epoch), bounds: bounds).isEmpty, "orphan move ignored")
    try check(gate.accept(try packet("up", gate.epoch), bounds: bounds).isEmpty, "orphan up ignored")
    _ = gate.accept(try packet("down", gate.epoch), bounds: bounds)
    try check(gate.accept(try packet("cancel", gate.epoch), bounds: bounds).count == 1 && gate.pressed == nil, "cancel releases")
    try check(gate.release().isEmpty, "release is idempotent")
    let scroll = gate.accept(try packet("scroll", gate.epoch), bounds: bounds)
    try check(scroll.first?.scroll == CGPoint(x: 400, y: -534), "scroll uses logical desktop points")
    _ = gate.accept(try packet("down", gate.epoch), bounds: bounds)
    try check(gate.accept(try packet("move", gate.epoch), bounds: .null).first?.kind == .up, "lost display releases")
    for bad: Any in [true, "0.5", -0.01, 1.01, Double.nan, Double.infinity] {
        do { _ = try packet("click", gate.epoch, x: bad); throw NSError(domain: "accepted invalid coordinate", code: 1) }
        catch is BridgeError { }
    }
    for bad: Any in [true, -1, 0, 0.5, Double(Int32.max) + 1, "1"] {
        do { _ = try TouchPacket(["phase": "cancel", "epoch": bad]); throw NSError(domain: "accepted invalid epoch", code: 1) }
        catch is BridgeError { }
    }
    do { _ = try packet("key", gate.epoch); throw NSError(domain: "accepted unknown input", code: 1) } catch is BridgeError { }
    _ = gate.setEnabled(true, trackpad: true)
    let cursor = CGPoint(x: 100, y: 200)
    let hover = gate.accept(try packet("hover", gate.epoch), bounds: bounds, cursor: cursor)
    try check(hover.first?.kind == .hover && hover.first?.point == CGPoint(x: 500, y: -334), "relative movement uses current cursor")
    _ = gate.accept(try packet("end", gate.epoch), bounds: bounds)
    try check(gate.accept(try packet("rightclick", gate.epoch), bounds: bounds, cursor: cursor).first?.point == cursor, "relative right click keeps cursor")
    try check(gate.accept(try packet("mission-control", gate.epoch), bounds: bounds).first?.kind == .missionControl, "trackpad finite shortcut")
    _ = gate.setEnabled(true)
    try check(gate.accept(try packet("mission-control", gate.epoch), bounds: bounds).isEmpty, "direct mode rejects system shortcut")
    try check(gate.accept(try packet("hover", gate.epoch), bounds: bounds).isEmpty, "direct mode rejects relative hover")
    _ = gate.setEnabled(true, trackpad: true)
    _ = gate.accept(try packet("begin", gate.epoch), bounds: bounds, cursor: cursor)
    _ = gate.accept(try packet("down", gate.epoch), bounds: bounds, cursor: cursor)
    for _ in 0..<2 { _ = gate.accept(try packet("move", gate.epoch), bounds: bounds, cursor: cursor) }
    let up = gate.accept(try packet("up", gate.epoch), bounds: bounds, cursor: cursor)
    try check(up.first?.point == CGPoint(x: 900, y: -868), "burst moves accumulate despite stale system cursor; UP does not jump")
    _ = gate.setEnabled(true)
    let directOrigin = CGPoint(x: -800.5, y: 33.5)
    try check(gate.accept(try packet("begin", gate.epoch), bounds: bounds) ==
              [TouchEffect(kind: .hover, point: directOrigin)], "two-finger direct begin positions without clicking")
    for phase in ["zoom-in", "zoom-out"] {
        let expected: TouchEffect.Kind = phase == "zoom-in" ? .zoomIn : .zoomOut
        try check(gate.accept(try packet(phase, gate.epoch), bounds: bounds) ==
                  [TouchEffect(kind: expected, point: directOrigin)], "direct pinch supports " + phase)
        try check(gate.accept(try packet(phase, gate.epoch - 1), bounds: bounds).isEmpty, "stale pinch rejected")
    }
    _ = gate.accept(try packet("down", gate.epoch), bounds: bounds)
    try check(gate.accept(try packet("zoom-in", gate.epoch), bounds: bounds).isEmpty, "pinch cannot fire while dragging")
    try check(gate.accept(try packet("begin", gate.epoch), bounds: bounds).map { $0.kind } == [.up, .hover], "new direct gesture releases interrupted drag before positioning")
    for _ in 0..<3 {
        try check(gate.accept(try packet("scroll", gate.epoch), bounds: bounds).first?.point == directOrigin,
                  "anchored direct scroll holds pointer steady")
    }
    _ = gate.setEnabled(true, trackpad: true)
    _ = gate.accept(try packet("begin", gate.epoch), bounds: bounds, cursor: cursor)
    for phase in ["scroll", "zoom-in", "zoom-out"] {
        try check(gate.accept(try packet(phase, gate.epoch, x: 0.9, y: 0.1), bounds: bounds).first?.point == cursor,
                  "trackpad " + phase + " preserves the Mac cursor")
    }
    _ = gate.setEnabled(false)
    try check(gate.accept(try packet("zoom-in", gate.epoch), bounds: bounds).isEmpty, "disabled pinch rejected")
    print("PASS: touch authorization epochs, release lifecycle, coordinate bounds, anchored scroll, pinch and malformed input rejection")
}
