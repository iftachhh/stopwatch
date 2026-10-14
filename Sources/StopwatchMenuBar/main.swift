import AppKit
import Carbon.HIToolbox

final class Stopwatch {
    private(set) var isRunning = false
    private var startDate: Date?
    private var accumulated: TimeInterval = 0

    var elapsed: TimeInterval {
        accumulated + (isRunning ? Date().timeIntervalSince(startDate!) : 0)
    }

    func stop() {
        guard isRunning else { return }
        accumulated += Date().timeIntervalSince(startDate!)
        isRunning = false
    }

    func resume() {
        guard !isRunning else { return }
        startDate = Date()
        isRunning = true
    }

    func startFromZero() {
        accumulated = 0
        startDate = Date()
        isRunning = true
    }

    func reset() {
        isRunning = false
        startDate = nil
        accumulated = 0
    }
}

// Borderless text that floats above other windows. A click without dragging calls onClick; a drag moves it and calls onDragEnd.
final class FloatingTextView: NSView {
    enum Style: Int {
        case outline, dark, glass // glass: the view draws only text; the caller puts it inside a glass view
    }

    private static let padding: CGFloat = 8
    var style = Style.outline {
        didSet { resize() }
    }
    var cornerRadius: CGFloat { font.pointSize * 0.35 }
    private static let shadow: NSShadow = {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 4
        return shadow
    }()

    var font = NSFont.monospacedDigitSystemFont(ofSize: 28, weight: .heavy) {
        didSet { resize() }
    }
    private var attributes: [NSAttributedString.Key: Any] {
        [.font: font]
    }
    private static let fillColor = NSColor(white: 0.94, alpha: 1)
    // visible outline thickness outside the glyphs, as a fraction of the font size
    private static let strokeRatio: CGFloat = 0.04
    // extra glyph thickness for fonts lighter than SF Heavy, as a fraction of the font size
    var embolden: CGFloat = 0
    // glyph names to draw in place of others, e.g. a font's plain zero instead of its slashed one
    var glyphSubstitutions: [String: String] = [:]
    // width of ":" and "." relative to their normal advance; monospaced fonts give them a full digit cell
    var punctuationScale: CGFloat = 1

    var onClick: ((_ optionHeld: Bool) -> Void)?
    var onDragEnd: (() -> Void)?
    var onResize: (() -> Void)?
    // adjusts a proposed window origin while dragging
    var constrainOrigin: ((NSPoint) -> NSPoint)?
    private var dragged = false
    private var mouseDownAt = NSPoint.zero
    private var originAtMouseDown = NSPoint.zero

    var text = "" {
        didSet { if text != oldValue { resize() } }
    }

    // overrides the style's text color (nil = light gray, or the system text color on glass)
    var textColorOverride: NSColor? {
        didSet { if textColorOverride != oldValue { needsDisplay = true } }
    }

    var textAlpha: CGFloat = 1 {
        didSet { if textAlpha != oldValue { needsDisplay = true } }
    }

    // distance from the view edges to the digits' ink. Same for every style so switching styles doesn't move the digits:
    // room for the background box's padding, and at least room for the outline and its shadow.
    private var inset: CGSize {
        let emboldenOutset = font.pointSize * embolden
        let outline = Self.padding + font.pointSize * Self.strokeRatio
        return CGSize(width: max(font.pointSize * 0.45, outline) + emboldenOutset,
                      height: max(font.pointSize * 0.3, outline) + emboldenOutset)
    }

    // ink bounds of "0" relative to the baseline (round digits overshoot slightly below it)
    static func digitBounds(_ font: NSFont) -> CGRect {
        var character: UniChar = 0x30
        var glyph: CGGlyph = 0
        CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
        return CTFontGetBoundingRectsForGlyphs(font, .default, &glyph, nil, 1)
    }

    static func digitHeight(_ font: NSFont) -> CGFloat { digitBounds(font).height }

