import SwiftUI
import ServiceManagement
import PrivateToggles

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                
                // BRANDING & UNIFIED CONTROLS SECTION
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("mac")
                            .font(.system(.headline, design: .rounded).weight(.regular))
                            .foregroundColor(.secondary)
                        + Text("AuViSy")
                            .font(.system(.headline, design: .rounded).weight(.bold))
                            .foregroundColor(.primary)
                        
                        Spacer()
                        
                        if appState.isMuted {
                            Button(action: {
                                appState.toggleMute()
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "speaker.slash.fill")
                                        .font(.caption2.bold())
                                    Text("MUTED")
                                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3.5)
                                .background(Color.red.opacity(0.88))
                                .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                            .help("Muted (Click to unmute)")
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .padding(.bottom, 2)
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Master Brightness")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        HStack {
                            Image(systemName: "sun.min").foregroundColor(.secondary).font(.caption)
                            Slider(value: $appState.combinedBrightness, in: 0...100)
                            Text("\(Int(appState.combinedBrightness))%").foregroundColor(.secondary).font(.caption.monospacedDigit()).frame(width: 30, alignment: .trailing)
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Master Volume (MIDI Sync)")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Spacer()
                            if appState.isMuted {
                                Text("MUTED")
                                    .font(.caption2.bold())
                                    .foregroundColor(.red)
                            }
                        }
                        HStack {
                            Button(action: {
                                appState.toggleMute()
                            }) {
                                Image(systemName: appState.isMuted ? "speaker.slash.fill" : "speaker.fill")
                                    .foregroundColor(appState.isMuted ? .red : .secondary)
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .help(appState.isMuted ? "Click to unmute" : "Click to mute")
                            
                            Slider(value: $appState.combinedVolume, in: 0...100)
                            Text("\(Int(appState.combinedVolume))%").foregroundColor(.secondary).font(.caption.monospacedDigit()).frame(width: 30, alignment: .trailing)
                        }
                    }
                }
                
                Divider()
                
                // ACCESSIBILITY PERMISSION BANNER (USER-INITIATED ONLY)
                if !appState.isAccessibilityGranted {
                    HStack(spacing: 8) {
                        Image(systemName: "keyboard.badge.waveform")
                            .foregroundColor(.orange)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Keyboard Shortcuts Disabled")
                                .font(.caption.weight(.semibold))
                            Text("Grant access for F1/F2 & F11/F12 keys")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Grant") {
                            appState.requestAccessibilityPermission()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.12))
                    .cornerRadius(8)
                    
                    Divider()
                }
                
                // DISPLAYS SECTION
                if !appState.displays.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("DISPLAYS", systemImage: "display")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        ForEach($appState.displays) { $display in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(display.name)
                                    .font(.subheadline)
                                HStack {
                                    Image(systemName: "sun.min").foregroundColor(.secondary).font(.caption)
                                    Slider(value: Binding(
                                        get: { display.brightness },
                                        set: { val in
                                            $display.wrappedValue.brightness = val
                                            appState.syncBrightness(for: $display.wrappedValue)
                                        }
                                    ), in: 0...100)
                                    Text("\(Int(display.brightness))%").foregroundColor(.secondary).font(.caption.monospacedDigit()).frame(width: 30, alignment: .trailing)
                                }
                            }
                        }
                    }
                    Divider()
                }
                
                // AUDIO SINK SECTION
                if !appState.audioDevices.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("AUDIO SINK", systemImage: "hifispeaker")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        ForEach($appState.audioDevices) { $device in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(device.name)
                                    .font(.subheadline)
                                HStack {
                                    Image(systemName: "speaker.fill").foregroundColor(.secondary).font(.caption)
                                    Slider(value: Binding(
                                        get: { device.volume },
                                        set: { val in
                                            $device.wrappedValue.volume = val
                                            appState.syncVolume(for: $device.wrappedValue)
                                        }
                                    ), in: 0...100)
                                    Text("\(Int(device.volume))%").foregroundColor(.secondary).font(.caption.monospacedDigit()).frame(width: 30, alignment: .trailing)
                                }
                            }
                        }
                    }
                    Divider()
                }
                
                // SYSTEM TOGGLES
                VStack(alignment: .leading, spacing: 8) {
                    Label("SYSTEM", systemImage: "macwindow")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Toggle("Dark Mode", isOn: Binding(get: { appState.isDarkMode }, set: { val in
                        appState.isDarkMode = val
                        let script = "tell application \"System Events\" to tell appearance preferences to set dark mode to \(val)"
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                        process.arguments = ["-e", script]
                        try? process.run()
                    }))
                    
                    Toggle("Night Shift", isOn: Binding(get: { appState.isNightShift }, set: { val in
                        appState.isNightShift = val
                        appState.setNightShift(enabled: val)
                    }))
                    
                    Toggle("True Tone", isOn: Binding(get: { appState.isTrueTone }, set: { val in
                        appState.isTrueTone = val
                        appState.setTrueTone(enabled: val)
                    }))
                    
                    Toggle("HDR (Display Settings)", isOn: Binding(get: { appState.isHDR }, set: { val in
                        appState.isHDR = val
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
                    }))
                    
                    Toggle("Launch at Login", isOn: Binding(get: { appState.launchAtLogin }, set: { val in
                        appState.launchAtLogin = val
                        do {
                            if val {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            print("Failed to change login item status: \(error)")
                            appState.launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }))
                }
                .toggleStyle(SwitchToggleStyle())
                .font(.subheadline)
            }
            .padding()
            
            Divider()
            
            // FOOTER SECTION
            HStack {
                Button(action: {
                    if let url = URL(string: "https://abhi-cser.github.io/") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Label("Say, Hi!", systemImage: "hand.wave")
                }
                .buttonStyle(HoverButtonStyle())
                
                Spacer()
                
                Button(action: {
                    if let url = URL(string: "https://buymeacoffee.com/abhi.cser") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Label("Coffee", systemImage: "cup.and.saucer")
                }
                .buttonStyle(HoverButtonStyle(hoverColor: Color.brown.opacity(0.7)))
                
                Spacer()
                
                QuitButton()
            }
            .font(.footnote)
            .padding(.horizontal)
            .padding(.vertical, 8)
            
        }
        .frame(width: 320)
        .accentColor(.primary)
        .tint(.primary)
        .colorMultiply(Color(white: 0.85))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .controlSize(.mini)
    }
}

