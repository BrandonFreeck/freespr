import Foundation
import AppKit
import AVFoundation
import ApplicationServices

/// The two TCC permissions freespr needs and how to detect/request/guide them. Input Monitoring is
/// not used: the active hotkey tap needs Accessibility, which is a superset.
///  - Microphone     → AVCaptureDevice authorization
///  - Accessibility  → the global hotkey (active CGEvent tap) AND the optional synthetic Cmd+V
///                     (AXIsProcessTrusted / AXIsProcessTrustedWithOptions). Superset of Input Monitoring.
enum Permissions {
    // MARK: Microphone
    /// The daemon's microphone state as one stable log token. AVAuthorizationStatus has four cases
    /// (AVCaptureDevice.h): notDetermined 0, restricted 1, denied 2, authorized 3. Until access is
    /// granted, capture devices vend SILENT samples — which is why a denied mic used to record 30s of
    /// nothing. Only the daemon's own call means anything: a Terminal-run CLI reports Terminal's grant.
    enum MicState: String {
        case authorized, denied, restricted
        case notDetermined = "not-determined"

        static func current() -> MicState {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:    return .authorized
            case .denied:        return .denied
            case .restricted:    return .restricted
            case .notDetermined: return .notDetermined
            @unknown default:    return .notDetermined   // treat a future case as "ask", never as granted
            }
        }

        /// Sentinel prefix the daemon logs and `status` parses. Keep it free of the hotkey sentinels.
        static let sentinel = "microphone: "
        var logLine: String { MicState.sentinel + rawValue }
    }

    static func hasMicrophone() -> Bool { MicState.current() == .authorized }
    static func requestMicrophone(_ completion: ((Bool) -> Void)? = nil) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in completion?(granted) }
    }

    // MARK: Accessibility
    static func hasAccessibility(prompt: Bool = false) -> Bool {
        if prompt {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            return AXIsProcessTrustedWithOptions(opts)
        }
        return AXIsProcessTrusted()
    }

    // MARK: System Settings panes
    static let micPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    static let axPane  = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

    static func openPane(_ urlString: String) {
        if let u = URL(string: urlString) { NSWorkspace.shared.open(u) }
    }

}
