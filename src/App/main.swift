import AppKit

// TailBridge GUI. Runs as the user. Launch only reads state; every change is an explicit click.

// MARK: - Small views

/// Wrapping label that reports the right height for its current width.
final class WrappingLabel: NSTextField {
    override func layout() {
        super.layout()
        if preferredMaxLayoutWidth != bounds.width {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

func label(_ s: String, font: NSFont = .systemFont(ofSize: NSFont.systemFontSize), color: NSColor = .labelColor) -> NSTextField {
    let l = NSTextField(labelWithString: s)
    l.font = font
    l.textColor = color
    return l
}

func wrapping(_ s: String, font: NSFont = .systemFont(ofSize: NSFont.systemFontSize), color: NSColor = .labelColor) -> WrappingLabel {
    let l = WrappingLabel(wrappingLabelWithString: s)
    l.font = font
    l.textColor = color
    l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return l
}

func symbolView(pointSize: CGFloat = 13) -> NSImageView {
    let v = NSImageView()
    v.symbolConfiguration = .init(pointSize: pointSize, weight: .regular)
    v.setContentHuggingPriority(.required, for: .horizontal)
    v.setContentCompressionResistancePriority(.required, for: .horizontal)
    return v
}

func setSymbol(_ v: NSImageView, _ name: String, _ color: NSColor, _ description: String) {
    v.image = NSImage(systemSymbolName: name, accessibilityDescription: description)
    v.contentTintColor = color
}

func hstack(_ views: [NSView], spacing: CGFloat = 8, align: NSLayoutConstraint.Attribute = .firstBaseline) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .horizontal
    s.alignment = align
    s.spacing = spacing
    return s
}

func vstack(_ views: [NSView], spacing: CGFloat = 6) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .vertical
    s.alignment = .leading
    s.spacing = spacing
    return s
}

/// Makes `v` as wide as `stack`'s content area.
func fill(_ v: NSView, _ stack: NSStackView) {
    v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true
}

/// Width of the widest label, so grid label columns don't absorb spare space.
func labelWidth(_ texts: [String]) -> CGFloat {
    ceil(texts.map { label($0).fittingSize.width }.max() ?? 0)
}

let sectionFont = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
let smallFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

/// One-line message shown inside the section it belongs to: icon, short text, next step.
final class NoticeView: NSStackView {
    typealias Kind = NoticeKind
    let icon = symbolView()
    let text = wrapping("")
    private(set) var state: NoticeState?

    convenience init() {
        self.init(frame: .zero)
        orientation = .horizontal
        alignment = .firstBaseline
        spacing = 6
        distribution = .fill
        addArrangedSubview(icon)
        addArrangedSubview(text)
        text.setContentHuggingPriority(.init(1), for: .horizontal)
        isHidden = true
    }

    func show(_ kind: Kind, _ message: String) { render(NoticeState(kind, message)) }

    /// Appends to a visible message without downgrading it; shows a new one otherwise.
    func add(_ kind: Kind, _ message: String) { render(state.map { $0.adding(kind, message) } ?? NoticeState(kind, message)) }

    /// Hides the message once the state it was written for has changed. Returns true if it was hidden.
    @discardableResult func refresh(context: String, idle: Bool) -> Bool {
        guard let s = state else { return false }
        guard let next = s.refreshed(context: context, idle: idle) else { hide(); return true }
        state = next
        return false
    }

    private func render(_ s: NoticeState) {
        state = s
        switch s.kind {
        case .success: setSymbol(icon, "checkmark.circle.fill", .systemGreen, L("tone.ok"))
        case .info: setSymbol(icon, "info.circle", .secondaryLabelColor, L("notice.info"))
        case .warning: setSymbol(icon, "exclamationmark.triangle.fill", .systemOrange, L("tone.warning"))
        case .error: setSymbol(icon, "xmark.octagon.fill", .systemRed, L("tone.error"))
        }
        text.stringValue = s.message
        isHidden = false
    }

    func hide() { isHidden = true; text.stringValue = ""; state = nil }
}

/// Native disclosure triangle with a clickable title and a collapsible content view.
final class Disclosure: NSObject {
    let triangle = NSButton()
    let title: NSButton
    let content: NSView
    let view: NSStackView
    var onToggle: (() -> Void)?

    init(_ text: String, content: NSView, font: NSFont = sectionFont) {
        self.content = content
        title = NSButton(title: text, target: nil, action: nil)
        title.isBordered = false
        title.font = font
        title.refusesFirstResponder = true   // the triangle carries keyboard focus
        title.cell?.setAccessibilityElement(false)   // VoiceOver reads the triangle, labeled with the same text
        triangle.bezelStyle = .disclosure
        triangle.setButtonType(.pushOnPushOff)
        triangle.title = ""
        triangle.setAccessibilityLabel(text)
        view = vstack([hstack([triangle, title], spacing: 2, align: .centerY), content], spacing: 8)
        super.init()
        triangle.target = self
        triangle.action = #selector(triangleClicked)
        title.target = self
        title.action = #selector(titleClicked)
        content.isHidden = true
    }

    var isExpanded: Bool {
        get { triangle.state == .on }
        set { triangle.state = newValue ? .on : .off; content.isHidden = !newValue }
    }

