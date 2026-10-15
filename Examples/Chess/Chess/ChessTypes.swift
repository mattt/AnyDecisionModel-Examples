enum Piece: String, CaseIterable, Hashable, Sendable {
    enum Color: String, CaseIterable, Hashable, Sendable {
        case black
        case white

        var opposite: Color { self == .black ? .white : .black }
    }

    enum Kind: String, CaseIterable, Hashable, Sendable {
        case pawn
        case rook
        case knight
        case bishop
        case queen
        case king
    }

    case blackPawn, blackRook, blackKnight, blackBishop, blackQueen, blackKing
    case whitePawn, whiteRook, whiteKnight, whiteBishop, whiteQueen, whiteKing

    init(color: Color, kind: Kind) {
        switch (color, kind) {
        case (.black, .pawn): self = .blackPawn
        case (.black, .rook): self = .blackRook
        case (.black, .knight): self = .blackKnight
        case (.black, .bishop): self = .blackBishop
        case (.black, .queen): self = .blackQueen
        case (.black, .king): self = .blackKing
        case (.white, .pawn): self = .whitePawn
        case (.white, .rook): self = .whiteRook
        case (.white, .knight): self = .whiteKnight
        case (.white, .bishop): self = .whiteBishop
        case (.white, .queen): self = .whiteQueen
        case (.white, .king): self = .whiteKing
        }
    }

    var color: Color {
        rawValue.hasPrefix("white") ? .white : .black
    }

    var kind: Kind {
        switch self {
        case .blackPawn, .whitePawn: .pawn
        case .blackRook, .whiteRook: .rook
        case .blackKnight, .whiteKnight: .knight
        case .blackBishop, .whiteBishop: .bishop
        case .blackQueen, .whiteQueen: .queen
        case .blackKing, .whiteKing: .king
        }
    }

    var graphic: String {
        switch self {
        case .blackPawn: "♟\u{FE0E}"
        case .blackRook: "♜"
        case .blackKnight: "♞"
        case .blackBishop: "♝"
        case .blackQueen: "♛"
        case .blackKing: "♚"
        case .whitePawn: "♙"
        case .whiteRook: "♖"
        case .whiteKnight: "♘"
        case .whiteBishop: "♗"
        case .whiteQueen: "♕"
        case .whiteKing: "♔"
        }
    }

    var fenCharacter: Character {
        let letter: Character = switch kind {
        case .pawn: "p"
        case .rook: "r"
        case .knight: "n"
        case .bishop: "b"
        case .queen: "q"
        case .king: "k"
        }
        return color == .white ? Character(String(letter).uppercased()) : letter
    }

    var sanLetter: String {
        switch kind {
        case .pawn: ""
        case .rook: "R"
        case .knight: "N"
        case .bishop: "B"
        case .queen: "Q"
        case .king: "K"
        }
    }
}

struct Board: Hashable, Sendable {
    enum Rank: Int, CaseIterable, Comparable, Hashable, Sendable {
        case one = 1, two, three, four, five, six, seven, eight

        static func < (lhs: Rank, rhs: Rank) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    enum File: String, CaseIterable, Comparable, Hashable, Sendable {
        case a, b, c, d, e, f, g, h

        var index: Int { Self.allCases.firstIndex(of: self)! }

        init?(index: Int) {
            guard Self.allCases.indices.contains(index) else { return nil }
            self = Self.allCases[index]
        }

        func offset(by delta: Int) -> File? {
            File(index: index + delta)
        }

        static func < (lhs: File, rhs: File) -> Bool {
            lhs.index < rhs.index
        }
    }

    enum Square: UInt8, CaseIterable, Comparable, Hashable, Sendable {
        case a1, b1, c1, d1, e1, f1, g1, h1
        case a2, b2, c2, d2, e2, f2, g2, h2
        case a3, b3, c3, d3, e3, f3, g3, h3
        case a4, b4, c4, d4, e4, f4, g4, h4
        case a5, b5, c5, d5, e5, f5, g5, h5
        case a6, b6, c6, d6, e6, f6, g6, h6
        case a7, b7, c7, d7, e7, f7, g7, h7
        case a8, b8, c8, d8, e8, f8, g8, h8

        init(_ file: File, _ rank: Rank) {
            self.init(rawValue: UInt8((rank.rawValue - 1) * 8 + file.index))!
        }

        init?(notation: String) {
            guard notation.count == 2,
                  let file = File(rawValue: String(notation.first!)),
                  let rankValue = Int(String(notation.last!)),
                  let rank = Rank(rawValue: rankValue)
            else { return nil }
            self.init(file, rank)
        }

        var file: File { File(index: Int(rawValue) % 8)! }
        var rank: Rank { Rank(rawValue: Int(rawValue) / 8 + 1)! }
        var notation: String { file.rawValue + String(rank.rawValue) }

        enum Color: Hashable, Sendable { case dark, light }

        var color: Color {
            (file.index + rank.rawValue).isMultiple(of: 2) ? .light : .dark
        }

