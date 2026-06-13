import Foundation
import AppKit
import Quartz

// ── Helpers ───────────────────────────────────────

func jsonPrint(_ obj: Any) {
    if let data = try? JSONSerialization.data(withJSONObject: obj),
       let str = String(data: data, encoding: .utf8) {
        print(str)
    }
}

func errorPrint(_ msg: String) -> Never {
    fputs("{\"error\":\"\(msg)\"}\n", stderr)
    exit(1)
}

// ── Commands ──────────────────────────────────────

func getCursor() {
    let loc = NSEvent.mouseLocation
    jsonPrint([
        "type": "cursor_pos",
        "x": round(loc.x * 10) / 10,
        "y": round(loc.y * 10) / 10
    ])
}

func getScreens() {
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
    jsonPrint(["type": "screens", "layout": screens])
}

func getClipboard() {
    let pb = NSPasteboard.general
    let text = pb.string(forType: .string) ?? ""
    jsonPrint(["type": "clipboard", "text": text])
}

func getActiveApp() {
    let app = NSWorkspace.shared.frontmostApplication
    jsonPrint([
        "type": "active_app",
        "name": app?.localizedName ?? "",
        "bundle": app?.bundleIdentifier ?? ""
    ])
}

func runCommand(_ cmd: String) {
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
    jsonPrint([
        "type": "command_result",
        "output": output,
        "exit_code": task.terminationStatus
    ])
}
// ── Window Management ─────────────────────────────

func listWindows() {
    guard let windowList = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] else {
        jsonPrint(["type": "windows", "list": []])
        return
    }

    var windows: [[String: Any]] = []

    for window in windowList {
        guard let pid    = window["kCGWindowOwnerPID"] as? Int,
              let name   = window["kCGWindowOwnerName"] as? String,
              let bounds = window["kCGWindowBounds"] as? [String: Any],
              let layer  = window["kCGWindowLayer"] as? Int,
              layer == 0  // only normal windows
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

    jsonPrint(["type": "windows", "list": windows])
}

func focusApp(_ appName: String) {
    let apps = NSWorkspace.shared.runningApplications
    if let app = apps.first(where: {
        $0.localizedName?.lowercased() == appName.lowercased()
    }) {
        // macOS 14+ compatible way
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: .activateIgnoringOtherApps)
        }
        jsonPrint([
            "type":    "focus_result",
            "app":     appName,
            "success": true
        ])
    } else {
        jsonPrint([
            "type":    "focus_result",
            "app":     appName,
            "success": false,
            "error":   "App not found: \(appName)"
        ])
    }
}

func getWindowForApp(_ appName: String) {
    guard let windowList = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] else {
        jsonPrint(["type": "error", "message": "Cannot get window list"])
        return
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

        jsonPrint([
            "type":  "window",
            "app":   name,
            "title": title,
            "id":    id,
            "x":     Int(bounds["X"] as? Double ?? 0),
            "y":     Int(bounds["Y"] as? Double ?? 0),
            "w":     Int(bounds["Width"] as? Double ?? 0),
            "h":     Int(bounds["Height"] as? Double ?? 0),
        ])
        return
    }

    jsonPrint(["type": "error", "message": "Window not found for \(appName)"])
}
// ── Main ──────────────────────────────────────────

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("Usage: zb-agent <cursor|screens|clipboard|app|run <cmd>>\n", stderr)
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
default:
    errorPrint("Unknown command: \(args[1])")
}
