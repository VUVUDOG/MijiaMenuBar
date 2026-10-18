import AppKit

// Application entry point (kept apart so App.swift and Intents.swift can be compiled together).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