class HoverState: ObservableObject {
    @Published var isHovered = false
}

struct HoverButtonStyle: ButtonStyle {
    var hoverColor: Color = Color.green.opacity(0.7)
    @StateObject private var state = HoverState()
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(4)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .onHover { hovering in
                if state.isHovered != hovering {
                    state.isHovered = hovering
                    DispatchQueue.main.async {
                        if hovering { NSCursor.pointingHand.push() }
                        else { NSCursor.pop() }
                    }
                }
            }
            .foregroundColor(state.isHovered ? .white : .secondary)
            .background(state.isHovered ? hoverColor : Color.clear)
            .cornerRadius(6)
            .scaleEffect(state.isHovered ? 1.05 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: state.isHovered)
    }
}

struct QuitButton: View {
    @StateObject private var state = HoverState()
    
    var body: some View {
        Button(action: {
            exit(0)
        }) {
            ZStack {
                Label("Sure?", systemImage: "power").opacity(state.isHovered ? 1 : 0)
                Label("Quit ", systemImage: "power").opacity(state.isHovered ? 0 : 1)
            }
            .padding(4)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .onHover { hovering in
                if state.isHovered != hovering {
                    state.isHovered = hovering
                    DispatchQueue.main.async {
                        if hovering { NSCursor.pointingHand.push() }
                        else { NSCursor.pop() }
                    }
                }
            }
            .foregroundColor(state.isHovered ? .white : .secondary)
            .background(state.isHovered ? Color.red.opacity(0.7) : Color.clear)
            .cornerRadius(6)
            .scaleEffect(state.isHovered ? 1.05 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: state.isHovered)
        }
        .buttonStyle(.plain)
    }
}
