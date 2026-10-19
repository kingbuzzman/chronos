import AppKit

let application = NSApplication.shared
let delegate = ViewerDelegate()
application.delegate = delegate
application.run()
