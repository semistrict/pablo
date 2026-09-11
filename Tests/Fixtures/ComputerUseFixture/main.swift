import AppKit

final class Fixture: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    var windows: [NSWindow] = []
    let status = NSTextField(labelWithString: "State: Before")
    let formatting = NSTextField(labelWithString: "Bold spans: 0")
    let editor = NSTextField(string: "🙂 first phrase; second phrase!")
    let rich = NSTextView(frame: .zero)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let main = makeWindow(title: "Pablo Computer Use Fixture", frame: NSRect(x: 100, y: 140, width: 820, height: 600))
        guard let content = main.contentView else { return }
        func add(_ view: NSView, _ frame: NSRect, _ identifier: String? = nil) {
            view.frame = frame
            if let identifier { view.setAccessibilityIdentifier(identifier) }
            content.addSubview(view)
        }
        add(NSTextField(labelWithString: "Computer-use fixture — disposable local content"), NSRect(x: 24, y: 550, width: 740, height: 26))
        add(status, NSRect(x: 24, y: 510, width: 350, height: 24), "fixture-status")
        let change = NSButton(title: "Change State", target: self, action: #selector(changeState))
        add(change, NSRect(x: 560, y: 500, width: 220, height: 32), "fixture-change")
        add(editor, NSRect(x: 24, y: 455, width: 756, height: 32), "fixture-editor")
        let secure = NSSecureTextField(string: "fixture secret")
        add(secure, NSRect(x: 24, y: 410, width: 350, height: 30), "fixture-secure")
        let secureLabel = NSTextField(labelWithString: "Synthetic secure field")
        add(secureLabel, NSRect(x: 390, y: 413, width: 350, height: 24))
        let scroll = NSScrollView(frame: NSRect(x: 24, y: 140, width: 756, height: 250))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        rich.frame = NSRect(x: 0, y: 0, width: 752, height: 246)
        rich.autoresizingMask = [.width]
        rich.isEditable = true
        rich.isRichText = true
        rich.font = .systemFont(ofSize: 18)
        rich.string = "Rich content"
        rich.delegate = self
        rich.setAccessibilityIdentifier("fixture-rich-editor")
        scroll.documentView = rich
        content.addSubview(scroll)
        add(formatting, NSRect(x: 24, y: 102, width: 450, height: 24), "fixture-formatting")
        let red = NSView(); red.wantsLayer = true; red.layer?.backgroundColor = NSColor.systemRed.cgColor
        let blue = NSView(); blue.wantsLayer = true; blue.layer?.backgroundColor = NSColor.systemBlue.cgColor
        add(red, NSRect(x: 24, y: 25, width: 180, height: 55))
        add(blue, NSRect(x: 600, y: 25, width: 180, height: 55))

        let second = makeWindow(title: "Pablo Second Window", frame: NSRect(x: 960, y: 310, width: 360, height: 220))
        let secondary = NSTextField(string: "Secondary field")
        secondary.frame = NSRect(x: 20, y: 130, width: 320, height: 30)
        secondary.setAccessibilityIdentifier("fixture-secondary-editor")
        second.contentView?.addSubview(secondary)
        let close = NSButton(title: "Close This Window", target: self, action: #selector(closeSecond))
        close.frame = NSRect(x: 40, y: 60, width: 280, height: 34)
        close.setAccessibilityIdentifier("fixture-close-second")
        second.contentView?.addSubview(close)
        main.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func makeWindow(title: String, frame: NSRect) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.orderFront(nil)
        return window
    }

    @objc func changeState() { status.stringValue = "State: After" }
    @objc func closeSecond() { windows.last?.close() }
    func textDidChange(_ notification: Notification) {
        var spans = 0
        rich.textStorage?.enumerateAttribute(.font, in: NSRange(location: 0, length: rich.textStorage?.length ?? 0)) { value, _, _ in
            if let font = value as? NSFont, NSFontManager.shared.traits(of: font).contains(.boldFontMask) { spans += 1 }
        }
        formatting.stringValue = "Bold spans: \(spans)"
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Fixture()
app.delegate = delegate
let menu = NSMenu()
let appItem = NSMenuItem(); menu.addItem(appItem)
let appMenu = NSMenu(); appItem.submenu = appMenu
appMenu.addItem(withTitle: "Quit Fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); menu.addItem(editItem)
let editMenu = NSMenu(title: "Edit"); editItem.submenu = editMenu
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
app.mainMenu = menu
app.run()
