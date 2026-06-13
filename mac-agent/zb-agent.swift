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

// ── Main ──────────────────────────────────────────

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("Usage: zb-agent <cursor|screens|clipboard|app|run <cmd>>\n", stderr)
    exit(1)
}

switch args[1] {
case "cursor":
    getCursor()
case "screens":
    getScreens()
case "clipboard":
    getClipboard()
case "app":
    getActiveApp()
case "run":
    guard args.count >= 3 else {
        errorPrint("run requires a command argument")
    }
    runCommand(args[2])
default:
    errorPrint("Unknown command: \(args[1])")
}