        func offset(file: Int, rank: Int) -> Square? {
            guard let newFile = self.file.offset(by: file),
                  let newRank = Rank(rawValue: self.rank.rawValue + rank)
            else { return nil }
            return Square(newFile, newRank)
        }

        static func < (lhs: Square, rhs: Square) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    struct CastlingRights: OptionSet, Hashable, Sendable {
        let rawValue: UInt8
        static let whiteKingside = Self(rawValue: 1 << 0)
        static let whiteQueenside = Self(rawValue: 1 << 1)
        static let blackKingside = Self(rawValue: 1 << 2)
        static let blackQueenside = Self(rawValue: 1 << 3)
        static let all: Self = [
            .whiteKingside, .whiteQueenside, .blackKingside, .blackQueenside,
        ]

        init(rawValue: UInt8) { self.rawValue = rawValue }
    }

    private var storage: [Piece?]

    init() {
        storage = Array(repeating: nil, count: 64)
    }

    subscript(square: Square) -> Piece? {
        get { storage[Int(square.rawValue)] }
        set { storage[Int(square.rawValue)] = newValue }
    }

    var pieces: [Square: Piece] {
        Dictionary(uniqueKeysWithValues: Square.allCases.compactMap { square in
            self[square].map { (square, $0) }
        })
    }

    static func startingPosition() -> Board {
        var board = Board()
        let order: [Piece.Kind] = [.rook, .knight, .bishop, .queen, .king, .bishop, .knight, .rook]
        for (index, file) in File.allCases.enumerated() {
            board[Square(file, .one)] = Piece(color: .white, kind: order[index])
            board[Square(file, .two)] = .whitePawn
            board[Square(file, .seven)] = .blackPawn
            board[Square(file, .eight)] = Piece(color: .black, kind: order[index])
        }
        return board
    }
}

struct Game: Hashable, Sendable {
    struct Move: Hashable, Sendable {
        enum CastleSide: String, Hashable, Sendable {
            case kingSide = "O-O"
            case queenSide = "O-O-O"
        }

        enum Kind: Hashable, Sendable {
            case normal
            case capture(captured: Piece)
            case enPassant(captured: Piece)
            case castle(side: CastleSide)
            case promotion(promotedTo: Piece, captured: Piece?)
        }

        let kind: Kind
        let piece: Piece
        let from: Board.Square
        let to: Board.Square

        init(kind: Kind, piece: Piece, from: Board.Square, to: Board.Square) {
            self.kind = kind
            self.piece = piece
            self.from = from
            self.to = to
        }

        var promotionKind: Piece.Kind? {
            guard case .promotion(let piece, _) = kind else { return nil }
            return piece.kind
        }

        var capturedPiece: Piece? {
            switch kind {
            case .capture(let piece), .enPassant(let piece): piece
            case .promotion(_, let piece): piece
            default: nil
            }
        }

        var isCapture: Bool { capturedPiece != nil }

        var uci: String {
            let suffix: String = switch promotionKind {
            case .queen: "q"
            case .rook: "r"
            case .bishop: "b"
            case .knight: "n"
            default: ""
            }
            return from.notation + to.notation + suffix
        }
    }

    enum Outcome: Hashable, Sendable {
        case inProgress
        case checkmate(winner: Piece.Color)
        case stalemate
        case drawByRepetition
        case drawByFiftyMoveRule
        case drawByInsufficientMaterial

        var isTerminal: Bool { self != .inProgress }
    }

    var board: Board
    var turn: Piece.Color
    var castlingRights: Board.CastlingRights
    var enPassantSquare: Board.Square?
    var halfmoveClock: Int
    var fullmoveNumber: Int
    var history: [Move]
    private(set) var repetitionCounts: [String: Int]

    init() {
        board = .startingPosition()
        turn = .white
        castlingRights = .all
        enPassantSquare = nil
        halfmoveClock = 0
        fullmoveNumber = 1
        history = []
        repetitionCounts = [:]
        repetitionCounts[positionKey] = 1
    }

    init(
        board: Board,
        turn: Piece.Color,
        castlingRights: Board.CastlingRights = [],
        enPassantSquare: Board.Square? = nil,
        halfmoveClock: Int = 0,
        fullmoveNumber: Int = 1,
        history: [Move] = []
    ) {
        self.board = board
        self.turn = turn
        self.castlingRights = castlingRights
        self.enPassantSquare = enPassantSquare
        self.halfmoveClock = halfmoveClock
        self.fullmoveNumber = fullmoveNumber
        self.history = history
        repetitionCounts = [:]
        repetitionCounts[positionKey] = 1
    }

    mutating func recordCurrentPosition() {
        repetitionCounts[positionKey, default: 0] += 1
    }

    var currentRepetitionCount: Int { repetitionCounts[positionKey, default: 0] }

    var positionKey: String {
        let fields = fen.split(separator: " ")
        return fields.prefix(4).joined(separator: " ")
    }
}

typealias GameSnapshot = Game
