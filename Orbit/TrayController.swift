import AppKit

@MainActor
class TrayController {
    private var statusItem: NSStatusItem?
    private var tokenStatsItem: NSMenuItem?
    private var timer: Timer?
    private let statsProvider: () -> TodayTokenStats
    weak var appDelegate: AppDelegate?
    
    init(statsProvider: @escaping () -> TodayTokenStats) {
        self.statsProvider = statsProvider
    }
    
    func setup() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Orbit")
            button.image?.size = NSSize(width: 16, height: 16)
            button.image?.isTemplate = true
        }
        
        let menu = NSMenu()
        
        let tokenItem = NSMenuItem(title: tokenStatsText(), action: nil, keyEquivalent: "")
        tokenItem.isEnabled = false
        menu.addItem(tokenItem)
        self.tokenStatsItem = tokenItem
        
        menu.addItem(NSMenuItem.separator())
        
        let toggleItem = NSMenuItem(title: "Show/Hide Orbit", action: #selector(togglePanel), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit Orbit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem.menu = menu
        self.statusItem = statusItem
        
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshTokenStats()
            }
        }
    }
    
    private func tokenStatsText() -> String {
        let stats = statsProvider()
        return TokenFormatting.tokenStatsText(
            tokensIn: stats.tokensIn,
            tokensOut: stats.tokensOut,
            outRate: stats.outRate
        )
    }
    
    private func refreshTokenStats() {
        tokenStatsItem?.title = tokenStatsText()
    }
    
    @objc private func togglePanel() {
        appDelegate?.togglePanel()
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
