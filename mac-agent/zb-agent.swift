import Foundation
import AppKit
import Quartz
import Network

// ── Helpers ───────────────────────────────────────

func jsonString(_ obj: Any) -> String? {
    if let data = try? JSONSerialization.data(withJSONObject: obj),
       let str = String(data: data, encoding: .utf8) {
        return str
    }
    return nil
}

func jsonPrint(_ obj: Any) {
    if let str = jsonString(obj) {
        print(str)
    }
}

func errorPrint(_ msg: String) -> Never {
    fputs("{\"error\":\"\(msg)\"}\n", stderr)
    exit(1)
}

func log(_ msg: String) {
    let df = DateFormatter()
    df.dateFormat = "HH:mm:ss.SSS"
    fputs("[\(df.string(from: Date()))] \(msg)\n", stderr)
}

// ── Commands (return dictionaries) ────────────────

func getCursorResult() -> [String: Any] {
    let loc = NSEvent.mouseLocation
    return [
        "type": "cursor_pos",
        "x": round(loc.x * 10) / 10,
        "y": round(loc.y * 10) / 10
    ]
}

func getScreensResult() -> [String: Any] {
    var screens: [[String: Any]] = []
    for (i, screen) in NSScreen.screens.enumerated() {
        let f = screen.frame
        screens.append([
            "id": i,
            "x": Int(f.origin.x),
            "y": Int(f.origin.y),
            "w": Int(f.size.width),
            "h": Int(f.size.height)
        ])
    }
    screens.sort { ($0["x"] as! Int) < ($1["x"] as! Int) }
    return ["type": "screens", "layout": screens]
}

func getClipboardResult() -> [String: Any] {
    let pb = NSPasteboard.general
    let text = pb.string(forType: .string) ?? ""
    return ["type": "clipboard", "text": text]
}

func getActiveAppResult() -> [String: Any] {
    let app = NSWorkspace.shared.frontmostApplication
    return [
        "type": "active_app",
        "name": app?.localizedName ?? "",
        "bundle": app?.bundleIdentifier ?? ""
    ]
}

func runCommandResult(_ cmd: String) -> [String: Any] {
    let task = Process()
    task.launchPath = "/bin/sh"
    task.arguments = ["-c", cmd]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    task.launch()
    task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    return [
        "type": "command_result",
        "output": output,
        "exit_code": task.terminationStatus
    ]
}

func listWindowsResult() -> [String: Any] {
    guard let windowList = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] else {
        return ["type": "windows", "list": []]
    }

    var windows: [[String: Any]] = []

    for window in windowList {
        guard let pid    = window["kCGWindowOwnerPID"] as? Int,
              let name   = window["kCGWindowOwnerName"] as? String,
              let bounds = window["kCGWindowBounds"] as? [String: Any],
              let layer  = window["kCGWindowLayer"] as? Int,
              layer == 0
        else { continue }

        let title = window["kCGWindowName"] as? String ?? ""
        let id    = window["kCGWindowNumber"] as? Int ?? 0

        windows.append([
            "id":     id,
            "pid":    pid,
            "app":    name,
            "title":  title,
            "x":      Int(bounds["X"] as? Double ?? 0),
            "y":      Int(bounds["Y"] as? Double ?? 0),
            "w":      Int(bounds["Width"] as? Double ?? 0),
            "h":      Int(bounds["Height"] as? Double ?? 0),
        ])
    }

    return ["type": "windows", "list": windows]
}

func focusAppResult(_ appName: String) -> [String: Any] {
    let apps = NSWorkspace.shared.runningApplications
    if let app = apps.first(where: {
        $0.localizedName?.lowercased() == appName.lowercased()
    }) {
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: .activateIgnoringOtherApps)
        }
        return [
            "type":    "focus_result",
            "app":     appName,
            "success": true
        ]
    } else {
        return [
            "type":    "focus_result",
            "app":     appName,
            "success": false,
            "error":   "App not found: \(appName)"
        ]
    }
}

