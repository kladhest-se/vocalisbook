import AVKit
import SwiftUI
import UIKit

/// The AirPlay button.
///
/// Routing needed nothing: the audio session already uses
/// `RouteSharingPolicy.longFormAudio`, which is what puts an audiobook in the
/// AirPlay 2 *audio* group — the one that survives leaving the app, and the
/// reason a HomePod keeps playing. What was missing was a way to pick a route
/// without going out to Control Centre.
///
/// `AVRoutePickerView` rather than a hand-built list. The system view is the only
/// thing that can enumerate routes, it updates itself, and it shows the active
/// one — reimplementing that means `MPVolumeView` archaeology and a control that
/// lies whenever a route changes elsewhere.
///
/// It is a UIKit view, which is why this is here and not in `PlatformShared`.
/// Apple's control, used as the control.
///
/// A previous version hid this and pressed its internal `UIButton` from a
/// SwiftUI button of our own, on the theory that a small frame was swallowing
/// taps. That was the wrong diagnosis: **the Simulator has no AirPlay routes to
/// find**, so the picker has nothing to present and tapping it does nothing
/// there however it is wired — the same class of thing as `setAlternateIconName`
/// failing on the Simulator, and it cost a hack that reached into a private view
/// hierarchy to fix a problem that was not there.
///
/// So this is the plain system view again, at 44pt, which is the tappable
/// control. On a device it works because it is the control Apple ships; on the
/// Simulator it will still do nothing, and that is not a bug in this app.
public struct AirPlayRoutePicker: UIViewRepresentable {

    private let tint: UIColor
    private let activeTint: UIColor

    public init(tint: Color, activeTint: Color) {
        self.tint = UIColor(tint)
        self.activeTint = UIColor(activeTint)
    }

    public func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = tint
        // The colour the icon takes while something is actually playing to a
        // route. Without it the button looks identical whether the sound is
        // coming out of this device or a speaker in another room, which is the
        // one thing it exists to tell you.
        picker.activeTintColor = activeTint
        picker.prioritizesVideoDevices = false
        return picker
    }

    public func updateUIView(_ picker: AVRoutePickerView, context: Context) {
        picker.tintColor = tint
        picker.activeTintColor = activeTint
    }
}

/// Where the sound is going, in words.
///
/// The picker shows a state; this says a name. Worth having on the player screen
/// because "why is this coming out of the phone" and "why is this coming out of
/// the kitchen" are both questions the icon alone cannot answer.
@MainActor
@Observable
public final class AudioRouteMonitor {

    public private(set) var name: String?

    /// True when output is somewhere other than this device.
    public private(set) var isExternal = false

    /// Holds the observer so it can be handed back.
    ///
    /// Not a stored property on this type: it is `@MainActor`, which makes its
    /// `deinit` nonisolated, and a nonisolated `deinit` may not touch
    /// main-actor-isolated stored properties — Swift 6 rejects it outright. The
    /// same shape as `AudiobookPlayer.Registrations`, and for the same reason.
    private final class Registration {
        var token: (any NSObjectProtocol)?
        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }

    private let registration = Registration()

    public init() {
        refresh()
        // MAIN-QUEUE: delivered on the main queue by the `queue:` argument.
        registration.token = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The notification is not read. `Notification` is not Sendable, and
            // everything wanted here is on the session rather than in the
            // userInfo — see the note in `WindowSizer.followResizes`.
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard let output = outputs.first else {
            name = nil
            isExternal = false
            return
        }
        name = output.portName
        switch output.portType {
        case .airPlay, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .HDMI, .usbAudio:
            isExternal = true
        default:
            isExternal = false
        }
    }
}
