enum ChessRuleError: Error, Equatable, Sendable {
    case illegalMove(String)
}

enum ChessRules {
    static func legalMoves(in game: Game) -> [Game.Move] {
        pseudoLegalMoves(in: game).filter { move in
            let next = applyingUnchecked(move, to: game)
            return !isInCheck(game.turn, board: next.board)
        }
    }

    static func legalMoves(from square: Board.Square, in game: Game) -> [Game.Move] {
        legalMoves(in: game).filter { $0.from == square }
    }

    static func applying(_ move: Game.Move, to game: Game) throws -> Game {
        guard let legalMove = legalMoves(in: game).first(where: { $0.uci == move.uci }) else {
            throw ChessRuleError.illegalMove(move.uci)
        }
        return applyingUnchecked(legalMove, to: game)
    }

    static func applying(uci: String, to game: Game) throws -> Game {
        guard let move = legalMoves(in: game).first(where: { $0.uci == uci }) else {
            throw ChessRuleError.illegalMove(uci)
        }
        return applyingUnchecked(move, to: game)
    }

    static func outcome(in game: Game) -> Game.Outcome {
        let moves = legalMoves(in: game)
        if moves.isEmpty {
            return isInCheck(game.turn, board: game.board)
                ? .checkmate(winner: game.turn.opposite)
                : .stalemate
        }
        if game.currentRepetitionCount >= 3 { return .drawByRepetition }
        if game.halfmoveClock >= 100 { return .drawByFiftyMoveRule }
        if hasInsufficientMaterial(game.board) { return .drawByInsufficientMaterial }
        return .inProgress
    }

    static func isInCheck(_ color: Piece.Color, board: Board) -> Bool {
        guard let king = board.pieces.first(where: {
            $0.value.color == color && $0.value.kind == .king
        })?.key else { return true }
        return isSquareAttacked(king, by: color.opposite, board: board)
    }

    static func isSquareAttacked(
        _ square: Board.Square,
        by attacker: Piece.Color,
        board: Board
    ) -> Bool {
        let pawnSourceDelta = attacker == .white ? -1 : 1
        for fileDelta in [-1, 1] {
            if let source = square.offset(file: fileDelta, rank: pawnSourceDelta),
               board[source] == Piece(color: attacker, kind: .pawn)
            {
                return true
            }
        }

        for (file, rank) in knightOffsets {
            if let source = square.offset(file: file, rank: rank),
               board[source] == Piece(color: attacker, kind: .knight)
            {
                return true
            }
        }

        for (file, rank) in kingOffsets {
            if let source = square.offset(file: file, rank: rank),
               board[source] == Piece(color: attacker, kind: .king)
            {
                return true
            }
        }

        if attackedAlong(
            square,
            by: attacker,
            board: board,
            directions: orthogonalDirections,
            kinds: [.rook, .queen]
        ) { return true }
        return attackedAlong(
            square,
            by: attacker,
            board: board,
            directions: diagonalDirections,
            kinds: [.bishop, .queen]
        )
    }

    static func hasInsufficientMaterial(_ board: Board) -> Bool {
        let nonKings = board.pieces.filter { $0.value.kind != .king }
        if nonKings.isEmpty { return true }
        if nonKings.count == 1,
           let kind = nonKings.first?.value.kind,
           kind == .bishop || kind == .knight
        {
            return true
        }
        guard nonKings.allSatisfy({ $0.value.kind == .bishop }) else { return false }
        let squareColors = Set(nonKings.map { $0.key.color })
        return squareColors.count == 1
    }

    static func perft(_ game: Game, depth: Int) -> Int {
        if depth == 0 { return 1 }
        return legalMoves(in: game).reduce(0) { count, move in
            count + perft(applyingUnchecked(move, to: game), depth: depth - 1)
        }
    }

    private static let knightOffsets = [
        (1, 2), (2, 1), (2, -1), (1, -2),
        (-1, -2), (-2, -1), (-2, 1), (-1, 2),
    ]
    private static let kingOffsets = [
        (-1, -1), (0, -1), (1, -1),
        (-1, 0), (1, 0),
        (-1, 1), (0, 1), (1, 1),
    ]
    private static let orthogonalDirections = [(1, 0), (-1, 0), (0, 1), (0, -1)]
    private static let diagonalDirections = [(1, 1), (1, -1), (-1, 1), (-1, -1)]

