import SwiftUI

/// The full feature tour — first-run welcome and post-update "what's new"
/// in one window. Content lives in FeatureGuide; entries newer than the
/// version the user last saw get a NEW badge.
struct WelcomeView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("👋 Welcome to Agent Babysitter")
                    .font(.title2).fontWeight(.semibold)
                Text("It keeps an eye on your AI coding agents so you don't have to keep switching windows. Here's everything it does — new additions are badged.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            Divider()

            // ScrollView content is invisible to the snapshot renderer;
            // QA renders use the plain stack. App behavior unchanged.
            if AppModel.isSnapshotMode {
                tourContent
            } else {
                ScrollView { tourContent }
            }

            Divider()
            HStack {
                Text("Everything above works out of the box.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") {
                    model.markGuideSeen()
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 480)
        .frame(height: AppModel.isSnapshotMode ? nil : 560)
        .onDisappear { model.markGuideSeen() }
    }

    private var tourContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(FeatureGuide.sections) { section in
                VStack(alignment: .leading, spacing: 10) {
                    Text(section.name)
                        .font(.headline)
                    ForEach(section.tips) { tip in
                        tipRow(tip)
                    }
                }
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private func tipRow(_ tip: FeatureGuide.Tip) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: tip.symbol)
                .font(.body)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(tip.title)
                        .font(.callout).fontWeight(.medium)
                    if model.isNewTip(tip) {
                        Text("NEW")
                            .font(.caption2).fontWeight(.bold)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.2),
                                        in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(tip.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