    private func resize() {
        guard let window else { return }
        // height from the digits' ink (not the font's line box) so every font gets the same box with the digits in the same place
        let width = layout().width
        let size = NSSize(width: ceil(width + 2 * inset.width), height: ceil(Self.digitHeight(font) + 2 * inset.height))
        // resizing a window is slow; digits are monospaced so this only happens when the format or font changes
        if size != bounds.size {
            window.setContentSize(size)
            onResize?()
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        switch style {
        case .outline:
            // lowest non-zero alpha: invisible, but clicks in the padding still hit the window instead of passing through
            context.setFillColor(CGColor(gray: 0, alpha: 1.0 / 255))
            context.fill(bounds)
        case .dark:
            context.addPath(CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
            context.setFillColor(CGColor(gray: 0, alpha: 0.5))
            context.fillPath()
        case .glass:
            break
        }

        let path = layout().path
        context.translateBy(x: inset.width, y: inset.height - Self.digitBounds(font).minY)
        // glass can be light or dark depending on what's behind it, so follow the system text color there
        let textColor = textColorOverride?.cgColor ?? (style == .glass ? NSColor.labelColor.cgColor : Self.fillColor.cgColor)

        // the flash dims fill and outline together; the background box stays
        context.saveGState()
        context.setAlpha(textAlpha)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        // colored text keeps its outline on every style so it stays readable on the box
        if style == .outline || textColorOverride != nil {
            drawOutline(path, in: context)
        }
        fillGlyphs(path, color: textColor, in: context)
        context.endTransparencyLayer()
        context.restoreGState()
    }

    // the glyph shape, thickened by embolden
    private func fillGlyphs(_ path: CGPath, color: CGColor, in context: CGContext) {
        context.addPath(path)
        context.setFillColor(color)
        context.fillPath()
        if embolden > 0 {
            // fake bold: stroke the outline in the fill color
            context.addPath(path)
            context.setLineJoin(.round)
            context.setLineWidth(font.pointSize * embolden * 2)
            context.setStrokeColor(color)
            context.strokePath()
        }
    }

    private func drawOutline(_ path: CGPath, in context: CGContext) {
        // outer stroke: stroke the glyph outlines at double width with round joins (even all around),
        // then clear the glyph shape out of it so only the outside remains (a dimmed fill mustn't show it through)
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setShadow(offset: Self.shadow.shadowOffset, blur: Self.shadow.shadowBlurRadius,
                          color: Self.shadow.shadowColor?.cgColor)
        context.addPath(path)
        context.setLineJoin(.round)
        context.setLineWidth(font.pointSize * (Self.strokeRatio + embolden) * 2)
        context.setStrokeColor(.black)
        context.strokePath()
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setBlendMode(.clear)
        fillGlyphs(path, color: .black, in: context)
        context.endTransparencyLayer()
        context.restoreGState()
    }

    // glyph outlines of the text, with substitutions and narrowed punctuation applied, plus the resulting advance width
    private func layout() -> (path: CGPath, width: CGFloat) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let path = CGMutablePath()
        var removed: CGFloat = 0 // width taken out of the punctuation so far; later glyphs shift left by it
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            for (from, to) in glyphSubstitutions {
                let fromGlyph = CTFontGetGlyphWithName(runFont, from as CFString)
                let toGlyph = CTFontGetGlyphWithName(runFont, to as CFString)
                guard fromGlyph != 0, toGlyph != 0 else { continue }
                glyphs = glyphs.map { $0 == fromGlyph ? toGlyph : $0 }
            }
            CTRunGetPositions(run, CFRange(), &positions)
            var advances = [CGSize](repeating: .zero, count: count)
            CTRunGetAdvances(run, CFRange(), &advances)
            var punctuation: [UniChar] = [0x3A, 0x2E] // ":" "."
            var punctuationGlyphs: [CGGlyph] = [0, 0]
            CTFontGetGlyphsForCharacters(runFont, &punctuation, &punctuationGlyphs, 2)
            for i in 0..<count {
                var x = positions[i].x - removed
                if punctuationScale != 1 && punctuationGlyphs.contains(glyphs[i]) {
                    let cut = advances[i].width * (1 - punctuationScale)
                    x -= cut / 2 // keep the glyph centered in its narrower cell
                    removed += cut
                }
                guard let glyph = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) else { continue }
                path.addPath(glyph, transform: CGAffineTransform(translationX: x, y: positions[i].y))
            }
        }
        return (path, CTLineGetTypographicBounds(line, nil, nil, nil) - removed)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragged = false
        mouseDownAt = NSEvent.mouseLocation
        originAtMouseDown = window?.frame.origin ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let location = NSEvent.mouseLocation
        let dx = location.x - mouseDownAt.x, dy = location.y - mouseDownAt.y
        // ignore hand jitter so a slightly moving click still counts as a click
        if !dragged && hypot(dx, dy) < 4 { return }
        dragged = true
        let origin = NSPoint(x: originAtMouseDown.x + dx, y: originAtMouseDown.y + dy)
        window.setFrameOrigin(constrainOrigin?(origin) ?? origin)
    }

    override func mouseUp(with event: NSEvent) {
        dragged ? onDragEnd?() : onClick?(event.modifierFlags.contains(.option))
    }
}