func getMacStateResult() -> [String: Any] {
    // Display sleep: check if the main display is off
    let displayAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0

    // Lock state: read the current login session dictionary
    var screenLocked = false
    if let sessionInfo = CGSessionCopyCurrentDictionary() as? [String: Any] {
        screenLocked = sessionInfo["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    let state: String
    if displayAsleep {
        state = "display_sleep"
    } else if screenLocked {
        state = "locked"
    } else {
        state = "active"
    }

    return [
        "type":          "mac_state",
        "state":         state,
        "locked":        screenLocked,
        "display_sleep": displayAsleep,
    ]
}

func getWindowForAppResult(_ appName: String) -> [String: Any] {
    guard let windowList = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] else {
        return ["type": "error", "message": "Cannot get window list"]
    }

    for window in windowList {
        guard let name   = window["kCGWindowOwnerName"] as? String,
              name.lowercased() == appName.lowercased(),
              let bounds = window["kCGWindowBounds"] as? [String: Any],
              let layer  = window["kCGWindowLayer"] as? Int,
              layer == 0
        else { continue }

        let title = window["kCGWindowName"] as? String ?? ""
        let id    = window["kCGWindowNumber"] as? Int ?? 0

        return [
            "type":  "window",
            "app":   name,
            "title": title,
            "id":    id,
            "x":     Int(bounds["X"] as? Double ?? 0),
            "y":     Int(bounds["Y"] as? Double ?? 0),
            "w":     Int(bounds["Width"] as? Double ?? 0),
            "h":     Int(bounds["Height"] as? Double ?? 0),
        ]
    }

    return ["type": "error", "message": "Window not found for \(appName)"]
}

// ── Request Dispatcher ────────────────────────────

func handleRequest(_ json: [String: Any]) -> [String: Any] {
    let reqType = json["type"] as? String ?? ""
    let reqId   = json["id"] as? String ?? ""

    var result: [String: Any]

    switch reqType {
    case "get_cursor":
        result = getCursorResult()
    case "get_screens":
        result = getScreensResult()
    case "get_clipboard":
        result = getClipboardResult()
    case "get_active_app":
        result = getActiveAppResult()
    case "get_windows":
        result = listWindowsResult()
    case "get_window_for_app":
        let app = json["app"] as? String ?? ""
        result = getWindowForAppResult(app)
    case "focus_app":
        let app = json["app"] as? String ?? ""
        result = focusAppResult(app)
    case "run_command":
        let cmd = json["cmd"] as? String ?? ""
        result = runCommandResult(cmd)
    case "get_mac_state":
        result = getMacStateResult()
    case "ping":
        result = ["type": "pong"]
    default:
        result = ["type": "error", "message": "Unknown request type: \(reqType)"]
    }

    // Attach the correlation ID
    result["id"] = reqId
    return result
}

// ── WebSocket Server ──────────────────────────────

func startServer(port: UInt16, bindAddr: String) {
    log("Starting WebSocket server on \(bindAddr):\(port)")

    let params = NWParameters.tcp
    let wsOptions = NWProtocolWebSocket.Options()
    params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

    // Bind to specific interface (USB tether only)
    if let nwPort = NWEndpoint.Port(rawValue: port) {
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(bindAddr),
            port: nwPort
        )
    }

    guard let listener = try? NWListener(using: params) else {
        log("❌ Failed to create listener")
        exit(1)
    }

    listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
            log("✅ WebSocket server listening on \(bindAddr):\(port)")
        case .failed(let error):
            log("❌ Listener failed: \(error)")
            exit(1)
        case .cancelled:
            log("⚠ Listener cancelled")
        default:
            break
        }
    }

    listener.newConnectionHandler = { connection in
        log("← New WebSocket connection")
        handleWSConnection(connection)
    }

    listener.start(queue: .main)

    // Install signal handlers for clean shutdown
    signal(SIGINT) { _ in
        log("Received SIGINT — shutting down")
        exit(0)
    }
    signal(SIGTERM) { _ in
        log("Received SIGTERM — shutting down")
        exit(0)
    }

    log("Server ready — waiting for connections...")
    RunLoop.main.run()
}

func handleWSConnection(_ conn: NWConnection) {
    conn.stateUpdateHandler = { state in
        switch state {
        case .ready:
            log("  ✅ Connection ready")
        case .failed(let error):
            log("  ❌ Connection failed: \(error)")
        case .cancelled:
            log("  ⚠ Connection cancelled")
        default:
            break
        }
    }

    conn.start(queue: .global(qos: .userInteractive))
    wsReceiveLoop(conn)
}

