import AppKit
final class HostEditorWindow: NSWindow {
    var cancelFind: (() -> Bool)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53, cancelFind?() == true { return }
        super.sendEvent(event)
    }
}

final class LineNumberRuler: NSRulerView {
    weak var editor: NSTextView?
    init(scrollView: NSScrollView, editor: NSTextView) {
        self.editor = editor
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = editor; ruleThickness = 56; clipsToBounds = true
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        // Modern AppKit may draw a view outside its bounds. The ruler's dirty rect
        // can span the entire window, so explicitly clip before painting its background.
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        guard let editor, let layout = editor.layoutManager, let container = editor.textContainer else { return }
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        let visible = layout.glyphRange(forBoundingRect: editor.visibleRect, in: container)
        let ns = editor.string as NSString
        if layout.numberOfGlyphs == 0 { drawNumber(1, y: editor.textContainerInset.height); return }
        var glyph = visible.location
        var line = ns.substring(to: min(layout.characterIndexForGlyph(at: min(glyph, max(0, layout.numberOfGlyphs - 1))), ns.length)).filter { $0 == "\n" }.count + 1
        while glyph < NSMaxRange(visible) && glyph < layout.numberOfGlyphs {
            var range = NSRange()
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range)
            let character = layout.characterIndexForGlyph(at: glyph)
            if character == 0 || ns.character(at: character - 1) == 10 {
                drawNumber(line, y: fragment.minY + editor.textContainerInset.height - editor.visibleRect.minY)
                line += 1
            }
            glyph = NSMaxRange(range)
        }
    }
    private func drawNumber(_ number: Int, y: CGFloat) {
        let value = String(number) as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        let size = value.size(withAttributes: attrs)
        value.draw(at: NSPoint(x: ruleThickness - size.width - 12, y: y), withAttributes: attrs)
    }
}
