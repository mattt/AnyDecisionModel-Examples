import SwiftUI

/// An 8×8 board that supports mouse, keyboard, and VoiceOver selection.
///
/// The keyboard cursor is separate from the selected piece.
/// Arrow keys move the cursor in the displayed orientation,
/// Return or Space activates the square under the cursor,
/// and Escape clears the selection.
struct ChessboardView: View {
    let game: Game
    let bottomColor: Piece.Color
    let selection: MoveSelection
    let onActivate: (Board.Square) -> Void
    let onCancel: () -> Void

    @State private var cursor: Board.Square = .e2
    @State private var showsCursor = false
    @FocusState private var isFocused: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    private let labelSize: CGFloat = 20

    private var files: [Board.File] {
        bottomColor == .white ? Board.File.allCases : Board.File.allCases.reversed()
    }

    private var ranks: [Board.Rank] {
        bottomColor == .white ? Board.Rank.allCases.reversed() : Board.Rank.allCases
    }

    var body: some View {
        GeometryReader { proxy in
            let side = max(0, min(proxy.size.width, proxy.size.height) - labelSize)
            let squareSize = (side / 8).rounded(.down)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        ForEach(ranks, id: \.self) { rank in
                            Text(String(rank.rawValue))
                                .frame(width: labelSize, height: squareSize)
                                .accessibilityHidden(true)
                        }
                    }
                    squares(size: squareSize)
                }
                HStack(spacing: 0) {
                    Color.clear.frame(width: labelSize, height: labelSize)
                    ForEach(files, id: \.self) { file in
                        Text(file.rawValue)
                            .frame(width: squareSize, height: labelSize)
                            .accessibilityHidden(true)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func squares(size: CGFloat) -> some View {
        let palette = BoardPalette(contrast: contrast)
        let lastMove = game.history.last
        let checkedKing = game.checkedKingSquare
        let targets = selection.targets
        return VStack(spacing: 0) {
            ForEach(ranks, id: \.self) { rank in
                HStack(spacing: 0) {
                    ForEach(files, id: \.self) { file in
                        let square = Board.Square(file, rank)
                        let state = SquareState(
                            piece: game.board[square],
                            isSelected: selection.square == square,
                            isTarget: targets.contains(square),
                            isLastMove: lastMove.map { $0.from == square || $0.to == square } ?? false,
                            isCheckedKing: checkedKing == square,
                            hasCursor: showsCursor && isFocused && cursor == square
                        )
                        SquareView(square: square, state: state, palette: palette, size: size)
                            .onTapGesture {
                                cursor = square
                                showsCursor = false
                                isFocused = true
                                onActivate(square)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(state.accessibilityLabel(for: square))
                            .accessibilityValue(state.accessibilityValue)
                            .accessibilityAddTraits(state.isSelected ? [.isButton, .isSelected] : .isButton)
                            .accessibilityAction { onActivate(square) }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .focusable()
        .focused($isFocused)
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
            guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else {
                return .ignored
            }
            moveCursor(press.key)
            return .handled
        }
        .onKeyPress(keys: [.return, .space]) { press in
            guard press.modifiers.isEmpty else { return .ignored }
            showsCursor = true
            onActivate(cursor)
            return .handled
        }
        .onExitCommand(perform: onCancel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chessboard")
    }

    private func moveCursor(_ key: KeyEquivalent) {
        guard showsCursor else {
            showsCursor = true
            return
        }
        var column = files.firstIndex(of: cursor.file) ?? 0
        var row = ranks.firstIndex(of: cursor.rank) ?? 0
        switch key {
        case .upArrow: row -= 1
        case .downArrow: row += 1
        case .leftArrow: column -= 1
        case .rightArrow: column += 1
        default: break
        }
        column = min(max(column, 0), 7)
        row = min(max(row, 0), 7)
        cursor = Board.Square(files[column], ranks[row])
    }
}

private struct SquareState {
    var piece: Piece?
    var isSelected: Bool
    var isTarget: Bool
    var isLastMove: Bool
    var isCheckedKing: Bool
    var hasCursor: Bool

    func accessibilityLabel(for square: Board.Square) -> String {
        "\(square.notation), \(piece?.name ?? "empty")"
    }

    var accessibilityValue: String {
        var parts: [String] = []
        if isSelected { parts.append("selected") }
        if isTarget { parts.append(piece == nil ? "legal move" : "capture") }
        if isCheckedKing { parts.append("in check") }
        if isLastMove { parts.append("last move") }
        return parts.joined(separator: ", ")
    }
}

/// Board colors are separate from the interface colors
/// and do not change with the system appearance.
private struct BoardPalette {
    var light: Color
    var dark: Color
    var lastMove: Color
    var lastMoveOutline: Color
    var marker: Color
    var selection: Color
    var check: Color

    init(contrast: ColorSchemeContrast) {
        let increased = contrast == .increased
        light = increased
            ? Color(red: 0.97, green: 0.92, blue: 0.83)
            : Color(red: 0.93, green: 0.85, blue: 0.72)
        dark = increased
            ? Color(red: 0.50, green: 0.33, blue: 0.21)
            : Color(red: 0.69, green: 0.52, blue: 0.38)
        lastMove = Color(red: 0.96, green: 0.80, blue: 0.18).opacity(increased ? 0.6 : 0.45)
        lastMoveOutline = Color(red: 0.58, green: 0.43, blue: 0.0)
        marker = Color(red: 0.10, green: 0.30, blue: 0.17).opacity(increased ? 0.9 : 0.6)
        selection = Color(red: 0.05, green: 0.29, blue: 0.62)
        check = Color(red: 0.86, green: 0.10, blue: 0.10)
    }
}

private struct SquareView: View {
    let square: Board.Square
    let state: SquareState
    let palette: BoardPalette
    let size: CGFloat

    var body: some View {
        ZStack {
            Rectangle().fill(square.color == .light ? palette.light : palette.dark)
            if state.isLastMove {
                Rectangle().fill(palette.lastMove)
                Rectangle()
                    .strokeBorder(palette.lastMoveOutline, style: StrokeStyle(
                        lineWidth: max(2, size * 0.04),
                        dash: [size * 0.12, size * 0.08]
                    ))
            }
            if state.isCheckedKing {
                RadialGradient(
                    colors: [palette.check.opacity(0.9), palette.check.opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: size * 0.6
                )
                Circle()
                    .strokeBorder(palette.check, lineWidth: max(2, size * 0.06))
                    .padding(size * 0.04)
            }
            if state.isTarget, state.piece == nil {
                Circle()
                    .fill(palette.marker)
                    .frame(width: size * 0.3, height: size * 0.3)
            }
            if let piece = state.piece {
                PieceView(piece: piece, size: size)
            }
            if state.isTarget, state.piece != nil {
                CaptureCorners()
                    .fill(palette.marker)
            }
            if state.isSelected {
                Rectangle()
                    .strokeBorder(palette.selection, lineWidth: max(3, size * 0.07))
                Rectangle()
                    .strokeBorder(.white.opacity(0.9), lineWidth: 1)
                    .padding(max(3, size * 0.07))
            }
            if state.hasCursor {
                RoundedRectangle(cornerRadius: size * 0.08)
                    .strokeBorder(
                        Color(nsColor: .keyboardFocusIndicatorColor),
                        style: StrokeStyle(lineWidth: max(2, size * 0.05), dash: [size * 0.1, size * 0.06])
                    )
                    .padding(size * 0.12)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
    }
}

private struct PieceView: View {
    let piece: Piece
    let size: CGFloat

    var body: some View {
        Text(piece.solidGlyph)
            .foregroundStyle(piece.color == .white ? Color.white : Color.black)
            .font(.system(size: size * 0.8))
            .shadow(
                color: piece.color == .white ? .black.opacity(0.7) : .clear,
                radius: size * 0.03,
                y: size * 0.01
            )
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Triangles in the four corners of a square that marks a capture
/// without covering the captured piece.
private struct CaptureCorners: Shape {
    func path(in rect: CGRect) -> Path {
        let length = rect.width * 0.28
        var path = Path()
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: rect.minX, y: rect.minY), 1, 1),
            (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
            (CGPoint(x: rect.minX, y: rect.maxY), 1, -1),
            (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1),
        ]
        for (corner, dx, dy) in corners {
            path.move(to: corner)
            path.addLine(to: CGPoint(x: corner.x + dx * length, y: corner.y))
            path.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * length))
            path.closeSubpath()
        }
        return path
    }
}

private extension Piece {
    var solidGlyph: String {
        let glyph = switch kind {
        case .pawn: "♟"
        case .rook: "♜"
        case .knight: "♞"
        case .bishop: "♝"
        case .queen: "♛"
        case .king: "♚"
        }
        return glyph + "\u{FE0E}"
    }
}