    private static func pseudoLegalMoves(in game: Game) -> [Game.Move] {
        var moves: [Game.Move] = []
        for square in Board.Square.allCases {
            guard let piece = game.board[square], piece.color == game.turn else { continue }
            switch piece.kind {
            case .pawn: addPawnMoves(from: square, piece: piece, game: game, to: &moves)
            case .knight: addStepMoves(
                from: square,
                piece: piece,
                offsets: knightOffsets,
                board: game.board,
                to: &moves
            )
            case .bishop: addSlidingMoves(
                from: square,
                piece: piece,
                directions: diagonalDirections,
                board: game.board,
                to: &moves
            )
            case .rook: addSlidingMoves(
                from: square,
                piece: piece,
                directions: orthogonalDirections,
                board: game.board,
                to: &moves
            )
            case .queen: addSlidingMoves(
                from: square,
                piece: piece,
                directions: orthogonalDirections + diagonalDirections,
                board: game.board,
                to: &moves
            )
            case .king:
                addStepMoves(
                    from: square,
                    piece: piece,
                    offsets: kingOffsets,
                    board: game.board,
                    to: &moves
                )
                addCastlingMoves(from: square, piece: piece, game: game, to: &moves)
            }
        }
        return moves
    }

    private static func addPawnMoves(
        from square: Board.Square,
        piece: Piece,
        game: Game,
        to moves: inout [Game.Move]
    ) {
        let direction = piece.color == .white ? 1 : -1
        let startingRank: Board.Rank = piece.color == .white ? .two : .seven
        let promotionRank: Board.Rank = piece.color == .white ? .eight : .one

        if let one = square.offset(file: 0, rank: direction), game.board[one] == nil {
            addPawnMove(from: square, to: one, piece: piece, captured: nil, promotionRank: promotionRank, moves: &moves)
            if square.rank == startingRank,
               let two = square.offset(file: 0, rank: direction * 2),
               game.board[two] == nil
            {
                moves.append(Game.Move(kind: .normal, piece: piece, from: square, to: two))
            }
        }

        for fileDelta in [-1, 1] {
            guard let target = square.offset(file: fileDelta, rank: direction) else { continue }
            if let captured = game.board[target],
               captured.color != piece.color,
               captured.kind != .king
            {
                addPawnMove(
                    from: square,
                    to: target,
                    piece: piece,
                    captured: captured,
                    promotionRank: promotionRank,
                    moves: &moves
                )
            } else if target == game.enPassantSquare,
                      let capturedSquare = target.offset(file: 0, rank: -direction),
                      let captured = game.board[capturedSquare],
                      captured == Piece(color: piece.color.opposite, kind: .pawn)
            {
                moves.append(Game.Move(
                    kind: .enPassant(captured: captured),
                    piece: piece,
                    from: square,
                    to: target
                ))
            }
        }
    }

    private static func addPawnMove(
        from: Board.Square,
        to: Board.Square,
        piece: Piece,
        captured: Piece?,
        promotionRank: Board.Rank,
        moves: inout [Game.Move]
    ) {
        if to.rank == promotionRank {
            for kind in [Piece.Kind.queen, .rook, .bishop, .knight] {
                moves.append(Game.Move(
                    kind: .promotion(
                        promotedTo: Piece(color: piece.color, kind: kind),
                        captured: captured
                    ),
                    piece: piece,
                    from: from,
                    to: to
                ))
            }
        } else {
            let kind: Game.Move.Kind = captured.map { .capture(captured: $0) } ?? .normal
            moves.append(Game.Move(kind: kind, piece: piece, from: from, to: to))
        }
    }

    private static func addStepMoves(
        from square: Board.Square,
        piece: Piece,
        offsets: [(Int, Int)],
        board: Board,
        to moves: inout [Game.Move]
    ) {
        for (file, rank) in offsets {
            guard let target = square.offset(file: file, rank: rank) else { continue }
            if let captured = board[target] {
                if captured.color != piece.color, captured.kind != .king {
                    moves.append(Game.Move(
                        kind: .capture(captured: captured),
                        piece: piece,
                        from: square,
                        to: target
                    ))
                }
            } else {
                moves.append(Game.Move(kind: .normal, piece: piece, from: square, to: target))
            }
        }
    }

    private static func addSlidingMoves(
        from square: Board.Square,
        piece: Piece,
        directions: [(Int, Int)],
        board: Board,
        to moves: inout [Game.Move]
    ) {
        for (file, rank) in directions {
            var distance = 1
            while let target = square.offset(file: file * distance, rank: rank * distance) {
                if let captured = board[target] {
                    if captured.color != piece.color, captured.kind != .king {
                        moves.append(Game.Move(
                            kind: .capture(captured: captured),
                            piece: piece,
                            from: square,
                            to: target
                        ))
                    }
                    break
                }
                moves.append(Game.Move(kind: .normal, piece: piece, from: square, to: target))
                distance += 1
            }
        }
    }

