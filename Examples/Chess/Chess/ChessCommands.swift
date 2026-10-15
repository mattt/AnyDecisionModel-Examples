import SwiftUI

/// Menu bar commands for every toolbar action.
struct ChessCommands: Commands {
    let controller: ChessGameController
    @Binding var showsInspector: Bool

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Game") { controller.newGame() }
                .keyboardShortcut("n")
        }
        CommandMenu("Game") {
            GameMenuContent(controller: controller)
        }
        CommandGroup(before: .toolbar) {
            Button("Flip Board") { controller.flipBoard() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button(showsInspector ? "Hide Inspector" : "Show Inspector") {
                showsInspector.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
        }
    }
}

private struct GameMenuContent: View {
    let controller: ChessGameController

    var body: some View {
        Picker("Mode", selection: Binding(
            get: { controller.mode },
            set: { controller.setMode($0) }
        )) {
            ForEach(PlayMode.allCases, id: \.self) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.inline)

        Divider()

        Button(controller.isRunning ? "Pause Self-Play" : "Start Self-Play") {
            controller.toggleSelfPlay()
        }
        .keyboardShortcut("r")
        .disabled(!controller.canToggleSelfPlay)

        Button("Step Self-Play") { controller.step() }
            .keyboardShortcut(.rightArrow)
            .disabled(!controller.canStep)

        Divider()

        Button("Retry Model Move") { controller.retry() }
            .disabled(!controller.canRetry)
    }
}
