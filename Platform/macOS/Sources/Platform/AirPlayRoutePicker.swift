import AVKit
import AppKit
import SwiftUI

/// The AirPlay button.
///
/// The same `AVRoutePickerView` the phone uses, as an `NSView`. See the iOS copy
/// for why the system view rather than a hand-built list.
///
/// No route monitor here to go with it. macOS has no `AVAudioSession`, so there
/// is no route-change notification and no `currentRoute` to read — which is the
/// same reason `supportsAudioSession` is false on this platform. The picker
/// reports its own active state and that is all there is.
public struct AirPlayRoutePicker: NSViewRepresentable {

    private let tint: NSColor
    private let activeTint: NSColor

    public init(tint: Color, activeTint: Color) {
        self.tint = NSColor(tint)
        self.activeTint = NSColor(activeTint)
    }

    public func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.setRoutePickerButtonColor(tint, for: .normal)
        // What the button looks like while something is playing elsewhere.
        // Without it there is no way to tell from the control whether the sound
        // is coming out of this Mac or a speaker in another room.
        picker.setRoutePickerButtonColor(activeTint, for: .active)
        picker.isRoutePickerButtonBordered = false
        return picker
    }

    public func updateNSView(_ picker: AVRoutePickerView, context: Context) {
        picker.setRoutePickerButtonColor(tint, for: .normal)
        picker.setRoutePickerButtonColor(activeTint, for: .active)
    }
}
