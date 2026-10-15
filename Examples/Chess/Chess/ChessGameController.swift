import AnyDecisionModel
import Foundation
import Observation

enum PlayMode: String, CaseIterable, Hashable, Sendable {
    case humanWhite = "Human plays White"
    case humanBlack = "Human plays Black"
    case selfPlay = "Model self-play"
}

@MainActor
@Observable
final class ChessGameController {
    private(set) var game = Game()
    private(set) var mode: PlayMode = .humanWhite
    private(set) var isThinking = false
    private(set) var isRunning = false
    private(set) var errorMessage: String?
    private(set) var lastDecision: ChessDecision?

    /// Standard algebraic notation for each move in `game.history`.
    private(set) var moveNotations: [String] = []
    /// The last model decision with notation from the position before its move.
    private(set) var lastDecisionSummary: DecisionSummary?
    /// The color shown at the bottom of the board.
    private(set) var bottomColor: Piece.Color = .white
    /// Whether the model has completed a move since the app started.
    private(set) var hasCompletedModelMove = false

    private let service: ChessDecisionService
    let startingGame: Game
    private var inferenceTask: Task<Void, Never>?
    private var generation = UUID()

    init(service: ChessDecisionService) {
        self.service = service
        startingGame = Game()
    }

    init(service: ChessDecisionService, mode: PlayMode, startingGame: Game, moves: [String] = []) throws {
        self.service = service
        self.startingGame = startingGame
        self.mode = mode
        bottomColor = mode.defaultBottomColor
        game = startingGame
        for uci in moves {
            guard let move = ChessRules.legalMoves(in: game).first(where: { $0.uci == uci }) else {
                throw ChessRuleError.illegalMove(uci)
            }
            try accept(move)
        }
    }

    convenience init() {
        self.init(service: ChessDecisionService(
            model: MLXDecisionModel(modelID: "mlx-community/Qwen3-4B-Instruct-2507-4bit")
        ))
    }

    var outcome: Game.Outcome { ChessRules.outcome(in: game) }
    var legalMoves: [Game.Move] { ChessRules.legalMoves(in: game) }
    var canRetry: Bool { errorMessage != nil && !outcome.isTerminal }

    var acceptsHumanMoves: Bool { isHumanTurn && !isThinking && !outcome.isTerminal }
    var canToggleSelfPlay: Bool { mode == .selfPlay && (isRunning || !outcome.isTerminal) }
    var canStep: Bool { mode == .selfPlay && !isThinking && !outcome.isTerminal }

    func setMode(_ newMode: PlayMode) {
        guard mode != newMode else { return }
        cancelInference()
        mode = newMode
        bottomColor = newMode.defaultBottomColor
        isRunning = false
        errorMessage = nil
        startModelTurnIfNeeded()
    }

    func newGame() {
        cancelInference()
        game = startingGame
        moveNotations = []
        lastDecision = nil
        lastDecisionSummary = nil
        errorMessage = nil
        isRunning = false
        startModelTurnIfNeeded()
    }

    func flipBoard() {
        bottomColor = bottomColor.opposite
    }

    func legalMoves(from square: Board.Square) -> [Game.Move] {
        guard isHumanTurn else { return [] }
        return ChessRules.legalMoves(from: square, in: game)
    }

    func makeHumanMove(_ move: Game.Move) {
        guard acceptsHumanMoves else { return }
        do {
            try accept(move)
            errorMessage = nil
            startModelTurnIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleSelfPlay() {
        guard mode == .selfPlay else { return }
        if isRunning {
            pause()
        } else if !outcome.isTerminal {
            isRunning = true
            requestModelMove(continueSelfPlay: true)
        }
    }

    func step() {
        guard mode == .selfPlay, !isThinking, !outcome.isTerminal else { return }
        isRunning = false
        requestModelMove(continueSelfPlay: false)
    }

    func pause() {
        isRunning = false
        cancelInference()
    }

    func retry() {
        guard canRetry else { return }
        errorMessage = nil
        requestModelMove(continueSelfPlay: mode == .selfPlay && isRunning)
    }

    func close() {
        isRunning = false
        cancelInference()
    }

    private var isHumanTurn: Bool {
        switch mode {
        case .humanWhite: game.turn == .white
        case .humanBlack: game.turn == .black
        case .selfPlay: false
        }
    }

    private var isModelTurn: Bool { !isHumanTurn && !outcome.isTerminal }

    func startModelTurnIfNeeded() {
        guard mode != .selfPlay, isModelTurn else { return }
        requestModelMove(continueSelfPlay: false)
    }

    private func requestModelMove(continueSelfPlay: Bool) {
        guard inferenceTask == nil, isModelTurn else { return }
        let snapshot = game
        let requestGeneration = generation
        isThinking = true
        inferenceTask = Task { [weak self, service] in
            do {
                let decision = try await service.decide(in: snapshot)
                try Task.checkCancellation()
                guard let self,
                      self.generation == requestGeneration,
                      self.game.fen == snapshot.fen,
                      let move = ChessRules.legalMoves(in: self.game).first(where: {
                          $0.uci == decision.move.uci
                      })
                else { return }
                let summary = DecisionSummary(decision: decision, before: self.game)
                try self.accept(move)
                self.lastDecision = decision
                self.lastDecisionSummary = summary
                self.hasCompletedModelMove = true
                self.errorMessage = nil
                self.finishInference()
                if self.outcome.isTerminal {
                    self.isRunning = false
                } else if continueSelfPlay && self.isRunning {
                    self.requestModelMove(continueSelfPlay: true)
                }
            } catch is CancellationError {
                guard let self, self.generation == requestGeneration else { return }
                self.finishInference()
            } catch {
                guard let self, self.generation == requestGeneration else { return }
                self.errorMessage = error.localizedDescription
                self.isRunning = false
                self.finishInference()
            }
        }
    }

    /// Records notation from the current position, then applies the move.
    /// Human and model moves both use this path.
    private func accept(_ move: Game.Move) throws {
        let notation = game.notation(for: move)
        game = try ChessRules.applying(move, to: game)
        moveNotations.append(notation)
    }

    private func cancelInference() {
        generation = UUID()
        inferenceTask?.cancel()
        inferenceTask = nil
        isThinking = false
    }

    private func finishInference() {
        inferenceTask = nil
        isThinking = false
    }
}