// The custom time in the Timer menu: one "0:00" field and its stepper.
// Click the field to select it (gray highlight, no caret). Digits fill in from the right like a microwave keypad
// (0:05 → 0:53 → 5:30) and apply as you type, Delete removes the last digit, Esc lets go.
// The stepper moves 5 seconds up to a minute and 15 above; ⌥-click moves a whole minute.
// Arrow keys stay with the menu: a menu handles every key itself as well, so the field can't keep them.
final class CustomTimerView: NSView {
    private let field = NSTextField()
    private let stepper = NSStepper()
    private var total = 0          // seconds the field shows (0 = no timer)
    private var typed: Int?        // digits typed since the field was selected, as mmss
    private var selected = false
    var onChange: ((Int) -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 140, height: 30))
        let x: CGFloat = 34 // lines up with the menu item titles and dividers
        field.isEditable = false   // keys come to this view instead, so there's never a caret
        field.isSelectable = false
        field.alignment = .left
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.bezelStyle = .roundedBezel
        field.frame = NSRect(x: x, y: 4, width: 64, height: 22) // fits "60:00"
        field.setAccessibilityLabel("Timer")
        // the stepper only reports a direction (one past either side of 0); step() decides the amount
        stepper.minValue = -1
        stepper.maxValue = 1
        stepper.target = self
        stepper.action = #selector(stepped)
        stepper.frame = NSRect(x: x + 65, y: 3, width: 15, height: 24)
        stepper.setAccessibilityLabel("Timer")
        addSubview(field)
        addSubview(stepper)
        redraw()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: selection and typing

    override var acceptsFirstResponder: Bool { true }

    // the menu builds a new window each time it opens; start unselected
    override func viewDidMoveToWindow() {
        select(false)
    }

    // clicks on the field come to this view (a read-only field would otherwise swallow them)
    override func hitTest(_ point: NSPoint) -> NSView? {
        let view = super.hitTest(point)
        return view === field ? self : view
    }

    override func mouseDown(with event: NSEvent) {
        select(true)
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if !(selected && handle(event)) { super.keyDown(with: event) }
    }

    // returns whether the key was used
    private func handle(_ event: NSEvent) -> Bool {
        let key = event.charactersIgnoringModifiers ?? ""
        if let digit = Int(key), key.count == 1 {
            type(min(((typed ?? 0) * 10 + digit) % 10000, 6000)) // at most mm:ss, an hour at most
        } else if event.keyCode == 51 || event.keyCode == 117 { // Delete, Forward Delete: drop the last digit
            type((typed ?? Self.digits(total)) / 10)
        } else if event.keyCode == 53 { // Esc: let go
            select(false)
            window?.makeFirstResponder(nil)
        } else {
            return false
        }
        return true
    }

    private func select(_ on: Bool) {
        if !on { typed = nil } // the time is already applied; show it tidied up (0:90 → 1:30)
        selected = on
        redraw()
    }

    // keeps building one number while selected (so 5, 9, 5, 9 gives 59:59) and applies it right away
    private func type(_ digits: Int) {
        typed = digits
        set(Self.seconds(fromDigits: digits))
    }

    // MARK: values

    func show(_ totalSeconds: Int) {
        total = totalSeconds
        redraw()
    }

    @objc private func stepped(_ sender: NSStepper) {
        let up = sender.integerValue > 0
        sender.integerValue = 0
        typed = nil // stepping starts a fresh entry
        let wholeMinute = NSApp.currentEvent?.modifierFlags.contains(.option) == true
        set(wholeMinute ? (up ? total + 60 : total < 60 ? 0 : total - 60) : Self.step(total, up: up))
    }

    private func set(_ seconds: Int) {
        total = min(max(seconds, 0), 3600) // an hour at most
        redraw()
        onChange?(total) // 0:00 means no timer (None)
    }

    // shows typed digits as they are (0:9 → "0:09", even 0:90), otherwise the time; gray highlight when selected
    private func redraw() {
        let digits = typed ?? Self.digits(total)
        let text = "\(digits / 100):" + String(format: "%02d", digits % 100)
        let alignLeft = NSMutableParagraphStyle()
        alignLeft.alignment = .left
        var attributes: [NSAttributedString.Key: Any] = [
            .font: field.font!, .paragraphStyle: alignLeft, .foregroundColor: NSColor.labelColor
        ]
        if selected { attributes[.backgroundColor] = NSColor.unemphasizedSelectedTextBackgroundColor }
        field.attributedStringValue = NSAttributedString(string: text, attributes: attributes)
    }

    // 5-second steps up to a minute, 15-second steps above; snaps to the step grid, so 62 → 75 up or 60 down
    static func step(_ total: Int, up: Bool) -> Int {
        let step = (up ? total < 60 : total <= 60) ? 5 : 15
        return up ? (total / step + 1) * step : max(total - 1, 0) / step * step
    }

    // 1:30 ↔ 130 (mmss digits); typed seconds past 59 carry into minutes
    static func digits(_ seconds: Int) -> Int { seconds / 60 * 100 + seconds % 60 }
    static func seconds(fromDigits digits: Int) -> Int { digits / 100 * 60 + digits % 100 }
}


