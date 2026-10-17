import Foundation
import ServiceManagement
import Cocoa
import CoreGraphics
import CoreAudio
import AudioToolbox
import IOKit
import PrivateToggles

// MARK: - Private Apple Framework APIs
typealias DisplayServicesSetBrightnessFunc = @convention(c) (CGDirectDisplayID, Float) -> Int32
typealias DisplayServicesGetBrightnessFunc = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

var displayServicesSetBrightness: DisplayServicesSetBrightnessFunc?
var displayServicesGetBrightness: DisplayServicesGetBrightnessFunc?

func loadDisplayServices() {
    let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    if let setSym = dlsym(handle, "DisplayServicesSetBrightness"),
       let getSym = dlsym(handle, "DisplayServicesGetBrightness") {
        displayServicesSetBrightness = unsafeBitCast(setSym, to: DisplayServicesSetBrightnessFunc.self)
        displayServicesGetBrightness = unsafeBitCast(getSym, to: DisplayServicesGetBrightnessFunc.self)
    }
}

// MARK: - DDC Worker (Serialized, Reliable, Hardware-Paced)
final class DDCWorker {
    static let shared = DDCWorker()
    private var pendingLuminanceWorkItem: DispatchWorkItem?
    private let ddcQueue = DispatchQueue(label: "com.macAuViSy.ddcQueue", qos: .userInitiated)
    private let m1ddcPath = "/opt/homebrew/bin/m1ddc"
    
    private var hasM1ddc: Bool {
        FileManager.default.fileExists(atPath: m1ddcPath)
    }
    
    @discardableResult
    private func executeDDC(arguments: [String], retries: Int = 2) -> (Bool, String) {
        guard hasM1ddc else { return (false, "") }
        for attempt in 0...retries {
            let p = Process()
            let pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: self.m1ddcPath)
            p.arguments = arguments
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do {
                try p.run()
                p.waitUntilExit()
                if p.terminationStatus == 0 {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return (true, output)
                }
            } catch {
                print("⚠️ DDC error executing \(arguments): \(error)")
            }
            if attempt < retries {
                usleep(50_000) // 50ms I2C recovery pause before retry
            }
        }
        return (false, "")
    }
    
    func getLuminance() -> Int? {
        let (ok, out) = executeDDC(arguments: ["get", "luminance"], retries: 1)
        return ok ? Int(out) : nil
    }

    func setLuminance(_ val: Int) {
        guard hasM1ddc else { return }
        pendingLuminanceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            _ = self.executeDDC(arguments: ["set", "luminance", "\(val)"])
        }
        pendingLuminanceWorkItem = item
        ddcQueue.asyncAfter(deadline: .now() + 0.04, execute: item)
    }
    
    func getVolume() -> Int? {
        let (ok, out) = executeDDC(arguments: ["get", "volume"], retries: 1)
        return ok ? Int(out) : nil
    }

    func setVolume(_ val: Int) {
        setMute(val <= 0, volume: max(0, val))
    }
    
    func setMute(_ muted: Bool, volume: Int) {
        guard hasM1ddc else { return }
        // Queue serialized to ensure zero dropped commands and no concurrent I2C bus collisions
        ddcQueue.async { [weak self] in
            guard let self = self else { return }
            
            // 1. Send hardware mute command with automatic retry
            _ = self.executeDDC(arguments: ["set", "mute", muted ? "on" : "off"], retries: 2)
            
            // 2. Critical VESA DDC/CI inter-command pacing (60ms) to allow display microcontroller to settle
            usleep(60_000)
            
            // 3. Set hardware volume: 0 when muted, or exact target volume
            let targetVol = muted ? 0 : volume
            _ = self.executeDDC(arguments: ["set", "volume", "\(targetVol)"], retries: 2)
        }
    }
}

// MARK: - Models
struct DisplayItem: Identifiable {
    let id: CGDirectDisplayID
    var name: String
    var brightness: Double // 0 to 100
    var isBuiltIn: Bool
    var hasDDC: Bool
    var isExternal: Bool { !isBuiltIn }
}

struct AudioDeviceItem: Identifiable {
    let id: AudioDeviceID
    var uid: String = ""
    var name: String
    var volume: Double // 0 to 100
    var hasHardwareDDC: Bool = false
}

// MARK: - AppState Controller
class AppState: ObservableObject {
    private var isScanning = false
    private var isUpdatingCombined = false

    var displayOffsets: [CGDirectDisplayID: Double] = [:]
    var audioOffsets: [AudioDeviceID: Double] = [:]

    @Published var displays: [DisplayItem] = []
    @Published var combinedBrightness: Double = 50.0 {
        didSet {
            guard !isScanning && !isUpdatingCombined else { return }
            isUpdatingCombined = true
            for i in 0..<displays.count {
                if combinedBrightness <= 0.0 {
                    displays[i].brightness = 0.0
                } else if combinedBrightness >= 100.0 {
                    displays[i].brightness = 100.0
                } else {
                    let offset = displayOffsets[displays[i].id] ?? 0.0
                    displays[i].brightness = max(0.0, min(100.0, combinedBrightness + offset))
                }
                setBrightness(for: displays[i], level: displays[i].brightness)
            }
            isUpdatingCombined = false
        }
    }
    
    @Published var audioDevices: [AudioDeviceItem] = []
    @Published var combinedVolume: Double = 50.0 {
        didSet {
            guard !isScanning && !isUpdatingCombined else { return }
            if combinedVolume > 0 && isMuted {
                isMuted = false
            }
            isUpdatingCombined = true
            for i in 0..<audioDevices.count {
                if combinedVolume <= 0.0 {
                    audioDevices[i].volume = 0.0
                } else if combinedVolume >= 100.0 {
                    audioDevices[i].volume = 100.0
                } else {
                    let offset = audioOffsets[audioDevices[i].id] ?? 0.0
                    audioDevices[i].volume = max(0.0, min(100.0, combinedVolume + offset))
                }
            }
            isUpdatingCombined = false
            applyAllDeviceVolumes(forceUnmute: combinedVolume > 0.0)
        }
    }
    
