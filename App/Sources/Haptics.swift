import SwiftUI

extension View {
    /// A trackpad haptic tick whenever the control's bound value changes: one
    /// tick per toggle flip, one per slider detent. macOS only plays the
    /// `.levelChange`/`.alignment` sensory-feedback kinds, and only on Macs
    /// with a Force Touch trackpad — everywhere else this is a silent no-op.
    func hapticTick<V: Equatable>(on value: V) -> some View {
        sensoryFeedback(.levelChange, trigger: value)
    }
}