func wsReceiveLoop(_ conn: NWConnection) {
    conn.receiveMessage { data, context, isComplete, error in
        if let error = error {
            log("  ❌ Receive error: \(error)")
            conn.cancel()
            return
        }

        guard let data = data, !data.isEmpty else {
            if isComplete {
                log("  ⚠ Connection closed by client")
                conn.cancel()
                return
            }
            // Empty frame — keep listening
            wsReceiveLoop(conn)
            return
        }

        // Check if this is a WebSocket text message
        let isText = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
            .flatMap { $0 as? NWProtocolWebSocket.Metadata }
            .map { $0.opcode == .text } ?? true

        guard isText else {
            log("  ⚠ Ignoring non-text WebSocket frame")
            wsReceiveLoop(conn)
            return
        }

        guard let text = String(data: data, encoding: .utf8) else {
            log("  ❌ Failed to decode UTF-8")
            wsReceiveLoop(conn)
            return
        }

        log("  ← \(text.prefix(120))")

        // Parse JSON and dispatch concurrently
        guard let jsonData = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            log("  ❌ JSON parse error")
            let errResp: [String: Any] = ["type": "error", "id": "", "message": "JSON parse error"]
            wsSendResponse(conn, response: errResp)
            wsReceiveLoop(conn)
            return
        }

        // Dispatch request on a background queue for concurrent execution
        DispatchQueue.global(qos: .userInitiated).async {
            let response = handleRequest(json)
            wsSendResponse(conn, response: response)
        }

        // Immediately listen for next message (don't wait for handler)
        wsReceiveLoop(conn)
    }
}

func wsSendResponse(_ conn: NWConnection, response: [String: Any]) {
    guard let jsonStr = jsonString(response),
          let data = jsonStr.data(using: .utf8) else {
        log("  ❌ Failed to serialize response")
        return
    }

    // Create WebSocket metadata for text frame
    let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
    let context = NWConnection.ContentContext(
        identifier: "ws-response",
        metadata: [metadata]
    )

    conn.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
        if let error = error {
            log("  ❌ Send error: \(error)")
        } else {
            log("  → \(String(data: data, encoding: .utf8)?.prefix(120) ?? "?")")
        }
    })
}

// ── CLI Print Wrappers ────────────────────────────

func getCursor()   { jsonPrint(getCursorResult()) }
func getScreens()  { jsonPrint(getScreensResult()) }
func getClipboard(){ jsonPrint(getClipboardResult()) }
func getActiveApp(){ jsonPrint(getActiveAppResult()) }
func listWindows() { jsonPrint(listWindowsResult()) }
func runCommand(_ cmd: String) { jsonPrint(runCommandResult(cmd)) }
func focusApp(_ appName: String) { jsonPrint(focusAppResult(appName)) }
func getWindowForApp(_ appName: String) { jsonPrint(getWindowForAppResult(appName)) }
func getMacState() { jsonPrint(getMacStateResult()) }

// ── Main ──────────────────────────────────────────

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("Usage: zb-agent <command>\n", stderr)
    fputs("\n", stderr)
    fputs("Commands:\n", stderr)
    fputs("  cursor              Get mouse cursor position\n", stderr)
    fputs("  screens             Get screen layout\n", stderr)
    fputs("  clipboard           Get clipboard text\n", stderr)
    fputs("  app                 Get active application\n", stderr)
    fputs("  windows             List visible windows\n", stderr)
    fputs("  focus <app>         Focus an application\n", stderr)
    fputs("  window <app>        Get window info for app\n", stderr)
    fputs("  run <cmd>           Run a shell command\n", stderr)
    fputs("  state               Get Mac state (active/locked/display_sleep)\n", stderr)
    fputs("  serve [--port N] [--bind ADDR]   Start WebSocket server\n", stderr)
    fputs("\n", stderr)
    exit(1)
}

switch args[1] {
case "cursor":    getCursor()
case "screens":   getScreens()
case "clipboard": getClipboard()
case "app":       getActiveApp()
case "windows":   listWindows()
case "focus":
    guard args.count >= 3 else {
        errorPrint("focus requires app name")
    }
    focusApp(args[2])
case "window":
    guard args.count >= 3 else {
        errorPrint("window requires app name")
    }
    getWindowForApp(args[2])
case "run":
    guard args.count >= 3 else {
        errorPrint("run requires a command argument")
    }
    runCommand(args[2])
case "state": getMacState()
case "serve":
    // Parse --port and --bind flags
    var port: UInt16 = 8082
    var bindAddr = "169.254.206.1"

    var i = 2
    while i < args.count {
        if args[i] == "--port", i + 1 < args.count {
            port = UInt16(args[i + 1]) ?? 8082
            i += 2
        } else if args[i] == "--bind", i + 1 < args.count {
            bindAddr = args[i + 1]
            i += 2
        } else {
            i += 1
        }
    }

    startServer(port: port, bindAddr: bindAddr)
default:
    errorPrint("Unknown command: \(args[1])")
}
