import SwiftUI

struct ContentView: View {
    @Bindable var controller: ChessGameController
    @State private var selection = MoveSelection()
    @State private var promotionMoves: [Game.Move] = []
    @Binding var showsInspector: Bool

    var body: some View {
        VStack(spacing: 12) {
            StatusView(controller: controller)
            ChessboardView(
                game: controller.game,
                bottomColor: controller.bottomColor,
                selection: selection,
                onActivate: activate,
                onCancel: clearSelection
            )
        }
        .padding()
        .frame(minWidth: 540)
        .inspector(isPresented: $showsInspector) {
            InspectorView(controller: controller)
                .inspectorColumnWidth(min: 260, ideal: 320, max: 460)
        }
        .toolbar { toolbar }
        .confirmationDialog(
            "Promote Pawn",
            isPresented: Binding(
                get: { !promotionMoves.isEmpty },
                set: { if !$0 { promotionMoves = [] } }
            )
        ) {
            ForEach(promotionMoves, id: \.uci) { move in
                Button(promotionName(move.promotionKind)) {
                    controller.makeHumanMove(move)
                    clearSelection()
                }
            }
        } message: {
            if let square = promotionMoves.first?.to {
                Text("Choose a piece for the pawn on \(square.notation).")
            }
        }
        .onChange(of: controller.game.fen) { clearSelection() }
        .onChange(of: controller.mode) { clearSelection() }
        .onChange(of: controller.acceptsHumanMoves) { _, accepts in
            if !accepts { clearSelection() }
        }
        .onChange(of: controller.moveNotations) { _, notations in
            guard let last = notations.last else { return }
            let mover = controller.game.turn.opposite
            AccessibilityNotification.Announcement("\(mover.name) played \(last)").post()
        }
        .onDisappear { controller.close() }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                controller.newGame()
            } label: {
                Label("New Game", systemImage: "plus")
            }
            .help("Start a new game")
        }

        ToolbarItem(placement: .principal) {
            Picker("Mode", selection: Binding(
                get: { controller.mode },
                set: { controller.setMode($0) }
            )) {
                ForEach(PlayMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .help("Choose who plays each side")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if controller.mode == .selfPlay {
                Button {
                    controller.toggleSelfPlay()
                } label: {
                    if controller.isRunning {
                        Label("Pause", systemImage: "pause.fill")
                    } else {
                        Label("Start", systemImage: "play.fill")
                    }
                }
                .disabled(!controller.canToggleSelfPlay)
                .help(controller.isRunning ? "Pause self-play" : "Start self-play")

                Button {
                    controller.step()
                } label: {
                    Label("Step", systemImage: "forward.frame.fill")
                }
                .disabled(!controller.canStep)
                .help("Let the model make one move")
            }

            Button {
                controller.flipBoard()
            } label: {
                Label("Flip Board", systemImage: "arrow.up.arrow.down")
            }
            .help("Show the other side at the bottom")

            Button {
                showsInspector.toggle()
            } label: {
                Label(
                    showsInspector ? "Hide Inspector" : "Show Inspector",
                    systemImage: "sidebar.trailing"
                )
            }
            .help(showsInspector ? "Hide the inspector" : "Show the inspector")
        }
    }

    private func activate(_ square: Board.Square) {
        guard controller.acceptsHumanMoves else {
            clearSelection()
            return
        }
        switch selection.activate(square, in: controller.game, legalMoves: controller.legalMoves(from:)) {
        case .none:
            break
        case .move(let move):
            controller.makeHumanMove(move)
        case .promotion(let moves):
            promotionMoves = moves
        }
    }

    private func clearSelection() {
        selection.clear()
        promotionMoves = []
    }

    private func promotionName(_ kind: Piece.Kind?) -> String {
        switch kind {
        case .queen: "Queen"
        case .rook: "Rook"
        case .bishop: "Bishop"
        case .knight: "Knight"
        default: "Piece"
        }
    }
}

/// The game state above the board: whose turn it is, model activity, errors, and results.
private struct StatusView: View {
    let controller: ChessGameController

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                if controller.isThinking {
                    ProgressView()
                        .controlSize(.small)
                    Text("The model is choosing a move for \(controller.game.turn.name).")
                } else if let error = controller.errorMessage {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                    Text(error)
                        .lineLimit(2)
                    if controller.canRetry {
                        Button("Retry") { controller.retry() }
                    }
                } else if let summary = controller.outcome.summary {
                    Image(systemName: "flag.checkered")
                        .accessibilityHidden(true)
                    Text(summary)
                } else {
                    Text(turnText)
                }
            }
            .font(.headline)

            if controller.isThinking, !controller.hasCompletedModelMove {
                Text("The first model move can download model weights and take longer.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .contain)
    }

    private var turnText: String {
        let turn = controller.game.turn.name
        let check = ChessRules.isInCheck(controller.game.turn, board: controller.game.board)
        let paused = controller.mode == .selfPlay && !controller.isRunning ? " Self-play is paused." : ""
        return check ? "\(turn) to move, in check.\(paused)" : "\(turn) to move.\(paused)"
    }
}
