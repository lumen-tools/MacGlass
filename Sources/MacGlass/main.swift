// MacGlass - entry point.
// SPDX-License-Identifier: GPL-3.0-only
import AppKit

let arguments = CommandLine.arguments
if let i = arguments.firstIndex(of: "--selftest") {
    // Headless checks used by CI: MacGlass --selftest <output folder>
    let outDir = i + 1 < arguments.count ? arguments[i + 1] : NSTemporaryDirectory()
    Thread {
        exit(SelfTest.run(outDir: URL(fileURLWithPath: outDir, isDirectory: true)))
    }.start()
    dispatchMain()
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.regular)
app.run()
