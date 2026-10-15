import Testing

@testable import Chess

@Suite("Chess rules")
struct ChessCoreTests {
    @Test func startingMoveTreeCounts() {
        let game = Game()
        #expect(ChessRules.perft(game, depth: 1) == 20)
        #expect(ChessRules.perft(game, depth: 2) == 400)
        #expect(ChessRules.perft(game, depth: 3) == 8_902)
    }

    @Test func tacticalMoveTreeCounts() throws {
        let game = try #require(Game(
            fen: "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1"
        ))
        #expect(ChessRules.perft(game, depth: 1) == 14)
        #expect(ChessRules.perft(game, depth: 2) == 191)
        #expect(ChessRules.perft(game, depth: 3) == 2_812)
    }

    @Test func slidingPiecesStopAtFirstOccupiedSquare() throws {
        let game = try #require(Game(fen: "4k3/8/8/3p4/3R1P2/8/8/4K3 w - - 0 1"))
        let moves = ChessRules.legalMoves(from: .d4, in: game)
        #expect(moves.contains { $0.uci == "d4d5" && $0.isCapture })
        #expect(!moves.contains { $0.uci == "d4d6" })
        #expect(!moves.contains { $0.uci == "d4f4" })
    }

    @Test func pinnedPieceCannotExposeKing() throws {
        let game = try #require(Game(fen: "4r1k1/8/8/8/8/8/4R3/4K3 w - - 0 1"))
        let moves = ChessRules.legalMoves(from: .e2, in: game)
        #expect(!moves.contains { $0.to.file != .e })
        #expect(moves.contains { $0.uci == "e2e8" })
    }

    @Test func castlingRequiresSafePathAndMovesRook() throws {
        let clear = try #require(Game(fen: "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1"))
        let castles = ChessRules.legalMoves(from: .e1, in: clear)
        #expect(castles.contains { $0.uci == "e1g1" })
        #expect(castles.contains { $0.uci == "e1c1" })
        let castled = try ChessRules.applying(uci: "e1g1", to: clear)
        #expect(castled.board[.g1] == .whiteKing)
        #expect(castled.board[.f1] == .whiteRook)
        #expect(!castled.castlingRights.contains(.whiteKingside))

        let attacked = try #require(Game(fen: "r3k2r/8/b7/8/8/8/8/R3K2R w KQkq - 0 1"))
        #expect(!ChessRules.legalMoves(from: .e1, in: attacked).contains { $0.uci == "e1g1" })
    }

    @Test func enPassantUsesTheSameMoveApplication() throws {
        let game = try #require(Game(fen: "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1"))
        let move = try #require(ChessRules.legalMoves(in: game).first { $0.uci == "e5d6" })
        guard case .enPassant = move.kind else {
            Issue.record("Expected an en passant move.")
            return
        }
        let next = try ChessRules.applying(move, to: game)
        #expect(next.board[.d6] == .whitePawn)
        #expect(next.board[.d5] == nil)
        #expect(next.halfmoveClock == 0)
    }

    @Test func promotionCreatesFourUniqueUCIChoices() throws {
        let game = try #require(Game(fen: "4k3/P7/8/8/8/8/8/4K3 w - - 0 1"))
        let moves = ChessRules.legalMoves(from: .a7, in: game)
        #expect(Set(moves.map(\.uci)) == ["a7a8q", "a7a8r", "a7a8b", "a7a8n"])
        let next = try ChessRules.applying(uci: "a7a8n", to: game)
        #expect(next.board[.a8] == .whiteKnight)
    }

    @Test func terminalPositionsDistinguishMateAndStalemate() throws {
        let mate = try #require(Game(fen: "7k/6Q1/6K1/8/8/8/8/8 b - - 0 1"))
        #expect(ChessRules.outcome(in: mate) == .checkmate(winner: .white))
        let stalemate = try #require(Game(fen: "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1"))
        #expect(ChessRules.outcome(in: stalemate) == .stalemate)
    }

    @Test func repetitionAndMoveCountersEndTheGame() throws {
        var game = Game()
        for move in [
            "g1f3", "g8f6", "f3g1", "f6g8",
            "g1f3", "g8f6", "f3g1", "f6g8",
        ] {
            game = try ChessRules.applying(uci: move, to: game)
        }
        #expect(game.currentRepetitionCount == 3)
        #expect(ChessRules.outcome(in: game) == .drawByRepetition)
        #expect(game.halfmoveClock == 8)
        #expect(game.fullmoveNumber == 5)

        let fifty = try #require(Game(fen: "4k2r/8/8/8/8/8/8/R3K3 w - - 100 51"))
        #expect(ChessRules.outcome(in: fifty) == .drawByFiftyMoveRule)
    }

    @Test func detectsStandardInsufficientMaterial() throws {
        for fen in [
            "4k3/8/8/8/8/8/8/4K3 w - - 0 1",
            "4k3/8/8/8/8/8/8/2B1K3 w - - 0 1",
            "4k3/8/8/8/8/8/8/2N1K3 w - - 0 1",
            "4kb2/8/8/8/8/8/8/2B1K3 w - - 0 1",
        ] {
            let game = try #require(Game(fen: fen))
            #expect(ChessRules.hasInsufficientMaterial(game.board))
        }
        let oppositeBishops = try #require(Game(fen: "2b1k3/8/8/8/8/8/8/2B1K3 w - - 0 1"))
        #expect(!ChessRules.hasInsufficientMaterial(oppositeBishops.board))
    }

    @Test func fenAsciiAndNotationDescribeThePosition() throws {
        var game = Game()
        game = try ChessRules.applying(uci: "e2e4", to: game)
        #expect(game.fen == "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1")
        #expect(game.asciiBoard.contains("4 . . . . P . . ."))
        #expect(game.coordinateMoveHistory == "1. e2e4")

        let capture = try #require(Game(fen: "4k3/8/8/3p4/4P3/8/8/4K3 w - - 0 1"))
        let move = try #require(ChessRules.legalMoves(in: capture).first { $0.uci == "e4d5" })
        #expect(capture.notation(for: move) == "exd5")
    }

    @Test func squareColorsPutADarkSquareOnA1() {
        #expect(Board.Square.a1.color == .dark)
        #expect(Board.Square.h1.color == .light)
        #expect(Board.Square.a8.color == .light)
        #expect(Board.Square.h8.color == .dark)
        #expect(Board.Square.d4.color == .dark)
        #expect(Board.Square.e4.color == .light)
    }

    @Test func notationUsesFileRankOrBothToDisambiguate() throws {
        let game = try #require(Game(fen: "6k1/8/8/8/8/Q7/7K/Q1Q5 w - - 0 1"))
        func notation(_ uci: String) throws -> String {
            let move = try #require(ChessRules.legalMoves(in: game).first { $0.uci == uci })
            return game.notation(for: move)
        }
        #expect(try notation("a1b2") == "Qa1b2")
        #expect(try notation("a3b2") == "Q3b2")
        #expect(try notation("c1b2") == "Qcb2")
        #expect(try notation("a3b3") == "Qb3+")
    }
}