    // System Toggles State
    @Published var isDarkMode = (UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark")
    @Published var isNightShift = (UserDefaults.standard.object(forKey: "isNightShift") as? Bool) ?? false
    @Published var isTrueTone = (UserDefaults.standard.object(forKey: "isTrueTone") as? Bool) ?? PrivateToggles.isTrueToneEnabled()
    @Published var isHDR = UserDefaults.standard.bool(forKey: "isHDR")
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var isAccessibilityGranted: Bool = false
    
    fileprivate var eventPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var accessibilityTimer: Timer?
    private var globalMonitor: Any?
    private var audioDevicesListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultOutputListenerBlock: AudioObjectPropertyListenerBlock?
    private var displayReconfigCallback: CGDisplayReconfigurationCallBack?
    @Published var isMuted: Bool = false
    private var preMuteVolume: Double = 50.0
    private var deviceVolumesBeforeMute: [AudioDeviceID: Double] = [:]
    var lastVolumeStepTime: TimeInterval = 0
    var lastBrightnessStepTime: TimeInterval = 0
    var lastMuteToggleTime: TimeInterval = 0
    var volumePressStartTime: TimeInterval = 0
    var brightnessPressStartTime: TimeInterval = 0
    
    init() {
        loadDisplayServices()
        scanDisplays()
        scanAudioDevices()
        checkAccessibilityPermissions()
        
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleHardwareRefresh()
        }

        // Display reconfiguration callback (instant hot-plug / unplug detection)
        let dispCallback: CGDisplayReconfigurationCallBack = { (display, flags, userInfo) in
            guard let userInfo = userInfo else { return }
            let appState = Unmanaged<AppState>.fromOpaque(userInfo).takeUnretainedValue()
            if flags.contains(.addFlag) || flags.contains(.removeFlag) || flags.contains(.enabledFlag) || flags.contains(.disabledFlag) {
                appState.scheduleHardwareRefresh()
            }
        }
        self.displayReconfigCallback = dispCallback
        CGDisplayRegisterReconfigurationCallback(dispCallback, Unmanaged.passUnretained(self).toOpaque())

        // CoreAudio hardware device change listener (audio interface plug/unplug)
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let devBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleHardwareRefresh()
        }
        self.audioDevicesListenerBlock = devBlock
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            DispatchQueue.main,
            devBlock
        )

        // CoreAudio default output change listener (active speaker switch)
        var defaultOutputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let outBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleHardwareRefresh()
        }
        self.defaultOutputListenerBlock = outBlock
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutputAddress,
            DispatchQueue.main,
            outBlock
        )
        
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.tearDownEventTap()
            self?.tearDownHardwareListeners()
            CGDisplayRestoreColorSyncSettings()
        }
        
        if isNightShift {
            setNightShift(enabled: true)
        } else {
            PrivateToggles.setNightShiftEnabled(false)
        }
        if isTrueTone {
            setTrueTone(enabled: true)
        }
    }
    
    deinit {
        tearDownEventTap()
        tearDownHardwareListeners()
        CGDisplayRestoreColorSyncSettings()
    }

    private func tearDownHardwareListeners() {
        if let dispCallback = displayReconfigCallback {
            CGDisplayRemoveReconfigurationCallback(dispCallback, Unmanaged.passUnretained(self).toOpaque())
            displayReconfigCallback = nil
        }
        if let devBlock = audioDevicesListenerBlock {
            var devicesAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &devicesAddress,
                DispatchQueue.main,
                devBlock
            )
            audioDevicesListenerBlock = nil
        }
        if let outBlock = defaultOutputListenerBlock {
            var defaultOutputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultOutputAddress,
                DispatchQueue.main,
                outBlock
            )
            defaultOutputListenerBlock = nil
        }
    }
    
    private func tearDownEventTap() {
        if let port = eventPort {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
            eventPort = nil
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }
    }
    
    // MARK: - Hardware Refresh
    private var refreshWorkItem: DispatchWorkItem?

    func scheduleHardwareRefresh(delay: TimeInterval = 0.8) {
        refreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.refreshHardware()
        }
        refreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func refreshHardware() {
        scanDisplays()
        scanAudioDevices()
    }

    // MARK: - Hardware Sync Methods
    func syncBrightness(for display: DisplayItem) {
        if let idx = displays.firstIndex(where: { $0.id == display.id }) {
            displays[idx].brightness = display.brightness
        }
        setBrightness(for: display, level: display.brightness)
        displayOffsets[display.id] = display.brightness - combinedBrightness
    }
    
    func syncVolume(for device: AudioDeviceItem) {
        if isMuted && device.volume > 0 {
            isMuted = false
        }
        if let idx = audioDevices.firstIndex(where: { $0.id == device.id }) {
            audioDevices[idx].volume = device.volume
        }
        setVolume(for: device, level: device.volume)
        audioOffsets[device.id] = device.volume - combinedVolume
    }
    
    func syncAllDisplays(level: Double) {
        let clamped = max(0.0, min(100.0, level))
        for display in displays {
            setBrightness(for: display, level: clamped)
        }
    }

    private func recalculateCombinedBrightness() {
        guard !displays.isEmpty else { return }
        isUpdatingCombined = true
        combinedBrightness = displays.first?.brightness ?? 50.0
        isUpdatingCombined = false
    }
    
    private func recalculateCombinedVolume() {
        guard !audioDevices.isEmpty else { return }
        let targetIDs = getTargetAudioDeviceIDs()
        isUpdatingCombined = true
        if let defaultDev = audioDevices.first(where: { targetIDs.contains($0.id) }) {
            combinedVolume = defaultDev.volume
        } else {
            combinedVolume = audioDevices.first?.volume ?? 50.0
        }
        isUpdatingCombined = false
    }
    
    // MARK: - Unified Hardware Color & Brightness Pipeline (HDCP Safe, Zero Overlays)
    private func applyGammaAndLuminance(for display: DisplayItem) {
        let clamped = max(0.0, min(100.0, display.brightness))
        // Built-in panels use native Apple backlight control down to 0.
        // All external monitors (physical DDC and virtual USB) use GPU transfer table scaling
        // so that brightness smoothly dims all the way to complete darkness (0) instead of staying lit at minimum backlight.
        let factor: Float = display.isBuiltIn ? 1.0 : Float(clamped / 100.0)
        
        let tableSize = 256
        var red = [Float](repeating: 0, count: tableSize)
        var green = [Float](repeating: 0, count: tableSize)
        var blue = [Float](repeating: 0, count: tableSize)
        
        var gFactor: Float = 1.0
        var bFactor: Float = 1.0
        
        // For external displays (which macOS natively neglects), extend Night Shift and True Tone via GPU color curves!
        // For built-in displays, macOS native True Tone & Night Shift handles it via PrivateToggles.
        if !display.isBuiltIn {
            if isNightShift {
                gFactor *= 0.85
                bFactor *= 0.65
            }
            if isTrueTone {
                gFactor *= 0.96
                bFactor *= 0.90
            }
        }
        
        for i in 0..<tableSize {
            let base = (Float(i) / Float(tableSize - 1)) * factor
            red[i] = base
            green[i] = base * gFactor
            blue[i] = base * bFactor
        }
        
        // Native GPU transfer table: zero overlay window, 100% HDCP DRM safe for Netflix/Prime
        _ = CGSetDisplayTransferByTable(display.id, UInt32(tableSize), red, green, blue)
    }

    func setBrightness(for display: DisplayItem, level: Double) {
        let clamped = max(0.0, min(100.0, level))
        
        // 1. Native Apple DisplayServices ONLY for built-in displays
        if display.isBuiltIn {
            if let setB = displayServicesSetBrightness {
                _ = setB(display.id, Float(clamped / 100.0))
            }
        }
        
        // 2. Hardware DDC luminance ONLY for directly connected DDC external monitors
        // Never send DDC commands when adjusting virtual / USB displays
        if display.hasDDC {
            DDCWorker.shared.setLuminance(Int(clamped))
        }
        
        // 3. Unified GPU Gamma scaling across ALL displays
        var updated = display
        updated.brightness = clamped
        applyGammaAndLuminance(for: updated)
        UserDefaults.standard.set(clamped, forKey: "brightness_\(display.id)")
        UserDefaults.standard.set(clamped, forKey: "brightness_\(display.name)")
    }
    
    // MARK: - Unified Night Shift Control
    func setNightShift(enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "isNightShift")
        isNightShift = enabled
        PrivateToggles.setNightShiftEnabled(enabled)
        
        for display in displays {
            applyGammaAndLuminance(for: display)
        }
    }

    // MARK: - Unified True Tone Control
    func setTrueTone(enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "isTrueTone")
        isTrueTone = enabled
        PrivateToggles.setTrueToneEnabled(enabled)
        
        for display in displays {
            applyGammaAndLuminance(for: display)
        }
    }
    
    // MARK: - Accessibility & Media Keys
    func checkAccessibilityPermissions() {
        let isTrusted = AXIsProcessTrusted()
        self.isAccessibilityGranted = isTrusted
        
        if isTrusted {
            print("✅ Accessibility permissions granted.")
            if eventPort == nil {
                setupEventTap()
            }
        } else {
            print("ℹ️ Accessibility permissions not yet granted. Passive monitoring enabled without prompting.")
            startAccessibilityMonitoring()
        }
    }
    
    private func startAccessibilityMonitoring() {
        guard accessibilityTimer == nil else { return }
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self = self else { return }
            if AXIsProcessTrusted() {
                DispatchQueue.main.async {
                    print("✅ Accessibility permissions detected via background monitor.")
                    self.isAccessibilityGranted = true
                    if self.eventPort == nil {
                        self.setupEventTap()
                    }
                    timer.invalidate()
                    self.accessibilityTimer = nil
                }
            }
        }
    }
    
    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    
    // MARK: - Global Media Key Interception & Stepping
    func stepVolume(up: Bool, isFine: Bool = false) {
        let totalSteps: Double = isFine ? 64.0 : 16.0
        let stepDelta: Double = 100.0 / totalSteps
        
        // Strict boundary clamping guards - prevents infinite looping when held down
        if !up && combinedVolume <= 0.0 {
            combinedVolume = 0.0
            for i in 0..<audioDevices.count {
                audioDevices[i].volume = 0.0
            }
            applyAllDeviceVolumes(forceUnmute: false)
            OSDOverlayManager.shared.show(type: .volume(level: 0.0, isMuted: true))
            return
        }
        if up && combinedVolume >= 100.0 {
            OSDOverlayManager.shared.show(type: .volume(level: 100.0, isMuted: false))
            return
        }
        
        if isMuted {
            isMuted = false
            let base = (preMuteVolume > 0.0) ? preMuteVolume : 50.0
            let currentStep = round(base / stepDelta)
            let nextStep = up ? min(totalSteps, currentStep + 1.0) : max(0.0, currentStep - 1.0)
            let targetVol = (nextStep / totalSteps) * 100.0
            
            isUpdatingCombined = true
            combinedVolume = targetVol
            for i in 0..<audioDevices.count {
                if targetVol <= 0.0 {
                    audioDevices[i].volume = 0.0
                } else if targetVol >= 100.0 {
                    audioDevices[i].volume = 100.0
                } else {
                    let offset = audioOffsets[audioDevices[i].id] ?? 0.0
                    audioDevices[i].volume = max(0.0, min(100.0, targetVol + offset))
                }
            }
            isUpdatingCombined = false
            
            applyAllDeviceVolumes(forceUnmute: targetVol > 0.0)
            OSDOverlayManager.shared.show(type: .volume(level: targetVol, isMuted: targetVol <= 0.0))
            return
        }
        
        let currentStep = round(combinedVolume / stepDelta)
        let nextStep = up ? min(totalSteps, currentStep + 1.0) : max(0.0, currentStep - 1.0)
        let targetVol = (nextStep / totalSteps) * 100.0
        
        isUpdatingCombined = true
        combinedVolume = targetVol
        for i in 0..<audioDevices.count {
            if targetVol <= 0.0 {
                audioDevices[i].volume = 0.0
            } else if targetVol >= 100.0 {
                audioDevices[i].volume = 100.0
            } else {
                let offset = audioOffsets[audioDevices[i].id] ?? 0.0
                audioDevices[i].volume = max(0.0, min(100.0, targetVol + offset))
            }
        }
        isUpdatingCombined = false
        
        applyAllDeviceVolumes(forceUnmute: targetVol > 0.0)
        OSDOverlayManager.shared.show(type: .volume(level: targetVol, isMuted: targetVol <= 0.0))
    }

    func toggleMute(fromKey: Bool = false) {
        if !fromKey {
            let now = Date().timeIntervalSince1970
            guard now - lastMuteToggleTime > 0.30 else { return }
            lastMuteToggleTime = now
        }
        
        if isMuted {
            let restoreVol = (preMuteVolume > 5.0) ? preMuteVolume : 50.0
            isMuted = false
            
            isUpdatingCombined = true
            combinedVolume = restoreVol
            for i in 0..<audioDevices.count {
                let saved = deviceVolumesBeforeMute[audioDevices[i].id]
                let offset = audioOffsets[audioDevices[i].id] ?? 0.0
                let calculated = max(0.0, min(100.0, restoreVol + offset))
                audioDevices[i].volume = (saved != nil && saved! > 5.0) ? saved! : calculated
            }
            isUpdatingCombined = false
            
            applyAllDeviceVolumes(forceUnmute: true)
            OSDOverlayManager.shared.show(type: .volume(level: restoreVol, isMuted: false))
        } else if combinedVolume <= 0.0 {
            let restoreVol = (preMuteVolume > 5.0) ? preMuteVolume : 50.0
            isMuted = false
            
            isUpdatingCombined = true
            combinedVolume = restoreVol
            for i in 0..<audioDevices.count {
                let saved = deviceVolumesBeforeMute[audioDevices[i].id]
                let offset = audioOffsets[audioDevices[i].id] ?? 0.0
                let calculated = max(0.0, min(100.0, restoreVol + offset))
                audioDevices[i].volume = (saved != nil && saved! > 5.0) ? saved! : calculated
            }
            isUpdatingCombined = false
            
            applyAllDeviceVolumes(forceUnmute: true)
            OSDOverlayManager.shared.show(type: .volume(level: restoreVol, isMuted: false))
        } else {
            preMuteVolume = combinedVolume
            deviceVolumesBeforeMute = Dictionary(uniqueKeysWithValues: audioDevices.map { ($0.id, $0.volume) })
            isMuted = true
            
            isUpdatingCombined = true
            combinedVolume = 0.0
            for i in 0..<audioDevices.count {
                audioDevices[i].volume = 0.0
            }
            isUpdatingCombined = false
            
            applyAllDeviceVolumes(forceUnmute: false)
            OSDOverlayManager.shared.show(type: .volume(level: 0.0, isMuted: true))
        }
    }

    func stepBrightness(up: Bool, isFine: Bool = false) {
        let totalSteps: Double = isFine ? 64.0 : 16.0
        let stepDelta: Double = 100.0 / totalSteps
        
        if !up && combinedBrightness <= 0.0 {
            OSDOverlayManager.shared.show(type: .brightness(level: 0.0))
            return
        }
        if up && combinedBrightness >= 100.0 {
            OSDOverlayManager.shared.show(type: .brightness(level: 100.0))
            return
        }
        
        let currentStep = round(combinedBrightness / stepDelta)
        let nextStep = up ? min(totalSteps, currentStep + 1.0) : max(0.0, currentStep - 1.0)
        let targetBrightness = (nextStep / totalSteps) * 100.0
        
        isUpdatingCombined = true
        combinedBrightness = targetBrightness
        for i in 0..<displays.count {
            if targetBrightness <= 0.0 {
                displays[i].brightness = 0.0
            } else if targetBrightness >= 100.0 {
                displays[i].brightness = 100.0
            } else {
                let offset = displayOffsets[displays[i].id] ?? 0.0
                displays[i].brightness = max(0.0, min(100.0, targetBrightness + offset))
            }
            setBrightness(for: displays[i], level: displays[i].brightness)
        }
        isUpdatingCombined = false
        
        OSDOverlayManager.shared.show(type: .brightness(level: targetBrightness))
    }

    func handleMediaKeyCode(_ code: Int32, isRepeat: Bool, isFine: Bool) {
        let now = Date().timeIntervalSince1970
        
        if code == 7 {
            // Mute must NEVER repeat when held down, with strict synchronous debounce
            guard !isRepeat else { return }
            guard now - lastMuteToggleTime > 0.30 else { return }
            lastMuteToggleTime = now
            DispatchQueue.main.async { [weak self] in
                self?.toggleMute(fromKey: true)
            }
            return
        }
        
        if isRepeat {
            if code == 0 || code == 1 {
                if volumePressStartTime == 0 {
                    volumePressStartTime = (lastVolumeStepTime > 0) ? lastVolumeStepTime : now
                }
                let heldDuration = now - volumePressStartTime
                let paceInterval: TimeInterval
                if heldDuration < 0.4 {
                    paceInterval = 0.110 // Initial measured pace
                } else if heldDuration < 0.85 {
                    paceInterval = 0.070 // Medium acceleration
                } else {
                    paceInterval = 0.040 // Full native cruise speed
                }
                guard now - lastVolumeStepTime >= paceInterval else { return }
                lastVolumeStepTime = now
            } else if code == 2 || code == 3 {
                if brightnessPressStartTime == 0 {
                    brightnessPressStartTime = (lastBrightnessStepTime > 0) ? lastBrightnessStepTime : now
                }
                let heldDuration = now - brightnessPressStartTime
                let paceInterval: TimeInterval
                if heldDuration < 0.4 {
                    paceInterval = 0.110
                } else if heldDuration < 0.85 {
                    paceInterval = 0.070
                } else {
                    paceInterval = 0.040
                }
                guard now - lastBrightnessStepTime >= paceInterval else { return }
                lastBrightnessStepTime = now
            }
        } else {
            if code == 0 || code == 1 {
                volumePressStartTime = now
                lastVolumeStepTime = now
            } else if code == 2 || code == 3 {
                brightnessPressStartTime = now
                lastBrightnessStepTime = now
            }
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            switch code {
            case 0:
                self.stepVolume(up: true, isFine: isFine)
            case 1:
                self.stepVolume(up: false, isFine: isFine)
            case 2:
                self.stepBrightness(up: true, isFine: isFine)
            case 3:
                self.stepBrightness(up: false, isFine: isFine)
            default:
                break
            }
        }
    }

    // MARK: - Native Standalone Bypass
    // When MacBook speakers are selected as active audio out AND no external monitors are connected,
    // yield all hardware key controls completely to macOS native system.
    func shouldBypassHardwareKeyIntercept() -> Bool {
        // 1. Check if any external monitor is connected
        let hasExternalMonitor: Bool
        var displayCount: UInt32 = 0
        var displayList = [CGDirectDisplayID](repeating: 0, count: 16)
        let status = CGGetOnlineDisplayList(16, &displayList, &displayCount)
        if status == .success && displayCount > 0 {
            var foundExternal = false
            for i in 0..<Int(displayCount) {
                let id = displayList[i]
                guard id != 0 else { continue }
                if CGDisplayIsBuiltin(id) == 0 {
                    foundExternal = true
                    break
                }
            }
            hasExternalMonitor = foundExternal
        } else {
            hasExternalMonitor = displays.contains(where: { !$0.isBuiltIn })
        }
        
        // If an external monitor is connected, macAuViSy must handle hardware controls
        if hasExternalMonitor {
            return false
        }
        
        // 2. Check if default audio output device is MacBook built-in speakers
        return isDefaultAudioOutputMacBookSpeakers()
    }
    
    private func isDefaultAudioOutputMacBookSpeakers() -> Bool {
        var defaultOutputDeviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &defaultOutputDeviceID
        )
        guard status == noErr, defaultOutputDeviceID != 0 else { return false }
        
        // Handle Aggregate / Multi-Output Devices
        var subDevAddress = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(defaultOutputDeviceID, &subDevAddress) {
            var subDataSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(defaultOutputDeviceID, &subDevAddress, 0, nil, &subDataSize)
            let subCount = Int(subDataSize) / MemoryLayout<AudioObjectID>.size
            if subCount > 0 {
                var subIDs = [AudioObjectID](repeating: 0, count: subCount)
                AudioObjectGetPropertyData(defaultOutputDeviceID, &subDevAddress, 0, nil, &subDataSize, &subIDs)
                for subID in subIDs {
                    if !isDeviceBuiltInSpeaker(subID) {
                        return false
                    }
                }
                return true
            }
        }
        
        return isDeviceBuiltInSpeaker(defaultOutputDeviceID)
    }
    
    private func isDeviceBuiltInSpeaker(_ deviceID: AudioDeviceID) -> Bool {
        // Transport must be built-in: 'bltn' (1651274862)
        var transAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var tSize = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &transAddress, 0, nil, &tSize, &transport)
        guard transport == 1651274862 /* 'bltn' */ else { return false }
        
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceName: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &deviceName) { ptr in
            AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, ptr)
        }
        guard status == noErr else { return false }
        
        let name = (deviceName as String).lowercased()
        if name.contains("headphones") || name.contains("headset") || name.contains("earphones") {
            return false
        }
        return name.contains("speaker") || name.contains("macbook") || name.contains("built-in") || name.contains("internal")
    }

    private func setupEventTap() {
        // Start passive global monitor for volume keys routed through mediaremoted
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
                guard let self = self else { return }
                // If eventPort (CGEventTap) is active, CGEventTap handles all keys exclusively to prevent duplicates
                guard self.eventPort == nil else { return }
                guard !self.shouldBypassHardwareKeyIntercept() else { return }
                
                guard event.subtype.rawValue == 8 else { return }
                let data = event.data1
                let keyCode = (data & 0xFFFF0000) >> 16
                let keyFlags = (data & 0x0000FFFF)
                let keyType = (keyFlags & 0xFF00) >> 8
                let isRepeat = (keyFlags & 0x1) == 1
                
                // Only process key-down (0xA), NEVER key-up (0xB)
                guard keyType == 0xA else { return }
                
                let code = Int32(keyCode)
                let recognizedKeys: [Int32] = [0, 1, 2, 3, 7]
                guard recognizedKeys.contains(code) else { return }
                
                // Mute must NEVER repeat when held down
                if code == 7 && isRepeat { return }
                
                let now = Date().timeIntervalSince1970
                if code == 7 {
                    guard now - self.lastMuteToggleTime > 0.18 else { return }
                } else if !isRepeat {
                    let lastTime = (code == 0 || code == 1) ? self.lastVolumeStepTime : self.lastBrightnessStepTime
                    guard now - lastTime > 0.05 else { return }
                }
                
                let isFine = event.modifierFlags.contains(.option) && event.modifierFlags.contains(.shift)
                self.handleMediaKeyCode(code, isRepeat: isRepeat, isFine: isFine)
            }
        }

        guard eventPort == nil else { return }
        guard AXIsProcessTrusted() else {
            print("ℹ️ Skipping setupEventTap: Accessibility not yet granted.")
            return
        }
        let eventMask: CGEventMask = (1 << 14) // 14 = NX_SYSDEFINED
        
        let callback: CGEventTapCallBack = { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let refcon = refcon {
                    let appState = Unmanaged<AppState>.fromOpaque(refcon).takeUnretainedValue()
                    if let port = appState.eventPort {
                        CGEvent.tapEnable(tap: port, enable: true)
                    }
                }
                return nil
            }
            
            guard type.rawValue == 14 else { return Unmanaged.passRetained(event) }
            
            let nsEvent = NSEvent(cgEvent: event)
            guard let sysEvent = nsEvent, sysEvent.subtype.rawValue == 8 else {
                return Unmanaged.passRetained(event)
            }
            
            let data = sysEvent.data1
            let keyCode = (data & 0xFFFF0000) >> 16
            let keyFlags = (data & 0x0000FFFF)
            let keyType = (keyFlags & 0xFF00) >> 8
            let isRepeat = (keyFlags & 0x1) == 1
            let code = Int32(keyCode)
            
            // 0=Vol Up (F12), 1=Vol Down (F11), 7=Mute (F10), 2=Bright Up (F2), 3=Bright Down (F1)
            let recognizedKeys: [Int32] = [0, 1, 2, 3, 7]
            
            guard recognizedKeys.contains(code) else {
                return Unmanaged.passRetained(event)
            }
            
            if let refcon = refcon {
                let appState = Unmanaged<AppState>.fromOpaque(refcon).takeUnretainedValue()
                
                // If MacBook built-in speakers are selected as active audio out AND no external monitors are connected,
                // do not override anything! Pass the hardware key event untouched to macOS native handler.
                if appState.shouldBypassHardwareKeyIntercept() {
                    return Unmanaged.passRetained(event)
                }
                
                // Only process key-down (0xA), NEVER key-up (0xB)
                if keyType == 0xA {
                    let flags = event.flags
                    let isFine = flags.contains(.maskAlternate) && flags.contains(.maskShift)
                    appState.handleMediaKeyCode(code, isRepeat: isRepeat, isFine: isFine)
                }
            }
            
            // Always consume the recognized media keys so macOS system doesn't duplicate action
            return nil
        }
        
        let observer = Unmanaged.passUnretained(self).toOpaque()
        
        eventPort = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: observer
        )
        
        if let port = eventPort {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            if let source = runLoopSource {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            CGEvent.tapEnable(tap: port, enable: true)
        }
    }
    
    // MARK: - Hardware Scanning
    func scanDisplays() {
        var displayCount: UInt32 = 0
        var displayList = [CGDirectDisplayID](repeating: 0, count: 16)
        
        var status = CGGetOnlineDisplayList(16, &displayList, &displayCount)
        if status != .success || displayCount == 0 {
            status = CGGetActiveDisplayList(16, &displayList, &displayCount)
        }
        
        if status == .success {
            var newDisplays: [DisplayItem] = []
            var seenIDs = Set<CGDirectDisplayID>()
            for i in 0..<Int(displayCount) {
                let displayID = displayList[i]
                guard displayID != 0 else { continue }
                guard !seenIDs.contains(displayID) else { continue }
                seenIDs.insert(displayID)
                let isBuiltIn = CGDisplayIsBuiltin(displayID) != 0
                
                let displayName = getDisplayName(for: displayID, isBuiltIn: isBuiltIn)
                let isVirtual = displayName.lowercased().contains("usb") ||
                                displayName.lowercased().contains("virtual") ||
                                displayName.lowercased().contains("sidecar") ||
                                displayName.lowercased().contains("airplay") ||
                                displayName.lowercased().contains("dummy") ||
                                displayName.lowercased().contains("trigger") ||
                                displayName.lowercased().contains("displaylink") ||
                                displayName.lowercased().contains("instantview")
                let hasDDC = !isBuiltIn && !isVirtual
                
                var level: Double = 70.0
                let savedByName = UserDefaults.standard.value(forKey: "brightness_\(displayName)") as? Double
                let savedById = UserDefaults.standard.value(forKey: "brightness_\(displayID)") as? Double
                let savedLevel = savedByName ?? savedById

                if isBuiltIn {
                    var brightness: Float = 0.5
                    if let getB = displayServicesGetBrightness {
                        _ = getB(displayID, &brightness)
                    }
                    level = Double(brightness * 100.0)
                } else if hasDDC {
                    if let saved = savedLevel {
                        level = saved
                    } else if let ddcLum = DDCWorker.shared.getLuminance() {
                        level = Double(ddcLum)
                    } else if let existing = self.displays.first(where: { $0.id == displayID }) {
                        level = existing.brightness
                    } else {
                        level = 80.0
                    }
                    DDCWorker.shared.setLuminance(Int(level))
                } else {
                    if let saved = savedLevel {
                        level = saved
                    } else if let existing = self.displays.first(where: { $0.id == displayID }) {
                        level = existing.brightness
                    } else {
                        level = 80.0
                    }
                }
                
                newDisplays.append(DisplayItem(
                    id: displayID,
                    name: displayName,
                    brightness: level,
                    isBuiltIn: isBuiltIn,
                    hasDDC: hasDDC
                ))
            }
            
            DispatchQueue.main.async {
                self.isScanning = true
                self.displays = newDisplays
                if let first = newDisplays.first {
                    self.combinedBrightness = first.brightness
                }
                for display in newDisplays {
                    self.displayOffsets[display.id] = display.brightness - self.combinedBrightness
                    self.applyGammaAndLuminance(for: display)
                }
                self.isScanning = false
            }
        }
    }

    private func getDisplayName(for displayID: CGDirectDisplayID, isBuiltIn: Bool) -> String {
        for screen in NSScreen.screens {
            if let screenNum = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
               screenNum == displayID {
                return screen.localizedName
            }
        }
        return isBuiltIn ? "Built-in Display" : "External Display (\(displayID))"
    }
    
    private func getTargetAudioDeviceIDs() -> [AudioDeviceID] {
        var defaultOutputDeviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &defaultOutputDeviceID)
        
        var subDevAddress = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        if AudioObjectHasProperty(defaultOutputDeviceID, &subDevAddress) {
            var subDataSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(defaultOutputDeviceID, &subDevAddress, 0, nil, &subDataSize)
            let subCount = Int(subDataSize) / MemoryLayout<AudioObjectID>.size
            var subIDs = [AudioObjectID](repeating: 0, count: subCount)
            AudioObjectGetPropertyData(defaultOutputDeviceID, &subDevAddress, 0, nil, &subDataSize, &subIDs)
            return subIDs
        }
        
        return [defaultOutputDeviceID]
    }
    
    func scanAudioDevices() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize)
        guard sizeStatus == noErr else { return }
        
        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var audioDeviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        let getStatus = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &audioDeviceIDs)
        guard getStatus == noErr else { return }
        
        let targetIDs = getTargetAudioDeviceIDs()
        var newAudioDevices: [AudioDeviceItem] = []
        
        for id in audioDeviceIDs {
            // 1. Strict Liveness Check: Discard disconnected/ghost/zombie endpoints
            var isAlive: UInt32 = 0
            var aliveSize = UInt32(MemoryLayout<UInt32>.size)
            var aliveAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let aliveStatus = AudioObjectGetPropertyData(id, &aliveAddress, 0, nil, &aliveSize, &isAlive)
            guard aliveStatus == noErr, isAlive != 0 else { continue }
            
            // 2. Active Output Streams check
            var streamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamDataSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(id, &streamAddress, 0, nil, &streamDataSize)
            guard streamDataSize > 0 else { continue }
            
            // 3. Device Name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var deviceName: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            let status = withUnsafeMutablePointer(to: &deviceName) { ptr in
                AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, ptr)
            }
            guard status == noErr else { continue }
            
            let name = (deviceName as String).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            
            // 4. Device UID for persistent hardware identity
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidCF: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            let uidStatus = withUnsafeMutablePointer(to: &uidCF) { ptr in
                AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &uidSize, ptr)
            }
            let uid = (uidStatus == noErr) ? (uidCF as String) : ""
            
            // 5. Filter Aggregate, Virtual, and Conferencing drivers
            var subDevAddress = AudioObjectPropertyAddress(
                mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var transportAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var transportType: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(id, &transportAddress, 0, nil, &transportSize, &transportType)
            
            let nameLower = name.lowercased()
            if AudioObjectHasProperty(id, &subDevAddress) || 
               transportType == 1735554416 /* grup */ || 
               nameLower.contains("aggregate") || 
               nameLower.contains("multi-output") { 
                continue 
            }
            
            if transportType == 1986622068 /* virt */ ||
               nameLower.contains("teams") ||
               nameLower.contains("zoom") {
                continue
            }
            
            // 6. Direct Volume Acquisition from System CoreAudio
            var volAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            if !AudioObjectHasProperty(id, &volAddress) {
                volAddress.mSelector = kAudioDevicePropertyVolumeScalar
            }
            var volume: Float32 = 0.5
            var volSize = UInt32(MemoryLayout<Float32>.size)
            let savedVolByName = UserDefaults.standard.value(forKey: "volume_\(name)") as? Double
            let savedVolById = UserDefaults.standard.value(forKey: "volume_\(id)") as? Double
            let savedVol = (savedVolByName != nil && savedVolByName! > 0) ? savedVolByName : savedVolById

            let isDisplayTransport = (transportType == 1685090932 /* 'dprt' */ || transportType == 1751412073 /* 'hdmi' */)
            let matchesDDCDisplay = self.displays.contains(where: { $0.hasDDC && (name.localizedCaseInsensitiveContains($0.name) || $0.name.localizedCaseInsensitiveContains(name)) })
            let hasHardwareDDC = isDisplayTransport || matchesDDCDisplay

            if AudioObjectHasProperty(id, &volAddress) {
                let status = AudioObjectGetPropertyData(id, &volAddress, 0, nil, &volSize, &volume)
                if status != noErr {
                    var ch1 = volAddress
                    ch1.mElement = 1
                    if AudioObjectHasProperty(id, &ch1) {
                        _ = AudioObjectGetPropertyData(id, &ch1, 0, nil, &volSize, &volume)
                    }
                }
            } else if hasHardwareDDC {
                if let ddcVol = DDCWorker.shared.getVolume(), ddcVol > 0 {
                    volume = Float32(ddcVol) / 100.0
                } else if let saved = savedVol, saved > 0 {
                    volume = Float32(saved / 100.0)
                } else {
                    volume = 0.5
                }
            } else {
                if let saved = savedVol, saved > 0 {
                    volume = Float32(saved / 100.0)
                } else {
                    volume = 0.5
                }
            }
            
            let isDefault = targetIDs.contains(id)
            let deviceItem = AudioDeviceItem(
                id: id,
                uid: uid,
                name: name,
                volume: Double(volume * 100.0),
                hasHardwareDDC: hasHardwareDDC
            )

            // 7. Strict Real-Time Deduplication:
            // Sourced directly from live system without accumulating stale phantom sliders.
            // If an endpoint with the same UID or same display name is already in the list,
            // keep the canonical active/default one and do not duplicate.
            if let existingIndex = newAudioDevices.firstIndex(where: {
                (!uid.isEmpty && $0.uid == uid) || $0.name == name
            }) {
                if isDefault || (deviceItem.volume > 0 && newAudioDevices[existingIndex].volume <= 0) {
                    newAudioDevices[existingIndex] = deviceItem
                }
                continue
            }
            
            newAudioDevices.append(deviceItem)
        }
        
        DispatchQueue.main.async {
            self.isScanning = true
            self.audioDevices = newAudioDevices
            if let defaultDev = newAudioDevices.first(where: { targetIDs.contains($0.id) }) {
                self.combinedVolume = defaultDev.volume
            } else if let first = newAudioDevices.first {
                self.combinedVolume = first.volume
            }
            for dev in newAudioDevices {
                self.audioOffsets[dev.id] = dev.volume - self.combinedVolume
            }
            self.isScanning = false
        }
    }
    
    // MARK: - Synchronous Zero-Latency Audio Control
    func setVolume(for device: AudioDeviceItem, level: Double) {
        applyAudioSettings(to: device.id, volumeLevel: level, shouldMute: isMuted || level <= 0)
        let hasDDC = audioDevices.first(where: { $0.id == device.id })?.hasHardwareDDC ?? false
        if hasDDC {
            if isMuted || level <= 0 {
                DDCWorker.shared.setMute(true, volume: 0)
            } else {
                DDCWorker.shared.setMute(false, volume: Int(level))
            }
        }
    }

    func syncAllAudioDevices(level: Double, forceUnmute: Bool = false) {
        applyAllDeviceVolumes(forceUnmute: forceUnmute)
    }

    func applyAllDeviceVolumes(forceUnmute: Bool = false) {
        let isMasterMuted = !forceUnmute && (isMuted || combinedVolume <= 0.0)
        var ddcTargetVolume: Int? = nil
        var ddcShouldMute: Bool = false
        
        // 1. Apply volume to each physical device in audioDevices preserving individual ratios
        for device in audioDevices {
            let devClamped = max(0.0, min(100.0, device.volume))
            let devShouldMute = isMasterMuted || devClamped <= 0.0
            applyAudioSettings(to: device.id, volumeLevel: devClamped, shouldMute: devShouldMute)
            
            // Collect DDC external display control state
            if device.hasHardwareDDC {
                ddcShouldMute = devShouldMute
                ddcTargetVolume = Int(devClamped)
            }
        }
        
        // Dispatch DDC control once per state update
        if let targetVol = ddcTargetVolume {
            DDCWorker.shared.setMute(ddcShouldMute, volume: targetVol)
        }
        
        // 2. Apply to any target default output device not in audioDevices (e.g. aggregate sub-devices)
        for devID in getTargetAudioDeviceIDs() {
            if !audioDevices.contains(where: { $0.id == devID }) {
                let devClamped = max(0.0, min(100.0, combinedVolume))
                let devShouldMute = isMasterMuted || devClamped <= 0.0
                applyAudioSettings(to: devID, volumeLevel: devClamped, shouldMute: devShouldMute)
            }
        }
    }

    private func applyAudioSettings(to deviceID: AudioDeviceID, volumeLevel: Double, shouldMute: Bool) {
        // Skip input devices (like microphones)
        var streamAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamDataSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(deviceID, &streamAddress, 0, nil, &streamDataSize)
        guard streamDataSize > 0 else { return }
        
        // Handle Aggregate / Multi-Output Devices recursively
        var subDevAddress = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        if AudioObjectHasProperty(deviceID, &subDevAddress) {
            var subDataSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(deviceID, &subDevAddress, 0, nil, &subDataSize)
            let subCount = Int(subDataSize) / MemoryLayout<AudioObjectID>.size
            var subIDs = [AudioObjectID](repeating: 0, count: subCount)
            AudioObjectGetPropertyData(deviceID, &subDevAddress, 0, nil, &subDataSize, &subIDs)
            
            for subID in subIDs {
                applyAudioSettings(to: subID, volumeLevel: volumeLevel, shouldMute: shouldMute)
            }
            return
        }
        
        // 1. Hardware CoreAudio MUTE property on main, channel 1, and channel 2
        var muteVal: UInt32 = shouldMute ? 1 : 0
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &muteAddress) {
            AudioObjectSetPropertyData(deviceID, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &muteVal)
        }
        muteAddress.mElement = 1
        if AudioObjectHasProperty(deviceID, &muteAddress) {
            AudioObjectSetPropertyData(deviceID, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &muteVal)
        }
        muteAddress.mElement = 2
        if AudioObjectHasProperty(deviceID, &muteAddress) {
            AudioObjectSetPropertyData(deviceID, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &muteVal)
        }
        
        // 2. Synchronous CoreAudio volume scalar
        var volumeScalar = Float32(shouldMute ? 0.0 : (volumeLevel / 100.0))
        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        if !AudioObjectHasProperty(deviceID, &volumeAddress) {
            volumeAddress.mSelector = kAudioDevicePropertyVolumeScalar
        }
        
        var status = AudioObjectSetPropertyData(
            deviceID,
            &volumeAddress,
            0,
            nil,
            UInt32(MemoryLayout<Float32>.size),
            &volumeScalar
        )
        
        // Try channels 1 and 2 if master failed
        if status != noErr {
            volumeAddress.mElement = 1
            if AudioObjectHasProperty(deviceID, &volumeAddress) {
                status = AudioObjectSetPropertyData(
                    deviceID,
                    &volumeAddress,
                    0,
                    nil,
                    UInt32(MemoryLayout<Float32>.size),
                    &volumeScalar
                )
                volumeAddress.mElement = 2
                if AudioObjectHasProperty(deviceID, &volumeAddress) {
                    _ = AudioObjectSetPropertyData(
                        deviceID,
                        &volumeAddress,
                        0,
                        nil,
                        UInt32(MemoryLayout<Float32>.size),
                        &volumeScalar
                    )
                }
            }
        }
        
        UserDefaults.standard.set(volumeLevel, forKey: "volume_\(deviceID)")
        if let devName = audioDevices.first(where: { $0.id == deviceID })?.name {
            UserDefaults.standard.set(volumeLevel, forKey: "volume_\(devName)")
        }
    }
}