    @objc func triangleClicked() { content.isHidden = triangle.state != .on; onToggle?() }
    @objc func titleClicked() { isExpanded.toggle(); onToggle?() }
}

/// Separate window for the full log and diagnostics, opened on demand.
final class LogWindow: NSObject {
    let window: NSWindow
    let text = NSTextView()

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 420),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.title = L("log.title")
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentMinSize = NSSize(width: 420, height: 240)
        super.init()
        text.isEditable = false
        text.isRichText = true
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.setAccessibilityLabel(L("log.title"))
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let copy = NSButton(title: L("log.copyAll"), target: self, action: #selector(copyAll))
        let clear = NSButton(title: L("log.clear"), target: self, action: #selector(clear))
        let note = label(L("log.privacy"), font: smallFont, color: .secondaryLabelColor)
        note.lineBreakMode = .byTruncatingTail
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bar = hstack([note, NSView(), copy, clear], align: .centerY)
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 10, right: 12)
        bar.translatesAutoresizingMaskIntoConstraints = false
        let sep = NSBox(); sep.boxType = .separator; sep.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        [scroll, sep, bar].forEach(content.addSubview)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            sep.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            sep.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.topAnchor.constraint(equalTo: sep.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
    }

    func append(_ s: String, color: NSColor = .labelColor, bold: Bool = false) {
        let font: NSFont = .monospacedSystemFont(ofSize: 11, weight: bold ? .bold : .regular)
        text.textStorage?.append(NSAttributedString(string: s + "\n", attributes: [.foregroundColor: color, .font: font]))
        text.scrollToEndOfDocument(nil)
    }

    func show(relativeTo main: NSWindow) {
        if !window.isVisible {
            window.setFrameTopLeftPoint(NSPoint(x: main.frame.maxX + 12, y: main.frame.maxY))
            if let screen = main.screen, !screen.visibleFrame.contains(window.frame) { window.center() }
        }
        window.makeKeyAndOrderFront(nil)
    }

    @objc func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text.string, forType: .string)
    }
    @objc func clear() { text.string = "" }
}

// MARK: - Controller

final class Controller: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate, NSMenuItemValidation {
    var window: NSWindow!
    let log = LogWindow()
    let stack = NSStackView()
    let docView = FlippedView()

    // Status header
    let stateIcon = symbolView(pointSize: 30)
    let stateTitle = label("", font: .systemFont(ofSize: 20, weight: .semibold))
    let stateDetail = wrapping("", color: .secondaryLabelColor)
    let primaryButton = NSButton(title: L("action.enable"), target: nil, action: nil)
    let cleanupButton = NSButton(title: L("action.disable"), target: nil, action: nil)
    let headerNotice = NoticeView()

    // Connections
    let mullvadIcon = symbolView(), mullvadValue = label(""), mullvadSecondary = label("", color: .secondaryLabelColor)
    let tailscaleIcon = symbolView(), tailscaleValue = label(""), tailscaleSecondary = label("", color: .secondaryLabelColor)
    let dnsWarningIcon = symbolView(), dnsWarningText = wrapping("", font: smallFont, color: .secondaryLabelColor)
    var dnsWarning = NSView()
    let techGrid = NSGridView(numberOfColumns: 3, rows: 0)
    var techDisclosure: Disclosure!

    // Connection Test
    let peerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    var peers: [Peer] = []
    let peerField = NSTextField(string: UserDefaults.standard.string(forKey: "peer") ?? "")
    let nameField = NSTextField(string: UserDefaults.standard.string(forKey: "name") ?? "")
    let portField = NSTextField(string: UserDefaults.standard.string(forKey: "port") ?? "22")
    var advancedDisclosure: Disclosure!
    let testButton = NSButton(title: L("test.run"), target: nil, action: nil)
    let testNotice = NoticeView()
    let resultsSummary = label(L("test.none"), color: .secondaryLabelColor)
    let resultsStack = vstack([], spacing: 8)
    /// The whole section collapses to its heading and a one-line summary; only the user collapses it.
    var testDisclosure: Disclosure!
    let testCollapsedIcon = symbolView(), testCollapsedText = wrapping("")
    var testCollapsedRow = NSStackView()
    /// The collapsed line may change height (it wraps), so the window is refitted while collapsed.
    var testOutcome = TestOutcome.none {
        didSet { showCollapsedTest(); if !testDisclosure.isExpanded { fitWindow(shrinkOnly: userSized) } }
    }

    // Footer and Administration
    let updatedLabel = label("", font: smallFont, color: .secondaryLabelColor)
    let spinner = NSProgressIndicator()
    let busyLabel = label("", font: smallFont, color: .secondaryLabelColor)
    let adminNotice = NoticeView()
    var adminDisclosure: Disclosure!

    var actionButtons: [NSButton] = []
    var snapshot = Snapshot()
    var isBusy = false
    var timer: Timer?
    /// After the user resizes the window, refreshes only shrink it, never grow it back.
    var userSized = false
    /// True while fitWindow itself resizes the window.
    var fittingWindow = false
    /// Fields and state the shown test results belong to.
    var lastRun: TestRun?
    /// When the last action finished; snapshots started before it may show intermediate state.
    var idleSince = Date.distantPast

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        buildWindow()
        show(snapshot)
        refresh()
        loadPeers()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    func windowWillClose(_ n: Notification) { if n.object as? NSWindow === window { NSApp.terminate(nil) } }

    // MARK: Menu

