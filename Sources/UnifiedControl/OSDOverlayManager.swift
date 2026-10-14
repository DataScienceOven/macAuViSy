//
//  OSDOverlayManager.swift
//  macAuViSy
//
//  Multi-Screen Liquid Glass On-Screen Display (OSD) Overlay Manager.
//  Provides native macOS-styled floating HUD feedback for master volume and brightness
//  with adaptive light/dark appearance, discrete 16-chiclet stepping, and muted badge.
//

import SwiftUI
import AppKit

enum OSDType {
    case volume(level: Double, isMuted: Bool)
    case brightness(level: Double)
}

final class OSDState: ObservableObject {
    static let shared = OSDState()
    @Published var type: OSDType = .volume(level: 50.0, isMuted: false)
    @Published var isDarkMode: Bool = (UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark")
    
    init() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isDarkMode = (UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark")
        }
    }
}

struct LiquidGlassOSDView: View {
    @ObservedObject var state = OSDState.shared
    
    var body: some View {
        let isDark = state.isDarkMode
        let primaryColor = isDark ? Color.white : Color(white: 0.08)
        let unfilledColor = isDark ? Color.white.opacity(0.18) : Color.black.opacity(0.12)
        
        ZStack {
            // Completely transparent window padding canvas - ensures 0 square cutoffs
            Color.clear
            
            // The Liquid Glass Card
            VStack(spacing: 15) {
                Spacer().frame(height: 2)
                
                // Icon - Razor-sharp vector rendering
                Group {
                    switch state.type {
                    case .volume(let level, let isMuted):
                        if isMuted || level <= 0 {
                            Image(systemName: "speaker.slash.fill")
                        } else if level > 66 {
                            Image(systemName: "speaker.wave.3.fill")
                        } else if level > 33 {
                            Image(systemName: "speaker.wave.2.fill")
                        } else {
                            Image(systemName: "speaker.wave.1.fill")
                        }
                    case .brightness:
                        Image(systemName: "sun.max.fill")
                    }
                }
                .font(.system(size: 52, weight: .medium))
                .foregroundColor(primaryColor)
                .shadow(color: isDark ? Color.black.opacity(0.40) : Color.black.opacity(0.08), radius: 1.5, x: 0, y: 1)
                
                // 16 Apple Chiclets Bar - Sharp, crisp edges
                let filled = getFilledChiclets()
                HStack(spacing: 2.6) {
                    ForEach(0..<16, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(i < filled ? primaryColor : unfilledColor)
                            .frame(width: 7.5, height: 8.5)
                    }
                }
                .padding(.horizontal, 6)
                
                // Percentage or Status Text - Reduced by additional 20% (20pt / 18pt)
                Group {
                    switch state.type {
                    case .volume(let level, let isMuted):
                        if isMuted || level <= 0 {
                            HStack(spacing: 5) {
                                Image(systemName: "speaker.slash.fill")
                                    .font(.system(size: 13, weight: .bold))
                                Text("MUTED")
                                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 4.5)
                            .background(
                                Capsule()
                                    .fill(Color(red: 0.86, green: 0.18, blue: 0.18))
                            )
                        } else {
                            Text("\(Int(round(level)))%")
                                .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundColor(primaryColor)
                        }
                    case .brightness(let level):
                        Text("\(Int(round(level)))%")
                            .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundColor(primaryColor)
                    }
                }
                .shadow(color: isDark ? Color.black.opacity(0.35) : Color.black.opacity(0.08), radius: 1, x: 0, y: 0.5)
                
                Spacer().frame(height: 2)
            }
            .padding(16)
            .frame(width: 200, height: 200)
            .background(
                // Ultra-Transparent Liquid Glass
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(
                                isDark
                                ? Color(white: 0.08, opacity: 0.08)
                                : Color(white: 1.0, opacity: 0.08)
                            )
                    )
            )
            .overlay(
                // Razor-Sharp Specular Glass Rim Highlight
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: isDark ? [
                                Color.white.opacity(0.35),
                                Color.white.opacity(0.08),
                                Color.white.opacity(0.02),
                                Color.white.opacity(0.15)
                            ] : [
                                Color.white.opacity(0.70),
                                Color.white.opacity(0.20),
                                Color.black.opacity(0.04),
                                Color.white.opacity(0.40)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.0
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(
                color: isDark ? Color.black.opacity(0.22) : Color.black.opacity(0.08),
                radius: 12,
                x: 0,
                y: 5
            )
        }
        .frame(width: 250, height: 250)
    }
    
    private func getFilledChiclets() -> Int {
        switch state.type {
        case .volume(let level, let isMuted):
            if isMuted || level <= 0 { return 0 }
            return Int(round((level / 100.0) * 16.0))
        case .brightness(let level):
            return Int(round((level / 100.0) * 16.0))
        }
    }
}

final class OSDOverlayManager {
    static let shared = OSDOverlayManager()
    
    private var panels: [NSPanel] = []
    private var hideWorkItem: DispatchWorkItem?
    
    func show(type: OSDType) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Refresh dark mode state dynamically on each invocation
            OSDState.shared.isDarkMode = (UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark")
            OSDState.shared.type = type
            
            let screens = NSScreen.screens
            guard !screens.isEmpty else { return }
            
            // Maintain one panel per active screen
            while self.panels.count < screens.count {
                self.panels.append(self.createPanel())
            }
            while self.panels.count > screens.count {
                let p = self.panels.removeLast()
                p.orderOut(nil)
            }
            
            let panelSize: CGFloat = 250
            
            // Position on ALL screens in the EXACT center of each display
            for (idx, screen) in screens.enumerated() {
                let panel = self.panels[idx]
                let x = screen.frame.midX - (panelSize / 2.0)
                let y = screen.frame.midY - (panelSize / 2.0)
                panel.setFrameOrigin(NSPoint(x: x, y: y))
                
                panel.alphaValue = 1.0
                if !panel.isVisible {
                    panel.orderFront(nil)
                }
            }
            
            self.hideWorkItem?.cancel()
            
            let item = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.28
                    for p in self.panels {
                        p.animator().alphaValue = 0.0
                    }
                }, completionHandler: {
                    for p in self.panels {
                        if p.alphaValue == 0.0 {
                            p.orderOut(nil)
                        }
                    }
                })
            }
            self.hideWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.25, execute: item)
        }
    }
    
    private func createPanel() -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 250, height: 250),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        
        let hostingView = NSHostingView(rootView: LiquidGlassOSDView())
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        p.contentView = hostingView
        return p
    }
}
