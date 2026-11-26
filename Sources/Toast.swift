import AppKit

enum Toast {
    private static var current: NSPanel?

    static func show(_ message: String) {
        DispatchQueue.main.async {
            current?.orderOut(nil)

            let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
            let textSize = (message as NSString).size(withAttributes: [.font: font])
            let width = ceil(textSize.width) + 34
            let height: CGFloat = 36

            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .floating
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 10
            effect.layer?.masksToBounds = true
            effect.autoresizingMask = [.width, .height]

            let label = NSTextField(labelWithString: message)
            label.font = font
            label.textColor = .labelColor
            label.alignment = .center
            label.frame = NSRect(x: 12, y: (height - 17) / 2, width: width - 24, height: 18)
            label.autoresizingMask = [.width]
            effect.addSubview(label)
            panel.contentView = effect

            let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                panel.setFrameOrigin(NSPoint(
                    x: floor(visible.midX - width / 2),
                    y: visible.minY + 78
                ))
            }

            panel.alphaValue = 0
            panel.orderFront(nil)
            current = panel

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                panel.animator().alphaValue = 1
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.28
                    panel.animator().alphaValue = 0
                }, completionHandler: {
                    panel.orderOut(nil)
                    if current === panel {
                        current = nil
                    }
                })
            }
        }
    }
}