    private static func addCastlingMoves(
        from square: Board.Square,
        piece: Piece,
        game: Game,
        to moves: inout [Game.Move]
    ) {
        guard !isInCheck(piece.color, board: game.board) else { return }
        let rank: Board.Rank = piece.color == .white ? .one : .eight
        guard square == Board.Square(.e, rank) else { return }

        let kingRight: Board.CastlingRights = piece.color == .white ? .whiteKingside : .blackKingside
        if game.castlingRights.contains(kingRight),
           game.board[Board.Square(.h, rank)] == Piece(color: piece.color, kind: .rook),
           game.board[Board.Square(.f, rank)] == nil,
           game.board[Board.Square(.g, rank)] == nil,
           !isSquareAttacked(Board.Square(.f, rank), by: piece.color.opposite, board: game.board),
           !isSquareAttacked(Board.Square(.g, rank), by: piece.color.opposite, board: game.board)
        {
            moves.append(Game.Move(
                kind: .castle(side: .kingSide),
                piece: piece,
                from: square,
                to: Board.Square(.g, rank)
            ))
        }

        let queenRight: Board.CastlingRights = piece.color == .white ? .whiteQueenside : .blackQueenside
        if game.castlingRights.contains(queenRight),
           game.board[Board.Square(.a, rank)] == Piece(color: piece.color, kind: .rook),
           game.board[Board.Square(.b, rank)] == nil,
           game.board[Board.Square(.c, rank)] == nil,
           game.board[Board.Square(.d, rank)] == nil,
           !isSquareAttacked(Board.Square(.d, rank), by: piece.color.opposite, board: game.board),
           !isSquareAttacked(Board.Square(.c, rank), by: piece.color.opposite, board: game.board)
        {
            moves.append(Game.Move(
                kind: .castle(side: .queenSide),
                piece: piece,
                from: square,
                to: Board.Square(.c, rank)
            ))
        }
    }

    private static func attackedAlong(
        _ square: Board.Square,
        by attacker: Piece.Color,
        board: Board,
        directions: [(Int, Int)],
        kinds: Set<Piece.Kind>
    ) -> Bool {
        for (file, rank) in directions {
            var distance = 1
            while let source = square.offset(file: file * distance, rank: rank * distance) {
                if let piece = board[source] {
                    if piece.color == attacker && kinds.contains(piece.kind) { return true }
                    break
                }
                distance += 1
            }
        }
        return false
    }

    private static func applyingUnchecked(_ move: Game.Move, to game: Game) -> Game {
        var next = game
        next.board[move.from] = nil
        next.board[move.to] = move.piece

        switch move.kind {
        case .enPassant:
            let direction = move.piece.color == .white ? -1 : 1
            if let capturedSquare = move.to.offset(file: 0, rank: direction) {
                next.board[capturedSquare] = nil
            }
        case .castle(let side):
            let rank: Board.Rank = move.piece.color == .white ? .one : .eight
            let rookFrom = Board.Square(side == .kingSide ? .h : .a, rank)
            let rookTo = Board.Square(side == .kingSide ? .f : .d, rank)
            next.board[rookTo] = next.board[rookFrom]
            next.board[rookFrom] = nil
        case .promotion(let promoted, _):
            next.board[move.to] = promoted
        default:
            break
        }

        updateCastlingRights(for: move, in: &next)
        next.enPassantSquare = nil
        if move.piece.kind == .pawn,
           abs(move.to.rank.rawValue - move.from.rank.rawValue) == 2
        {
            next.enPassantSquare = move.from.offset(
                file: 0,
                rank: move.piece.color == .white ? 1 : -1
            )
        }
        next.halfmoveClock = move.piece.kind == .pawn || move.isCapture
            ? 0
            : game.halfmoveClock + 1
        if game.turn == .black { next.fullmoveNumber += 1 }
        next.turn = game.turn.opposite
        next.history.append(move)
        next.recordCurrentPosition()
        return next
    }

    private static func updateCastlingRights(for move: Game.Move, in game: inout Game) {
        if move.piece.kind == .king {
            if move.piece.color == .white {
                game.castlingRights.subtract([.whiteKingside, .whiteQueenside])
            } else {
                game.castlingRights.subtract([.blackKingside, .blackQueenside])
            }
        }
        switch move.from {
        case .a1: game.castlingRights.remove(.whiteQueenside)
        case .h1: game.castlingRights.remove(.whiteKingside)
        case .a8: game.castlingRights.remove(.blackQueenside)
        case .h8: game.castlingRights.remove(.blackKingside)
        default: break
        }
        switch move.to {
        case .a1: game.castlingRights.remove(.whiteQueenside)
        case .h1: game.castlingRights.remove(.whiteKingside)
        case .a8: game.castlingRights.remove(.blackQueenside)
        case .h8: game.castlingRights.remove(.blackKingside)
        default: break
        }
    }
}