final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private let stopwatch = Stopwatch()
    private let menu = NSMenu()
    private let resetItem = NSMenuItem()
    // click behavior choice; tag 1 = start from zero (reverseClickActions), 0 = start or resume
    private var clickModeItems: [NSMenuItem] = []
    private let millisecondsItem = NSMenuItem()
    private let doubleClickResetItem = NSMenuItem()
    // Timer and Play Sound appear in both the menu bar menu and the floating stopwatch's menu;
    // a submenu can only belong to one menu, so each place gets its own copy
    private var timerMenus: [NSMenu] = []
    private var customTimerViews: [CustomTimerView] = []
    private let floatingItem = NSMenuItem()
    private var alertSoundItems: [NSMenuItem] = []
    private var alertSoundMenus: [NSMenu] = []
    private var previewSound: NSSound?
    private var alertDone = false // time-up sound already played for the current run past the alert time
    private let floatingResetItem = NSMenuItem()
    private var floatingPanel: NSPanel?
    private let floatingView = FloatingTextView()
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    private static let horizontalPadding: CGFloat = 6

    private static let reverseKey = "reverseClickActions"
    private static let millisecondsKey = "showMilliseconds"
    private static let doubleClickResetKey = "doubleClickToReset"
    private static let blinkAfterKey = "blinkAfterSeconds"
    private static let alertSoundKey = "alertSound" // old on/off setting; read once to migrate
    private static let alertSoundNameKey = "alertSoundName"
    // menu title and sound name ("" = no sound): a system sound, or an EncoreInfinitum alert tone that macOS
    // ships in ToneLibrary. Those are played from the system at runtime, never bundled, so the app can be shipped.
    private static let toneLibrary = URL(fileURLWithPath:
        "/System/Library/PrivateFrameworks/ToneLibrary.framework/Resources/AlertTones/EncoreInfinitum")
    private static let alertSounds: [(String, String)] = [("None", ""), ("Ping", "Ping")]
        + ["Antic", "Cheers", "Droplet", "Handoff", "Milestone", "Passage", "Portal", "Rattle", "Slide"]
            .map { ($0, "\($0)-EncoreInfinitum") }
            // only list tones this macOS actually has
            .filter { FileManager.default.fileExists(atPath: toneLibrary.appendingPathComponent($0.1 + ".caf").path) }
    private static let floatingKey = "showFloatingStopwatch"
    private static let floatingSpotKey = "floatingSpot"
    private static let floatingSizeKey = "floatingFontSize"
    private static let floatingDesignKey = "floatingFontDesign"
    private static let floatingStyleKey = "floatingStyle"
    private static let floatingColorKey = "floatingColor"
    // 0: gray, 1: green to red, reaching red at the flash time
    private static let floatingColors = ["Gray", "Green to Red"]
    private static let floatingStyles: [(String, FloatingTextView.Style)] = [
        ("Outline", .outline), ("Dark Background", .dark), ("Translucent Blur", .glass)
    ]
    private static let floatingSizes: [(String, Int)] = [("Small", 20), ("Medium", 28), ("Large", 36), ("Extra Large", 48)]
    // system design raw value, or a font PostScript name
    private static let floatingDesigns: [(String, String)] = [
        ("Sans Serif", NSFontDescriptor.SystemDesign.default.rawValue),
        ("Rounded", NSFontDescriptor.SystemDesign.rounded.rawValue),
        ("Serif", NSFontDescriptor.SystemDesign.serif.rawValue), // New York
        ("Monospace", "PTMono-Bold"), // ships with macOS; drawn thicker, its Bold is its heaviest
        ("Slab Serif", "Rockwell-Bold") // ships with macOS; Apple has no slab design of its own
    ]
    private static let floatingOriginKey = "floatingFreeOrigin"
    private static let floatingSpotPadding: CGFloat = 12
    // drops closer than this (window center to spot center) snap to the spot
    private static let floatingSnapDistance: CGFloat = 60
    private static let doubleClickInterval: TimeInterval = 0.25
    // ponytail: flashing at time's up is switched off for now; set true to bring it back
    private static let flashWhenTimeUp = false
    private static let blinkOptions = [0, 5, 10, 15, 30, 45, 60, 120, 180, 240, 300]

    private var reverseClickActions = UserDefaults.standard.object(forKey: AppDelegate.reverseKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(reverseClickActions, forKey: Self.reverseKey) }
    }
    private var showMilliseconds = UserDefaults.standard.object(forKey: AppDelegate.millisecondsKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(showMilliseconds, forKey: Self.millisecondsKey) }
    }
    private var doubleClickToReset = UserDefaults.standard.object(forKey: AppDelegate.doubleClickResetKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(doubleClickToReset, forKey: Self.doubleClickResetKey) }
    }
    // 0-2: top left/center/right, 3-5: bottom left/center/right, -1: free (at floatingFreeOrigin)
    private var floatingSize = UserDefaults.standard.object(forKey: AppDelegate.floatingSizeKey) as? Int ?? 36 {
        didSet { UserDefaults.standard.set(floatingSize, forKey: Self.floatingSizeKey) }
    }
    private var floatingDesign = UserDefaults.standard.string(forKey: AppDelegate.floatingDesignKey) ?? NSFontDescriptor.SystemDesign.rounded.rawValue {
        didSet { UserDefaults.standard.set(floatingDesign, forKey: Self.floatingDesignKey) }
    }
    private var floatingColor = UserDefaults.standard.integer(forKey: AppDelegate.floatingColorKey) {
        didSet { UserDefaults.standard.set(floatingColor, forKey: Self.floatingColorKey) }
    }
    private var floatingStyle = UserDefaults.standard.integer(forKey: AppDelegate.floatingStyleKey) {
        didSet { UserDefaults.standard.set(floatingStyle, forKey: Self.floatingStyleKey) }
    }
    private let customizeMenu = NSMenu()
    private var floatingSpot = UserDefaults.standard.object(forKey: AppDelegate.floatingSpotKey) as? Int ?? 4 {
        didSet { UserDefaults.standard.set(floatingSpot, forKey: Self.floatingSpotKey) }
    }
    // 0 = never blink
    private var blinkAfter = UserDefaults.standard.integer(forKey: AppDelegate.blinkAfterKey) {
        didSet { UserDefaults.standard.set(blinkAfter, forKey: Self.blinkAfterKey) }
    }
    private var alertSound = UserDefaults.standard.string(forKey: AppDelegate.alertSoundNameKey)
        ?? (UserDefaults.standard.bool(forKey: AppDelegate.alertSoundKey) ? "Ping" : "Handoff-EncoreInfinitum") {
        didSet {
            UserDefaults.standard.set(alertSound, forKey: Self.alertSoundNameKey)
            UserDefaults.standard.removeObject(forKey: Self.alertSoundKey)
        }
    }
    private var showFloating = UserDefaults.standard.bool(forKey: AppDelegate.floatingKey) {
        didSet { UserDefaults.standard.set(showFloating, forKey: Self.floatingKey) }
    }
    private var menuJustClosedAt: TimeInterval = 0
    private var lastClickAt: TimeInterval = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.font = Self.font
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
            button.action = #selector(clicked)
        }

        resetItem.title = "Reset Stopwatch"
        resetItem.action = #selector(resetAction)
        menu.addItem(resetItem)
        // the saved tone is gone from this macOS: switch the setting to Ping
        if !Self.alertSounds.contains(where: { $0.1 == alertSound }) { alertSound = "Ping" }
        addTimerAndSoundItems(to: menu)
        menu.addItem(.separator())
        for (title, subtitle, tag) in [("Click to Start from Zero", "⌥+click to resume", 1),
                                       ("Click to Start or Resume", "⌥+click to start from zero", 0)] {
            let item = NSMenuItem(title: title, action: #selector(selectClickMode), keyEquivalent: "")
            item.attributedTitle = Self.titleWithHint(title, subtitle)
            item.tag = tag
            item.state = (tag == 1) == reverseClickActions ? .on : .off
            menu.addItem(item)
            clickModeItems.append(item)
        }
        menu.addItem(.separator())
        floatingItem.attributedTitle = Self.titleWithHint("Show Floating Stopwatch", "Right-click it to customize")
        floatingItem.action = #selector(toggleFloating)
        floatingItem.state = showFloating ? .on : .off
        menu.addItem(floatingItem)
        doubleClickResetItem.title = "Double Click to Reset"
        doubleClickResetItem.action = #selector(toggleDoubleClickReset)
        doubleClickResetItem.state = doubleClickToReset ? .on : .off
        menu.addItem(doubleClickResetItem)
        millisecondsItem.title = "Show Milliseconds"
        millisecondsItem.action = #selector(toggleMilliseconds)
        millisecondsItem.state = showMilliseconds ? .on : .off
        menu.addItem(millisecondsItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        menu.delegate = self
        menu.autoenablesItems = false

        floatingView.onClick = { [weak self] optionHeld in self?.leftClick(optionHeld: optionHeld) }
        floatingView.onDragEnd = { [weak self] in self?.snapFloating() }
        // keep right/center spots anchored when the text width changes
        floatingView.onResize = { [weak self] in self?.placeFloating() }
        // while dragging, the screen under the cursor decides, so it can be dragged onto another display
        floatingView.constrainOrigin = { [weak self] origin in self?.clampedFloatingOrigin(origin, on: NSEvent.mouseLocation) ?? origin }
        let floatingMenu = NSMenu()
        floatingResetItem.action = #selector(resetAction)
        floatingMenu.addItem(floatingResetItem)
        addTimerAndSoundItems(to: floatingMenu)
        floatingMenu.addItem(.separator())
        // Translucent Blur needs macOS 26: hide it before that, and move a saved choice to Dark Background
        let glassAvailable: Bool
        if #available(macOS 26, *) { glassAvailable = true } else { glassAvailable = false }
        if !glassAvailable && floatingStyle == FloatingTextView.Style.glass.rawValue {
            floatingStyle = FloatingTextView.Style.dark.rawValue
        }
        for (title, style) in Self.floatingStyles where style != .glass || glassAvailable {
            let item = NSMenuItem(title: title, action: #selector(selectFloatingStyle), keyEquivalent: "")
            item.tag = style.rawValue
            customizeMenu.addItem(item)
        }
        customizeMenu.addItem(.separator())
        for (title, size) in Self.floatingSizes {
            let item = NSMenuItem(title: title, action: #selector(selectFloatingSize), keyEquivalent: "")
            item.tag = size
            customizeMenu.addItem(item)
        }
        customizeMenu.addItem(.separator())
        for (title, design) in Self.floatingDesigns {
            let item = NSMenuItem(title: title, action: #selector(selectFloatingDesign), keyEquivalent: "")
            item.representedObject = design
            customizeMenu.addItem(item)
        }
        customizeMenu.addItem(.separator())
        for (index, title) in Self.floatingColors.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(selectFloatingColor), keyEquivalent: "")
            item.tag = index
            customizeMenu.addItem(item)
        }
        customizeMenu.autoenablesItems = false
        for item in customizeMenu.items { item.target = self }
        let customizeItem = NSMenuItem(title: "Customize", action: nil, keyEquivalent: "")
        customizeItem.attributedTitle = Self.titleWithHint("Customize", "Change style, size, font…", italic: true)
        customizeItem.submenu = customizeMenu
        floatingMenu.addItem(customizeItem)
        floatingMenu.addItem(withTitle: "Hide", action: #selector(toggleFloating), keyEquivalent: "")
        for item in floatingMenu.items { item.target = self }
        floatingMenu.delegate = self
        floatingMenu.autoenablesItems = false
        floatingView.menu = floatingMenu
        applyFloatingFont()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.placeFloating()
        }
        updateFloatingPanel()
        updateText()
        registerHotKey()
    }

    // ⌥\ anywhere acts like a plain left click, ⌥⇧\ like a ⌥+click.
    // Carbon hot keys: no Accessibility permission needed, and they swallow the keystroke.
    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()
            delegate.toggle(optionHeld: hotKeyID.id == 2)
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(kVK_ANSI_Backslash), UInt32(optionKey), EventHotKeyID(signature: 0x53545057, id: 1),
                            GetApplicationEventTarget(), 0, &ref)
        RegisterEventHotKey(UInt32(kVK_ANSI_Backslash), UInt32(optionKey | shiftKey), EventHotKeyID(signature: 0x53545057, id: 2),
                            GetApplicationEventTarget(), 0, &ref)
    }

    func menuWillOpen(_ menu: NSMenu) {
        for item in [resetItem, floatingResetItem] {
            item.title = stopwatch.isRunning ? "Stop and Reset Stopwatch" : "Reset Stopwatch"
            item.isEnabled = stopwatch.elapsed > 0
        }
    }

    // bundled .caf files by explicit URL (NSSound(named:) doesn't find them), otherwise a system sound
    // ponytail: ToneLibrary is a private folder a macOS update could move; missing tones aren't listed,
    // and a saved missing tone is switched to Ping at launch
    private static func sound(_ name: String) -> NSSound? {
        guard !name.isEmpty else { return nil }
        if let sound = NSSound(named: name) { return sound } // system sounds like Ping
        return NSSound(contentsOf: toneLibrary.appendingPathComponent(name + ".caf"), byReference: true)
    }

    private func addTimerAndSoundItems(to menu: NSMenu) {
        menu.addItem(.separator()) // between Reset and Timer
        let timerMenu = NSMenu()
        // minutes/seconds editor first, then None, then the presets.
        // The editor sits right in the Timer menu (a further submenu could open over the main menu).
        let editor = CustomTimerView()
        editor.onChange = { [weak self] seconds in self?.setTimer(seconds) }
        let editorItem = NSMenuItem()
        editorItem.view = editor
        customTimerViews.append(editor)
        timerMenu.addItem(editorItem)
        for seconds in Self.blinkOptions {
            let item = NSMenuItem(title: Self.blinkLabel(seconds), action: #selector(selectBlinkAfter), keyEquivalent: "")
            item.tag = seconds
            item.target = self
            timerMenu.addItem(item)
            if seconds == 0 { timerMenu.addItem(.separator()) }
        }
        // keep the checkmark column even when nothing is checked, so the titles and the editor stay aligned:
        // the system checkmark for on, and a blank image of exactly its size for off
        if let check = NSImage(named: NSImage.menuOnStateTemplateName) {
            let blank = NSImage(size: check.size)
            for item in timerMenu.items where !item.isSeparatorItem && item.view == nil {
                item.onStateImage = check
                item.offStateImage = blank
            }
        }
        timerMenus.append(timerMenu)
        let timerItem = NSMenuItem(title: "Timer", action: nil, keyEquivalent: "")
        timerItem.attributedTitle = Self.titleWithHint("Timer", "When time's up, stopwatch will turn red")
        timerItem.submenu = timerMenu
        menu.addItem(timerItem)

        let soundMenu = NSMenu()
        for (title, name) in Self.alertSounds {
            let item = NSMenuItem(title: title, action: #selector(selectAlertSound), keyEquivalent: "")
            item.representedObject = name
            item.target = self
            soundMenu.addItem(item)
            if name.isEmpty { soundMenu.addItem(.separator()) } // after None
        }
        soundMenu.delegate = self // previews each sound as it's hovered
        alertSoundMenus.append(soundMenu)
        let soundItem = NSMenuItem(title: "Play Sound", action: nil, keyEquivalent: "")
        soundItem.submenu = soundMenu
        menu.addItem(soundItem)
        alertSoundItems.append(soundItem)
        updateTimerCheckmarks()
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard alertSoundMenus.contains(where: { $0 === menu }) else { return }
        previewSound?.stop()
        previewSound = (item?.representedObject as? String).flatMap(Self.sound)
        previewSound?.play()
    }

    func menuDidClose(_ menu: NSMenu) {
        if alertSoundMenus.contains(where: { $0 === menu }) {
            previewSound?.stop()
            return
        }
        menuJustClosedAt = ProcessInfo.processInfo.systemUptime
    }

    @objc private func clicked() {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            // the click that dismisses an open menu also re-triggers this
            // action right after — skip reopening if we just closed it
            if ProcessInfo.processInfo.systemUptime - menuJustClosedAt < 0.3 {
                return
            }
            menu.popUp(positioning: nil, at: .zero, in: statusItem.button)
            return
        }

        leftClick(optionHeld: NSEvent.modifierFlags.contains(.option))
    }

    private func leftClick(optionHeld: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if doubleClickToReset && now - lastClickAt < Self.doubleClickInterval {
            lastClickAt = 0
            reset()
            return
        }
        lastClickAt = now

        toggle(optionHeld: optionHeld)
    }

    private func toggle(optionHeld: Bool) {
        if stopwatch.isRunning {
            stop()
            return
        }

        if reverseClickActions {
            optionHeld ? resume() : startFromZero()
        } else {
            optionHeld ? startFromZero() : resume()
        }
    }

    @objc private func selectClickMode(_ sender: NSMenuItem) {
        reverseClickActions = sender.tag == 1
        for item in clickModeItems { item.state = item.tag == sender.tag ? .on : .off }
    }

    @objc private func toggleMilliseconds() {
        showMilliseconds.toggle()
        millisecondsItem.state = showMilliseconds ? .on : .off
        updateText()
    }

    @objc private func toggleFloating() {
        showFloating.toggle()
        floatingItem.state = showFloating ? .on : .off
        updateFloatingPanel()
        updateText()
    }

    private func updateFloatingPanel() {
        guard showFloating else {
            floatingPanel?.orderOut(nil)
            return
        }
        if floatingPanel == nil {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.ignoresMouseEvents = false
            floatingPanel = panel
            applyFloatingStyle()
            floatingView.text = format(stopwatch.elapsed)
            placeFloating()
        }
        floatingPanel?.orderFrontRegardless()
    }

    @objc private func selectFloatingStyle(_ sender: NSMenuItem) {
        floatingStyle = sender.tag
        applyFloatingStyle()
        updateCustomizeCheckmarks()
    }

    private func applyFloatingStyle() {
        var style = FloatingTextView.Style(rawValue: floatingStyle) ?? .outline
        guard let panel = floatingPanel else { return }
        floatingView.removeFromSuperview()
        floatingView.autoresizingMask = [.width, .height]
        if style == .glass, #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = floatingView.cornerRadius
            panel.contentView = glass
            floatingView.frame = glass.bounds
            glass.contentView = floatingView
        } else {
            if style == .glass { style = .dark } // no Liquid Glass before macOS 26
            panel.contentView = floatingView
        }
        floatingView.style = style
    }

    @objc private func selectFloatingSize(_ sender: NSMenuItem) {
        floatingSize = sender.tag
        applyFloatingFont()
    }

    @objc private func selectFloatingDesign(_ sender: NSMenuItem) {
        floatingDesign = sender.representedObject as! String
        applyFloatingFont()
    }

    private func applyFloatingFont() {
        let size = CGFloat(floatingSize)
        let base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .heavy)
        let descriptor = base.fontDescriptor.withDesign(NSFontDescriptor.SystemDesign(rawValue: floatingDesign)) ?? base.fontDescriptor
        let embolden: CGFloat = floatingDesign == "PTMono-Bold" ? 0.02 : 0
        floatingView.embolden = embolden
        // PT Mono's default zero is slashed; zero.alt is the plain one (same width, it's monospaced)
        floatingView.glyphSubstitutions = floatingDesign == "PTMono-Bold" ? ["zero": "zero.alt"] : [:]
        floatingView.punctuationScale = floatingDesign == "PTMono-Bold" ? 0.6 : 1
        let font = NSFont(name: floatingDesign, size: size) ?? NSFont(descriptor: descriptor, size: size) ?? base
        // scale so the digits are exactly as tall as SF's at this size (embolden adds to both top and bottom)
        let scale = FloatingTextView.digitHeight(base) / (FloatingTextView.digitHeight(font) + 2 * embolden * size)
        floatingView.font = NSFont(descriptor: font.fontDescriptor, size: size * scale) ?? font
        applyFloatingStyle() // glass corner radius follows the font size
        updateCustomizeCheckmarks()
    }

    private func updateCustomizeCheckmarks() {
        // green to red counts toward the flash time; without one, fall back to gray
        if blinkAfter == 0 { floatingColor = 0 }
        for item in alertSoundItems { item.isHidden = blinkAfter == 0 } // sound only matters with a timer
        for item in alertSoundMenus.flatMap(\.items) { item.state = item.representedObject as? String == alertSound ? .on : .off }
        for item in customizeMenu.items where !item.isSeparatorItem {
            let selected: Bool
            switch item.action {
            case #selector(selectFloatingStyle): selected = item.tag == floatingStyle
            case #selector(selectFloatingSize): selected = item.tag == floatingSize
            case #selector(selectFloatingColor):
                selected = item.tag == floatingColor
                // green to red needs a flash time to count toward
                item.isEnabled = item.tag == 0 || blinkAfter > 0
            default: selected = item.representedObject as? String == floatingDesign
            }
            item.state = selected ? .on : .off
        }
    }

    // visibleFrame excludes the menu bar and the Dock
    private func floatingFrame(spot: Int, size: NSSize, in screen: NSRect) -> NSRect {
        let padding = Self.floatingSpotPadding
        let xs = [screen.minX + padding, screen.midX - size.width / 2, screen.maxX - size.width - padding]
        let ys = [screen.maxY - size.height - padding, screen.minY + padding]
        return NSRect(origin: NSPoint(x: xs[spot % 3], y: ys[spot / 3]), size: size)
    }

    // keeps the window at least floatingSpotPadding inside the visible frame of the screen containing `point`
    // (default: the window's center)
    private func clampedFloatingOrigin(_ origin: NSPoint, on point: NSPoint? = nil) -> NSPoint {
        guard let size = floatingPanel?.frame.size else { return origin }
        let point = point ?? NSPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        guard let screen = (NSScreen.screens.first { $0.frame.contains(point) } ?? floatingPanel?.screen ?? NSScreen.main)?.visibleFrame
        else { return origin }
        let area = screen.insetBy(dx: Self.floatingSpotPadding, dy: Self.floatingSpotPadding)
        return NSPoint(x: min(max(origin.x, area.minX), area.maxX - size.width),
                       y: min(max(origin.y, area.minY), area.maxY - size.height))
    }

    private func placeFloating(animate: Bool = false) {
        guard let panel = floatingPanel, let screen = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        // right after launch the window is still empty; it's placed again once the text sizes it
        guard panel.frame.width > 0 else { return }
        if floatingSpot < 0, let saved = UserDefaults.standard.string(forKey: Self.floatingOriginKey) {
            // clamping also pulls back a position left off screen by an unplugged or resized display
            panel.setFrameOrigin(clampedFloatingOrigin(NSPointFromString(saved)))
            return
        }
        panel.setFrame(floatingFrame(spot: floatingSpot, size: panel.frame.size, in: screen), display: true, animate: animate)
    }

    // after a drag, jump to the nearest spot if it's close enough, otherwise stay where dropped
    private func snapFloating() {
        guard let panel = floatingPanel, let screen = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let distances = (0..<6).map { spot -> CGFloat in
            let frame = floatingFrame(spot: spot, size: panel.frame.size, in: screen)
            return hypot(frame.midX - center.x, frame.midY - center.y)
        }
        let nearest = distances.indices.min { distances[$0] < distances[$1] }!
        if distances[nearest] <= Self.floatingSnapDistance {
            floatingSpot = nearest
            placeFloating(animate: true)
        } else {
            floatingSpot = -1
            UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: Self.floatingOriginKey)
        }
    }

    @objc private func toggleDoubleClickReset() {
        doubleClickToReset.toggle()
        doubleClickResetItem.state = doubleClickToReset ? .on : .off
    }

    @objc private func selectBlinkAfter(_ sender: NSMenuItem) {
        setTimer(sender.tag)
    }

    private func setTimer(_ seconds: Int) {
        blinkAfter = seconds
        // changing the timer never sounds the alert; only time passing the alert time does
        alertDone = blinkAfter > 0 && stopwatch.elapsed >= Double(blinkAfter)
        updateTimerCheckmarks()
        updateCustomizeCheckmarks()
        updateText()
    }

    private func updateTimerCheckmarks() {
        for item in timerMenus.flatMap(\.items) where item.action == #selector(selectBlinkAfter) {
            item.state = item.tag == blinkAfter ? .on : .off
        }
        for view in customTimerViews { view.show(blinkAfter) }
    }

    @objc private func selectAlertSound(_ sender: NSMenuItem) {
        alertSound = sender.representedObject as! String
        updateCustomizeCheckmarks()
    }

    @objc private func selectFloatingColor(_ sender: NSMenuItem) {
        floatingColor = sender.tag
        updateCustomizeCheckmarks()
        updateText()
    }

    // blends through the system green, yellow, orange and red, reaching red exactly at the flash time.
    // Ease-in (progress squared): stays green longer, then changes faster toward the end.
    private func progressColor(elapsed: TimeInterval) -> NSColor {
        let stops: [NSColor] = [.systemGreen, .systemYellow, .systemOrange, .systemRed]
        let progress = CGFloat(min(max(elapsed / Double(blinkAfter), 0), 1))
        let scaled = progress * progress * CGFloat(stops.count - 1)
        let index = min(Int(scaled), stops.count - 2)
        guard let from = stops[index].usingColorSpace(.sRGB), let to = stops[index + 1].usingColorSpace(.sRGB) else { return .systemRed }
        return from.blended(withFraction: scaled - CGFloat(index), of: to) ?? from
    }

    private static func blinkLabel(_ seconds: Int) -> String {
        guard seconds > 0 else { return "None" }
        let m = seconds / 60, s = seconds % 60
        let parts = [
            m > 0 ? "\(m) minute\(m == 1 ? "" : "s")" : nil,
            s > 0 ? "\(s) seconds" : nil
        ]
        return parts.compactMap { $0 }.joined(separator: " ")
    }

    // title with a gray hint line under it (instead of item.subtitle, whose spacing can't be adjusted)
    private static func titleWithHint(_ title: String, _ hint: String, italic: Bool = false) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = 3 // gap between title and hint
        let attributed = NSMutableAttributedString(string: title + "\n", attributes: [.font: NSFont.menuFont(ofSize: 0)])
        attributed.append(NSAttributedString(string: hint, attributes: [
            .font: italic
                ? NSFontManager.shared.convert(NSFont.menuFont(ofSize: NSFont.smallSystemFontSize), toHaveTrait: .italicFontMask)
                : NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ]))
        return attributed
    }

    private func stop() {
        stopwatch.stop()
        stopTimer()
        updateText()
    }

    private func resume() {
        stopwatch.resume()
        startTimer()
        updateText()
    }

    private func startFromZero() {
        stopwatch.startFromZero()
        startTimer()
        updateText()
    }

    private func reset() {
        stopwatch.reset()
        stopTimer()
        updateText()
    }

    private func startTimer() {
        timer?.invalidate()
        let newTimer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            self?.updateText()
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func updateText() {
        let text = format(stopwatch.elapsed)
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font]
        let width = NSAttributedString(string: text, attributes: attrs).size().width + Self.horizontalPadding * 2
        statusItem.length = width
        let sinceThreshold = stopwatch.elapsed - Double(blinkAfter)
        let timeUp = blinkAfter > 0 && sinceThreshold >= 0
        // play once when a running stopwatch crosses the alert time; re-arms after reset or start from zero
        if timeUp && !alertDone && stopwatch.isRunning { Self.sound(alertSound)?.play() }
        alertDone = timeUp
        // with the floating stopwatch showing, it carries the red; the menu bar stays plain
        if timeUp && !showFloating {
            statusItem.button?.attributedTitle = NSAttributedString(string: text, attributes: [
                .font: Self.font, .foregroundColor: NSColor.systemRed
            ])
        } else {
            statusItem.button?.title = text
        }
        // flash 2 times while running: dimmed for the first half of each of the 2 seconds after the threshold
        let blinkOff = Self.flashWhenTimeUp && stopwatch.isRunning && timeUp && sinceThreshold < 2
            && sinceThreshold.truncatingRemainder(dividingBy: 1) < 0.5
        statusItem.button?.alphaValue = blinkOff ? 0.35 : 1
        if showFloating {
            floatingView.text = text
            floatingView.textAlpha = blinkOff ? 0.35 : 1
            floatingView.textColorOverride = timeUp ? .systemRed
                : floatingColor == 1 && blinkAfter > 0 ? progressColor(elapsed: stopwatch.elapsed) : nil
        }
    }

    private func format(_ interval: TimeInterval) -> String {
        let totalCentiseconds = Int(interval * 100)
        let hours = totalCentiseconds / 360000
        let minutes = (totalCentiseconds % 360000) / 6000
        let seconds = (totalCentiseconds % 6000) / 100
        let minutesPart = hours > 0 ? String(format: "%d:%02d", hours, minutes) : String(format: "%02d", minutes)
        guard showMilliseconds else {
            return "\(minutesPart):\(String(format: "%02d", seconds))"
        }
        let centiseconds = totalCentiseconds % 100
        return "\(minutesPart):\(String(format: "%02d.%02d", seconds, centiseconds))"
    }

    @objc private func resetAction() {
        reset()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
