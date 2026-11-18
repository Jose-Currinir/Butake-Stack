import AppKit
import SwiftUI

/// The bottom of the window: Stack's state, said once (its details open from the indicator), and
/// the work in progress.
struct StatusBar: View {
    let store: StackStore
    var body: some View {
        HStack(spacing: 10) {
            StackStateIndicator(store: store)
            if let busy = store.busy {
                Divider().frame(height: 10)
                ProgressView().controlSize(.mini)
                Text(busy).lineLimit(1).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.uiCaption)
        .padding(.horizontal, 10).frame(height: 29)
        .background(Brand.bar)
        .overlay(alignment: .top) { Divider() }
        .animated(.snappy, value: store.busy)
    }
}