    /// Standard About panel with the version, channel and build from Info.plist (see aboutInfo).
    @objc func showAbout() {
        let a = aboutInfo(Bundle.main.infoDictionary ?? [:])
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let credits = NSAttributedString(string: a.credits, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ])
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.applicationVersion: a.version, .version: a.build, .credits: credits])
    }

    func buildMenu() {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(); let m = NSMenu(title: title)
            items.forEach(m.addItem)
            item.submenu = m
            main.addItem(item)
        }
        func item(_ title: String, _ sel: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            return i
        }
        submenu("TailBridge", [
            item(L("menu.about"), #selector(showAbout), target: self),
            .separator(),
            item(L("menu.hide"), #selector(NSApplication.hide(_:)), "h"),
            item(L("menu.hideOthers"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item(L("menu.showAll"), #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item(L("menu.quit"), #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu(L("menu.edit"), [
            item(L("menu.undo"), Selector(("undo:")), "z"),
            item(L("menu.redo"), Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item(L("menu.cut"), #selector(NSText.cut(_:)), "x"),
            item(L("menu.copy"), #selector(NSText.copy(_:)), "c"),
            item(L("menu.paste"), #selector(NSText.paste(_:)), "v"),
            item(L("menu.selectAll"), #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu(L("menu.actions"), [
            item(L("menu.enable"), #selector(enable), target: self),
            item(L("menu.disable"), #selector(disable), target: self),
            .separator(),
            item(L("test.run"), #selector(runChecks), "t", target: self),
            item(L("action.refresh"), #selector(refreshClicked), "r", target: self),
            .separator(),
            item(L("action.diagnostics"), #selector(diagnostics), "d", [.command, .option], target: self),
            item(L("action.showLog"), #selector(showLog), "l", target: self),
        ])
        submenu(L("menu.window"), [
            item(L("menu.minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"),
            item(L("menu.close"), #selector(NSWindow.performClose(_:)), "w"),
        ])
        NSApp.mainMenu = main
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        // Same rule as the primary button: no password prompt for an Enable that would be refused.
        case #selector(enable): return !isBusy && snapshot.headline.canEnable
        // Disable stays available as the fallback cleanup route, as before.
        case #selector(disable), #selector(runChecks), #selector(refreshClicked), #selector(diagnostics):
            return !isBusy
        default: return true
        }
    }

    // MARK: Window

    func actionButton(_ title: String, _ sel: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: sel)
        b.bezelStyle = .rounded
        actionButtons.append(b)
        return b
    }

    func separator() -> NSBox { let b = NSBox(); b.boxType = .separator; return b }

    func buildHeader() -> NSView {
        primaryButton.bezelStyle = .rounded
        primaryButton.controlSize = .large
        primaryButton.target = self
        primaryButton.action = #selector(primaryClicked)
        primaryButton.setContentHuggingPriority(.required, for: .horizontal)
        primaryButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        primaryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        actionButtons.append(primaryButton)
        cleanupButton.bezelStyle = .rounded
        cleanupButton.controlSize = .large
        cleanupButton.target = self
        cleanupButton.action = #selector(disable)
        cleanupButton.toolTip = L("action.cleanupHelp")
        cleanupButton.setAccessibilityHelp(L("action.cleanupHelp"))
        cleanupButton.setContentHuggingPriority(.required, for: .horizontal)
        cleanupButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        cleanupButton.isHidden = true
        actionButtons.append(cleanupButton)
        stateTitle.lineBreakMode = .byTruncatingTail
        stateTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let texts = vstack([stateTitle, stateDetail], spacing: 3)
        let buttons = hstack([cleanupButton, primaryButton], spacing: 8, align: .centerY)
        buttons.setHuggingPriority(.required, for: .horizontal)
        let row = hstack([stateIcon, texts, buttons], spacing: 12, align: .top)
        row.distribution = .fill
        texts.setHuggingPriority(.init(1), for: .horizontal)
        fill(stateDetail, texts)
        fill(stateTitle, texts)
        stateIcon.widthAnchor.constraint(equalToConstant: 36).isActive = true
        let scope = wrapping(L("header.scope"), font: smallFont, color: .secondaryLabelColor)
        let header = vstack([row, scope, headerNotice], spacing: 8)
        for v in [row, scope, headerNotice] { fill(v, header) }
        return header
    }

    func statusRow(_ name: String, _ icon: NSImageView, _ value: NSTextField, _ secondary: NSTextField) -> [NSView] {
        value.setContentHuggingPriority(.required, for: .horizontal)
        secondary.lineBreakMode = .byTruncatingTail
        secondary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return [icon, label(name, color: .labelColor), hstack([value, secondary], spacing: 8)]
    }

    func buildConnections() -> NSView {
        let grid = NSGridView(views: [
            statusRow(L("conn.mullvad"), mullvadIcon, mullvadValue, mullvadSecondary),
            statusRow(L("conn.tailscale"), tailscaleIcon, tailscaleValue, tailscaleSecondary),
        ])
        grid.columnSpacing = 8
        grid.rowSpacing = 6
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).width = 18
        grid.column(at: 1).width = 96

        techGrid.columnSpacing = 8
        techGrid.rowSpacing = 5
        techGrid.rowAlignment = .firstBaseline
        techGrid.column(at: 0).xPlacement = .trailing
        techGrid.column(at: 0).leadingPadding = 20
        techGrid.column(at: 0).width = labelWidth(["tech.interface", "tech.addresses", "tech.helper", "tech.pf",
                                                   "tech.resolver", "tech.env", "tech.legacy"].map { L($0) })
        techGrid.column(at: 1).width = 16
        techGrid.column(at: 2).xPlacement = .leading
        techDisclosure = Disclosure(L("tech.title"), content: techGrid, font: .systemFont(ofSize: NSFont.systemFontSize))
        techDisclosure.onToggle = { [weak self] in self?.fitWindow() }

        setSymbol(dnsWarningIcon, Tone.warning.symbol, Tone.warning.color, Tone.warning.label)
        dnsWarningText.setContentHuggingPriority(.init(1), for: .horizontal)   // use the full width, as NoticeView does
        let dnsWarning = hstack([dnsWarningIcon, dnsWarningText], spacing: 6, align: .top)
        self.dnsWarning = dnsWarning
        dnsWarning.isHidden = true

        let section = vstack([label(L("conn.title"), font: sectionFont), grid, dnsWarning, techDisclosure.view], spacing: 8)
        for v in [grid, dnsWarning, techDisclosure.view] { fill(v, section) }
        return section
    }

    func buildTest() -> NSView {
        let intro = wrapping(L("test.intro"), color: .secondaryLabelColor)

        peerPopup.target = self
        peerPopup.action = #selector(peerChosen)
        peerPopup.addItem(withTitle: L("test.loadingDevices"))
        peerPopup.setAccessibilityLabel(L("test.device"))
        peerPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        peerPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        peerPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        testButton.target = self
        testButton.action = #selector(runChecks)
        testButton.bezelStyle = .rounded
        testButton.setContentHuggingPriority(.required, for: .horizontal)
        actionButtons.append(testButton)
        let deviceRow = hstack([label(L("test.deviceLabel")), peerPopup, testButton], align: .centerY)

        peerField.placeholderString = "100.x.y.z"
        nameField.placeholderString = L("test.namePlaceholder")
        portField.placeholderString = "22"
        let fields: [(NSTextField, String, CGFloat)] = [(peerField, L("test.ip"), 150), (nameField, L("test.name"), 200), (portField, L("test.port"), 64)]
        for (f, name, w) in fields {
            f.delegate = self
            f.setAccessibilityLabel(name)
            f.widthAnchor.constraint(equalToConstant: w).isActive = true
        }
        let advGrid = NSGridView(views: fields.map { [label($0.1), $0.0] })
        advGrid.rowAlignment = .firstBaseline
        advGrid.columnSpacing = 8
        advGrid.rowSpacing = 6
        advGrid.column(at: 0).xPlacement = .trailing
        advGrid.column(at: 0).width = labelWidth(fields.map { $0.1 })
        advGrid.column(at: 1).xPlacement = .leading
        let advHint = wrapping(L("test.advancedHint"), font: smallFont, color: .secondaryLabelColor)
        let adv = vstack([advHint, advGrid], spacing: 8)
        adv.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        fill(advHint, adv)
        advancedDisclosure = Disclosure(L("test.advanced"), content: adv, font: .systemFont(ofSize: NSFont.systemFontSize))
        advancedDisclosure.onToggle = { [weak self] in self?.fitWindow() }

        let disclaimer = wrapping(L("test.disclaimer"), font: smallFont, color: .secondaryLabelColor)
        resultsStack.isHidden = true
        resultsSummary.lineBreakMode = .byTruncatingTail
        resultsSummary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let body = vstack([intro, deviceRow, advancedDisclosure.view, testNotice, resultsSummary, resultsStack, disclaimer], spacing: 8)
        body.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        body.setCustomSpacing(12, after: advancedDisclosure.view)
        for v in [intro, deviceRow, advancedDisclosure.view, testNotice, resultsSummary, resultsStack, disclaimer] { fill(v, body) }
        fill(adv, advancedDisclosure.view)

        testDisclosure = Disclosure(L("test.title"), content: body)
        testDisclosure.isExpanded = true
        testDisclosure.onToggle = { [weak self] in self?.showCollapsedTest(); self?.fitWindow() }
        // Wraps instead of truncating, so counts and the test time stay visible at the minimum width.
        testCollapsedText.setContentHuggingPriority(.init(1), for: .horizontal)
        testCollapsedRow = hstack([testCollapsedIcon, testCollapsedText], spacing: 6)
        testCollapsedRow.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        testCollapsedRow.setAccessibilityElement(true)
        testDisclosure.view.addArrangedSubview(testCollapsedRow)
        fill(body, testDisclosure.view)
        fill(testCollapsedRow, testDisclosure.view)
        showCollapsedTest()
        return testDisclosure.view
    }

    /// Summary line under the collapsed heading; hidden while the section is expanded.
    func showCollapsedTest() {
        guard testDisclosure != nil else { return }
        let line = collapsedTestLine(testOutcome)
        // line.help names the status in words; the disclaimer (hidden while collapsed) goes to tooltip and AX help.
        setSymbol(testCollapsedIcon, line.tone.symbol, line.tone.color, line.help ?? line.tone.label)
        testCollapsedText.stringValue = line.value
        testCollapsedRow.toolTip = "\(line.help ?? line.tone.label): \(line.value)\n" + L("test.disclaimer")
        testCollapsedRow.setAccessibilityLabel("\(L("test.title")): \(line.help ?? line.tone.label). \(line.value)")
        testCollapsedRow.setAccessibilityHelp(L("test.disclaimer"))
        testCollapsedRow.isHidden = testDisclosure.isExpanded
    }

    func buildAdmin() -> NSView {
        let intro = wrapping(L("admin.intro"), font: smallFont, color: .secondaryLabelColor)
        let buttons = hstack([actionButton(L("admin.install"), #selector(installHelper)),
                              actionButton(L("admin.uninstall"), #selector(uninstallHelper))], align: .centerY)
        let content = vstack([intro, buttons, adminNotice], spacing: 8)
        content.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        fill(intro, content)
        fill(adminNotice, content)
        adminDisclosure = Disclosure(L("admin.title"), content: content, font: .systemFont(ofSize: NSFont.systemFontSize))
        adminDisclosure.onToggle = { [weak self] in self?.fitWindow() }
        fill(content, adminDisclosure.view)
        return adminDisclosure.view
    }

    func buildFooter() -> NSView {
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let footer = hstack([actionButton(L("action.refresh"), #selector(refreshClicked)),
                             actionButton(L("action.diagnostics"), #selector(diagnostics)),
                             NSButton(title: L("action.showLog"), target: self, action: #selector(showLog)),
                             NSView(), spinner, busyLabel, updatedLabel], align: .centerY)
        return footer
    }

    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "TailBridge"
        window.subtitle = L("window.subtitle")
        window.isRestorable = false
        window.delegate = self
        window.contentMinSize = NSSize(width: 560, height: 320)

        let sections: [NSView] = [buildHeader(), separator(), buildConnections(), separator(), buildTest(),
                                  separator(), buildAdmin(), buildFooter()]
        sections.forEach(stack.addArrangedSubview)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        stack.setCustomSpacing(12, after: sections[6])
        stack.translatesAutoresizingMaskIntoConstraints = false
        sections.forEach { fill($0, stack) }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        docView.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = docView
        docView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: docView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: docView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: docView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: docView.bottomAnchor),
            docView.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            docView.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            docView.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        window.contentView = scroll
        window.autorecalculatesKeyViewLoop = true
        window.center()
        fitWindow(animate: false)
        window.center()
        window.initialFirstResponder = primaryButton
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Height of the laid-out content at the current width.
    func contentHeight() -> CGFloat {
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()   // second pass after wrapping labels learn their width
        return ceil(docView.fittingSize.height)
    }

    /// Fits the window to its content, never taller than the screen. `shrinkOnly` keeps a shorter window as is.
    func fitWindow(animate: Bool = true, shrinkOnly: Bool = false) {
        guard let window = window else { return }
        let h = contentHeight()
        window.contentMaxSize = NSSize(width: 10000, height: max(h, window.contentMinSize.height))
        let current = window.contentLayoutRect.height
        if shrinkOnly && current <= h { return }
        // Auto-fit stops at a comfortable height; the user can still drag the window up to the full content.
        let limit = min(((window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900) - 40, 860)
        let target = min(max(h, window.contentMinSize.height), limit)
        guard abs(target - current) > 0.5 else { return }
        var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: window.contentLayoutRect.width, height: target))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        if let screen = window.screen, frame.minY < screen.visibleFrame.minY { frame.origin.y = screen.visibleFrame.minY }
        // An animated setFrame also posts live-resize notifications; they must not count as the user's resize.
        fittingWindow = true
        window.setFrame(frame, display: true, animate: animate && window.isVisible)
        fittingWindow = false
    }

    func windowDidEndLiveResize(_ n: Notification) {
        guard !fittingWindow else { return }
        userSized = true
        fitWindow(animate: false, shrinkOnly: true)
    }

    // MARK: Logging and busy state

    func append(_ text: String, color: NSColor = .labelColor, bold: Bool = false) { log.append(text, color: color, bold: bold) }
    func onMain(_ f: @escaping () -> Void) { DispatchQueue.main.async(execute: f) }
    /// Log line from a background task.
    func say(_ s: String, _ c: NSColor = .labelColor) { onMain { self.append(s, color: c) } }
    /// Short message shown in a section; also logged.
    /// `followUp` appends to the visible message instead of replacing it (an error stays an error).
    func notify(_ notice: NoticeView, _ kind: NoticeView.Kind, _ s: String, followUp: Bool = false) {
        onMain {
            if followUp { notice.add(kind, s) } else { notice.show(kind, s) }
            let c: NSColor = [.success: .systemGreen, .warning: .systemOrange, .error: .systemRed][kind] ?? .labelColor
            self.append(s, color: c)
            self.fitWindow()
        }
    }

    /// Runs work off the main thread with action buttons disabled.
    func busy(_ title: String, _ work: @escaping () -> Void) {
        isBusy = true
        actionButtons.forEach { $0.isEnabled = false }
        spinner.startAnimation(nil)
        busyLabel.stringValue = L("common.working", title)
        updatedLabel.isHidden = true
        append("\n▶ \(title) — \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))", bold: true)
        DispatchQueue.global(qos: .userInitiated).async {
            work()
            DispatchQueue.main.async {
                self.isBusy = false
                self.spinner.stopAnimation(nil)
                self.busyLabel.stringValue = ""
                self.updatedLabel.isHidden = false
                self.idleSince = Date()
                self.actionButtons.forEach { $0.isEnabled = $0 !== self.primaryButton && $0 !== self.cleanupButton }   // show() sets these
                self.refresh()
            }
        }
    }

    @objc func showLog() { log.show(relativeTo: window) }

    // MARK: State

    @objc func refreshClicked() { refresh(); loadPeers() }

    /// Fills the picker. The list stays in memory only; it is never logged or saved.
    func loadPeers() {
        DispatchQueue.global(qos: .userInitiated).async {
            let list = PeerList.load()
            DispatchQueue.main.async { self.showPeers(list) }
        }
    }

    func showPeers(_ list: [Peer]?) {
        peers = list ?? []
        peerPopup.removeAllItems()
        let first: String
        if list == nil { first = L("test.devicesUnavailable") }
        else if peers.isEmpty { first = L("test.noDevices") }
        else { first = L("test.chooseDevice") }
        peerPopup.addItem(withTitle: first)
        for p in peers {
            let name = p.name.isEmpty ? L("test.unnamed") : p.name
            peerPopup.addItem(withTitle: p.online ? L("test.deviceItem", name, p.ip4) : L("test.deviceItemOffline", name, p.ip4))
        }
        syncPopupToFields()
    }

    /// Selects the device matching both fields, or the first item marked as a custom target.
    func syncPopupToFields() {
        if let i = matchingPeer(ip: peerField.stringValue, name: nameField.stringValue, in: peers) {
            peerPopup.selectItem(at: i + 1); return
        }
        let ip = peerField.stringValue.trimmingCharacters(in: .whitespaces)
        if !peers.isEmpty { peerPopup.item(at: 0)?.title = ip.isEmpty ? L("test.chooseDevice") : L("test.customTarget") }
        peerPopup.selectItem(at: 0)
    }

    @objc func peerChosen() {
        let i = peerPopup.indexOfSelectedItem - 1
        guard peers.indices.contains(i) else { return }
        peerField.stringValue = peers[i].ip4
        nameField.stringValue = peers[i].name
        peerPopup.item(at: 0)?.title = L("test.chooseDevice")
        targetEdited()
    }

    func controlTextDidChange(_ n: Notification) {
        if n.object as? NSTextField === peerField || n.object as? NSTextField === nameField { syncPopupToFields() }
        targetEdited()
    }

    var currentTarget: String { testTarget(ip: peerField.stringValue, name: nameField.stringValue, port: portField.stringValue) }

    /// A changed target makes earlier results and messages about the old target out of date.
    func targetEdited() {
        if lastRun != nil { checkResultsFreshness() } else if !testNotice.isHidden { testNotice.hide(); fitWindow() }
    }

    /// Replaces results that no longer describe the current target or state with a short note.
    func checkResultsFreshness() {
        guard let run = lastRun, snapshot.taken else { return }
        let f = freshness(of: run, target: currentTarget, context: snapshot.headerContext)
        guard f != .current else { return }
        lastRun = nil
        resultsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        resultsStack.isHidden = true
        testNotice.hide()
        resultsSummary.stringValue = f == .targetChanged ? L("test.staleTarget") : L("test.staleState")
        resultsSummary.textColor = .secondaryLabelColor
        if case .results(_, let at) = testOutcome { testOutcome = .stale(at: at) }
        append(resultsSummary.stringValue, color: .secondaryLabelColor)
        fitWindow(shrinkOnly: userSized)
    }

    func refresh() {
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let s = Snapshot.take()
            DispatchQueue.main.async { self.show(s, startedAt: started) }
        }
    }

    func apply(_ line: StatusLine, _ icon: NSImageView, _ value: NSTextField, _ secondary: NSTextField) {
        setSymbol(icon, line.tone.symbol, line.tone.color, line.tone.label)
        value.stringValue = line.value
        secondary.stringValue = line.secondary ?? ""
        for v in [icon, value, secondary] { v.toolTip = line.help }
    }

    func show(_ s: Snapshot, startedAt: Date = .distantPast) {
        snapshot = s
        let h = s.headline
        setSymbol(stateIcon, h.symbol, h.color, h.title)
        stateTitle.stringValue = h.title
        stateDetail.stringValue = h.detail
        primaryButton.title = h.action == .enable ? L("action.enable") : L("action.disable")
        primaryButton.bezelColor = h.action == .enable && h.actionEnabled ? .controlAccentColor : nil
        primaryButton.isEnabled = h.actionEnabled && !isBusy
        primaryButton.setAccessibilityHelp(h.detail)
        cleanupButton.isHidden = !(h.offersCleanup && h.action == .enable)
        cleanupButton.isEnabled = !isBusy

        apply(s.mullvadLine, mullvadIcon, mullvadValue, mullvadSecondary)
        apply(s.tailscaleLine, tailscaleIcon, tailscaleValue, tailscaleSecondary)
        dnsWarningText.stringValue = s.dnsFilterWarning ?? ""
        dnsWarning.isHidden = s.dnsFilterWarning == nil

        // removeRow keeps the cell views as subviews, so detach them first.
        techGrid.subviews.forEach { $0.removeFromSuperview() }
        while techGrid.numberOfRows > 0 { techGrid.removeRow(at: 0) }
        for r in s.taken ? s.technicalRows : [] {
            let icon = symbolView(pointSize: 11)
            setSymbol(icon, r.tone.symbol, r.tone.color, r.tone.label)
            let value = label(r.value)
            value.lineBreakMode = .byTruncatingMiddle
            value.toolTip = r.value
            value.isSelectable = true
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            techGrid.addRow(with: [label(r.label, color: .secondaryLabelColor), icon, value])
        }

        // A missing helper is the one case where Administration is the next step.
        if s.taken && !s.helperInstalled && !adminDisclosure.isExpanded { adminDisclosure.isExpanded = true }
        if s.taken {
            updatedLabel.stringValue = L("common.updated", DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))
            // Messages written for an earlier state disappear once it changes (not mid-action).
            let idle = !isBusy && startedAt >= idleSince
            headerNotice.refresh(context: s.headerContext, idle: idle)
            adminNotice.refresh(context: s.adminContext, idle: idle)
            if idle { checkResultsFreshness() }
        }
        fitWindow(shrinkOnly: userSized)
    }

    // MARK: Primary action

    @objc func primaryClicked() { snapshot.headline.action == .enable ? enable() : disable() }

    // MARK: Privileged actions

    enum AdminResult { case ok, partial, failed, cancelled, unknown }

    /// Runs one fixed helper command through the administrator prompt. `.unknown` = outcome not confirmed.
    func admin(_ command: String, prompt: String) -> AdminResult {
        let r = Proc.run("/usr/bin/osascript", ["-e", Privileged.appleScript(command: command, prompt: prompt)], timeout: 600)
        if r.err.contains("(-128)") { say(L("log.cancelled"), .systemOrange); return .cancelled }
        for l in r.out.split(whereSeparator: \.isNewline) where !l.hasPrefix("TAILBRIDGE_EXIT=") { say(String(l)) }
        let err = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty { say(err, .systemRed) }
        guard !r.timedOut, r.ok, let code = Privileged.exitStatus(r.out) else { return .unknown }
        switch code {
        case 0: return .ok
        case 2: return .partial
        default: return .failed
        }
    }

    func reportState(after action: String) {
        let s = Snapshot.take()
        guard s.monitorFresh, let st = s.status else {
            return notify(headerNotice, .warning, L("notice.unconfirmed", action), followUp: true)
        }
        say(L("log.stateAfter", action, st.anchor, st.resolver, st.legacyAnchor, st.cleanupPending ? L("common.yes") : L("common.no")),
            st.cleanupPending || st.anchor == "mismatch" ? .systemRed : .labelColor)
        for p in st.problems { say("  problem: \(p)", .systemOrange) }
        if !st.problems.isEmpty { notify(headerNotice, .warning, L("notice.problemsAfter", action), followUp: true) }
    }

    @objc func installHelper() {
        guard let src = Bundle.main.path(forResource: "com.tailbridge.helper", ofType: nil),
              let sha = Privileged.sha256Hex(src), let cmd = Privileged.installCommand(source: src, sha256: sha) else {
            adminDisclosure.isExpanded = true
            notify(adminNotice, .error, L("admin.missingHelper")); return
        }
        adminNotice.hide()
        busy(L("admin.installTask")) {
            self.say("Helper: \(src)\nSHA-256: \(sha)\nTarget: \(Privileged.helperPath) (root:wheel 755) + LaunchDaemon \(Privileged.label)")
            switch self.admin(cmd, prompt: L("prompt.install", String(sha.prefix(16)))) {
            case .ok: self.notify(self.adminNotice, .success, L("admin.installed"))
            case .cancelled: self.notify(self.adminNotice, .info, L("notice.cancelled"))
            default: self.notify(self.adminNotice, .error, L("admin.installFailed"))
            }
        }
    }

    @objc func uninstallHelper() {
        guard snapshot.helperInstalled else { notify(adminNotice, .info, L("admin.notInstalled")); return }
        adminNotice.hide()
        busy(L("admin.uninstallTask")) {
            switch self.admin(Privileged.uninstallCommand, prompt: L("prompt.uninstall")) {
            case .ok: self.notify(self.adminNotice, .success, L("admin.uninstalled"))
            case .partial: self.notify(self.adminNotice, .warning, L("admin.uninstalledLeftovers"))
            case .cancelled: self.notify(self.adminNotice, .info, L("notice.cancelled"))
            default: self.notify(self.adminNotice, .error, L("admin.uninstallFailed"))
            }
        }
    }

    @objc func enable() {
        headerNotice.hide()
        busy(L("action.enable")) {
            let s = Snapshot.take()
            guard s.helperInstalled, s.monitorFresh else {
                return self.notify(self.headerNotice, .warning, L("enable.needHelper"))
            }
            guard s.mullvadConnected else {
                return self.notify(self.headerNotice, .warning, L("enable.needMullvad"))
            }
            guard let t = s.ts, t.backendState == "Running", let v4 = t.ip4, let v6 = t.ip6, let d = t.domain, let i = s.iface else {
                return self.notify(self.headerNotice, .warning, L("enable.needTailscale"))
            }
            // Same blockers as the button and menu (state may have changed since): no password prompt for a refusal.
            if let blocker = s.enableBlocker { return self.notify(self.headerNotice, .warning, blocker) }
            let env = EnvFile.standard()
            do {
                if try env.apply() {
                    self.say("Created \(env.path)")
                    return self.notify(self.headerNotice, .info, L("enable.restartTailscale"))
                }
            } catch {
                self.say("env: \(error)", .systemRed)
                return self.notify(self.headerNotice, .error, L("enable.envFailed"))
            }
            let id = Identity(iface: i.name, index: i.index, ip4: v4, ip6: v6, domain: d)
            guard let cmd = Privileged.enableCommand(id) else { return self.notify(self.headerNotice, .error, L("enable.invalidData")) }
            switch self.admin(cmd, prompt: L("prompt.enable", i.name, v4, d)) {
            case .ok: self.notify(self.headerNotice, .success, L("enable.done"))
            case .cancelled: return self.notify(self.headerNotice, .info, L("notice.cancelled"))
            default: self.notify(self.headerNotice, .error, L("enable.failed"))
            }
            Thread.sleep(forTimeInterval: 6)   // let the monitor publish a fresh observation
            self.reportState(after: L("action.enable"))
        }
    }

    @objc func disable() {
        headerNotice.hide()
        busy(L("action.disable")) {
            let s = Snapshot.take()
            if s.helperInstalled {
                switch self.admin(Privileged.disableCommand, prompt: L("prompt.disable")) {
                case .ok: self.notify(self.headerNotice, .success, L("disable.done"))
                case .partial: self.notify(self.headerNotice, .warning, L("disable.partial"))
                case .cancelled: return self.notify(self.headerNotice, .info, L("notice.cancelled"))
                case .failed: self.notify(self.headerNotice, .error, L("disable.failed"))
                case .unknown: self.notify(self.headerNotice, .error, L("disable.unknown"))
                }
                Thread.sleep(forTimeInterval: 6)
                self.reportState(after: L("action.disable"))
            } else {
                self.notify(self.headerNotice, .warning, L("disable.noHelper"))
            }
            do {
                if let b = try EnvFile.standard().remove() { self.say(L("log.envMoved", b)) }
                else { self.say(L("log.envAbsent")) }
            } catch { self.say("env: \(error)", .systemOrange) }
            let after = Snapshot.take()
            self.say(L("log.mullvadAfter", after.mullvadError == nil ? after.mullvadState : L("mullvad.unavailable")),
                     after.mullvadConnected ? .systemGreen : .systemOrange)
        }
    }

    // MARK: Connection Test

    @objc func runChecks() {
        let peer = peerField.stringValue.trimmingCharacters(in: .whitespaces)
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let invalid: String?
        if !(peer.isEmpty || Validate.tailscaleIPv4(peer)) { invalid = L("test.invalidIP") }
        else if !(name.isEmpty || Validate.hostLabel(name)) { invalid = L("test.invalidName") }
        else if Validate.port(portField.stringValue.trimmingCharacters(in: .whitespaces)) == nil { invalid = L("test.invalidPort") }
        else { invalid = nil }
        if let msg = invalid {
            // The message is inside the section: show it rather than fail silently while collapsed.
            if !testDisclosure.isExpanded { testDisclosure.isExpanded = true; showCollapsedTest() }
            advancedDisclosure.isExpanded = true
            return notify(testNotice, .error, msg)
        }
        let port = Validate.port(portField.stringValue.trimmingCharacters(in: .whitespaces))!
        UserDefaults.standard.set(peer, forKey: "peer")
        UserDefaults.standard.set(name, forKey: "name")
        UserDefaults.standard.set(String(port), forKey: "port")
        testNotice.hide()
        lastRun = nil
        resultsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        resultsStack.isHidden = true
        resultsSummary.stringValue = L("test.running")
        resultsSummary.textColor = .secondaryLabelColor
        testOutcome = .running
        let target = currentTarget
        busy(L("test.run")) {
            let s = Snapshot.take()
            let results = Diagnostics.runAll(peer: peer, name: name, port: port, snapshot: s)
            self.onMain { self.showResults(results, snapshot: s, hadPeer: !peer.isEmpty, target: target) }
        }
    }

    func showResults(_ results: [CheckResult], snapshot s: Snapshot, hadPeer: Bool, target: String) {
        // The target was edited while the test ran: log the results but don't show them as current.
        if freshness(of: TestRun(target: target, context: ""), target: currentTarget, context: "") == .targetChanged {
            append(L("test.staleTarget"), color: .secondaryLabelColor)
            for r in results { append("\(r.verdict.label.padding(toLength: 12, withPad: " ", startingAt: 0)) \(r.name) — \(r.detail)", color: r.verdict.color) }
            resultsSummary.stringValue = L("test.staleTarget")
            resultsSummary.textColor = .secondaryLabelColor
            testOutcome = .stale(at: DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short))
            return
        }
        resultsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        resultsStack.isHidden = results.isEmpty
        for r in results {
            let icon = symbolView()
            setSymbol(icon, r.verdict.symbol, r.verdict.color, r.verdict.label)
            let name = label(r.name)
            name.lineBreakMode = .byTruncatingTail
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let detail = wrapping(r.detail, font: smallFont, color: .secondaryLabelColor)
            let texts = vstack([name, detail], spacing: 1)
            fill(detail, texts)
            let verdict = label(r.verdict.label, color: r.verdict == .notVerified || r.verdict == .info ? .secondaryLabelColor : r.verdict.color)
            verdict.alignment = .right
            verdict.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            verdict.widthAnchor.constraint(equalToConstant: 92).isActive = true
            let row = hstack([icon, texts, verdict], spacing: 8)
            row.distribution = .fill
            texts.setHuggingPriority(.init(1), for: .horizontal)
            row.setAccessibilityElement(true)
            row.setAccessibilityLabel("\(r.name): \(r.verdict.label). \(r.detail)")
            resultsStack.addArrangedSubview(row)
            fill(row, resultsStack)
            append("\(r.verdict.label.padding(toLength: 12, withPad: " ", startingAt: 0)) \(r.name) — \(r.detail)", color: r.verdict.color)
        }
        let sum = summarize(results, workaroundActive: s.workaroundActive, hadPeer: hadPeer)
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        resultsSummary.stringValue = L("test.summary", sum.passed, sum.failed, sum.inconclusive, sum.notTested, time)
        resultsSummary.textColor = .labelColor
        testOutcome = .results(sum, at: time)
        if let kind = sum.notice, let key = sum.noticeKey { notify(testNotice, kind, L(key)) }
        lastRun = TestRun(target: target, context: s.headerContext)
        fitWindow()
    }

    @objc func diagnostics() {
        showLog()
        busy(L("action.diagnostics")) {
            let s = Snapshot.take()
            var lines: [String] = []
            lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
            let tv = Tools.runVendor(Tools.tailscale, ["version"])
            lines.append("Tailscale: \(tv.lines.first ?? "?") · \(s.ts?.backendState ?? "?") · IPv6 \(s.ts?.ip6 ?? "?")")
            let mv = Tools.runVendor(Tools.mullvad, ["--version"])
            lines.append("Mullvad: \(mv.lines.first ?? "?") · \(s.mullvadError.map { "unavailable: \($0)" } ?? s.mullvadState) · \(s.lockdown ?? "?")")
            lines.append("Tailscale interface: \(s.iface.map { "\($0.name) #\($0.index)" } ?? "none")")
            lines.append("env file: \(EnvFile.standard().path) → \(s.env)")
            lines.append("Helper: \(s.helperInstalled ? "installed" : "not installed") · launchd: \(s.monitorRunning ? "running" : "not running")")
            if let st = s.status {
                lines.append("status.json (\(Int(s.statusAge ?? -1)) s ago, source \(st.source)): enabled=\(st.enabled) anchor=\(st.anchor) pf=\(st.pfEnabled.map(String.init) ?? "?") order=\(st.appleBeforeMullvad.map(String.init) ?? "?") resolver=\(st.resolver)")
                lines.append("  prototype: anchor=\(st.legacyAnchor) state=\(st.legacyState)")
                if let id = st.identity { lines.append("  identity: \(id.iface) #\(id.index) \(id.ip4) \(id.ip6) \(id.domain)") }
                if !st.lastEvent.isEmpty { lines.append("  last event: \(st.lastEvent)") }
                for p in st.problems { lines.append("  problem: \(p)") }
            } else { lines.append("status.json: missing (helper not installed?)") }
            lines.append(L("diag.pfCounters"))
            lines.append(L("diag.notCollected"))
            self.onMain { lines.forEach { self.append($0) } }
        }
    }
}

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.setActivationPolicy(.regular)
app.run()
