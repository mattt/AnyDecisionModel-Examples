import SpriteKit
import SwiftUI

struct ContentView: View {
    let controller: EmojiMagnetController
    @State private var scene: MagnetScene
    @State private var preferredFramesPerSecond = MagnetFrameRate.current
    @FocusState private var fieldIsFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReducesMotion

    init(controller: EmojiMagnetController) {
        self.controller = controller
        _scene = State(initialValue: MagnetScene(items: controller.catalog))
    }

    private var reducesMotion: Bool {
        #if DEBUG
        systemReducesMotion || EmojiMagnetDebugAutomation.reducesMotion
        #else
        systemReducesMotion
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                PhraseField(controller: controller, isFocused: $fieldIsFocused)
                StatusView(controller: controller)
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 4)

            SpriteView(
                scene: scene,
                preferredFramesPerSecond: preferredFramesPerSecond,
                options: [.allowsTransparency]
            )
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Emoji")
                .accessibilityChildren {
                    ForEach(controller.catalog) { item in
                        Text(item.glyph)
                            .accessibilityLabel(item.name)
                            .accessibilityValue(controller.attractedIDs.contains(item.id) ? "Matches" : "")
                    }
                }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand(perform: clear)
        .defaultFocus($fieldIsFocused, true)
        .onAppear {
            preferredFramesPerSecond = MagnetFrameRate.current
            scene.setReducesMotion(reducesMotion)
            scene.setAttracted(controller.attractedIDs)
            // After a drag, the scene has keyboard focus and receives Escape itself.
            scene.onCancel = clear
            controller.start()
        }
        .task {
            // The window accepts focus only after it becomes key.
            try? await Task.sleep(for: .milliseconds(300))
            fieldIsFocused = true
        }
        .onChange(of: controller.attractedIDs) { _, ids in scene.setAttracted(ids) }
        .onChange(of: reducesMotion) { _, reduces in scene.setReducesMotion(reduces) }
        .onReceive(
            NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
                .merge(with: NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification))
                .receive(on: RunLoop.main)
        ) { _ in
            preferredFramesPerSecond = MagnetFrameRate.current
        }
        .onDisappear { controller.close() }
    }

    private func clear() {
        controller.clear()
        fieldIsFocused = true
    }
}

/// The large rounded text field with its clear button.
private struct PhraseField: View {
    let controller: EmojiMagnetController
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(
                "Describe a group, such as \u{201C}animals\u{201D}",
                text: Binding(get: { controller.phrase }, set: { controller.setPhrase($0) })
            )
            .textFieldStyle(.plain)
            .font(.system(size: 30, weight: .medium, design: .rounded))
            .focused(isFocused)
            .accessibilityLabel("Phrase")
            if !controller.phrase.isEmpty {
                Button {
                    controller.clear()
                    isFocused.wrappedValue = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear the phrase and release every item")
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor))
        }
    }
}

/// Model loading, evaluation progress, errors, and the matching-items summary.
private struct StatusView: View {
    let controller: EmojiMagnetController

    var body: some View {
        HStack(spacing: 8) {
            if let error = controller.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                Text(error)
                    .lineLimit(2)
                Button("Retry") { controller.retry() }
                    .controlSize(.small)
            } else if controller.isLoading {
                ProgressView()
                    .controlSize(.small)
                Text("Loading the model. The first use can download model weights.")
            } else if controller.isEvaluating {
                ProgressView(value: Double(controller.evaluatedIDs.count), total: Double(controller.catalog.count))
                    .frame(width: 120)
                    .accessibilityHidden(true)
                Text("Checking \(controller.evaluatedIDs.count) of \(controller.catalog.count) items")
            } else if !controller.phrase.isEmpty {
                Text(summary)
                    .accessibilityLabel(accessibilitySummary)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(minHeight: 22)
        .accessibilityElement(children: .contain)
    }

    private var summary: String {
        switch controller.attractedIDs.count {
        case 0: "No matching items"
        case 1: "1 matching item"
        case let count: "\(count) matching items"
        }
    }

    private var accessibilitySummary: String {
        let names = controller.attractedItems.map(\.name)
        return names.isEmpty ? summary : "\(summary): \(names.joined(separator: ", "))"
    }
}

enum MagnetFrameRate {
    static var current: Int {
        preferred(
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState
        )
    }

    /// SpriteKit limits this request to a rate supported by the current display.
    static func preferred(lowPowerMode: Bool, thermalState: ProcessInfo.ThermalState) -> Int {
        switch thermalState {
        case .nominal, .fair: lowPowerMode ? 60 : 120
        case .serious: 60
        case .critical: 30
        @unknown default: 60
        }
    }
}
