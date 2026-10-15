import SwiftUI

/// The trailing inspector with the move history and the last model result.
struct InspectorView: View {
    let controller: ChessGameController

    var body: some View {
        VSplitView {
            MoveHistoryView(
                rows: MoveHistoryRow.rows(
                    from: controller.moveNotations,
                    startingTurn: controller.startingGame.turn,
                    startingFullmove: controller.startingGame.fullmoveNumber
                ),
                latestIndex: controller.moveNotations.indices.last
            )
            .frame(minHeight: 140, idealHeight: 260)

            ModelResultView(summary: controller.lastDecisionSummary)
                .frame(minHeight: 180)
        }
    }
}

private struct MoveHistoryView: View {
    let rows: [MoveHistoryRow]
    let latestIndex: Int?

    @State private var visibleRows: Set<Int> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Moves")
                .font(.headline)
                .padding([.horizontal, .top])
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 0) {
                Text("#").frame(width: 40, alignment: .trailing)
                Text("White").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 12)
                Text("Black").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 6)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.bottom, 4)
            .accessibilityHidden(true)
            Divider()

            if rows.isEmpty {
                Text("No moves yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { row in
                                MoveHistoryRowView(row: row, latestIndex: latestIndex)
                                    .id(row.number)
                                    .onAppear { visibleRows.insert(row.number) }
                                    .onDisappear { visibleRows.remove(row.number) }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onAppear { proxy.scrollTo(rows.last?.number, anchor: .bottom) }
                    .onChange(of: rows) { oldRows, newRows in
                        // Follow new moves only when the previous last row was visible,
                        // so that a person who scrolled back keeps their place.
                        guard let target = newRows.last?.number,
                              let previous = oldRows.last?.number,
                              visibleRows.contains(previous)
                        else { return }
                        if reduceMotion {
                            proxy.scrollTo(target, anchor: .bottom)
                        } else {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(target, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct MoveHistoryRowView: View {
    let row: MoveHistoryRow
    let latestIndex: Int?

    var body: some View {
        HStack(spacing: 6) {
            Text("\(row.number).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
            cell(row.white, isLatest: row.whiteIndex != nil && row.whiteIndex == latestIndex)
            cell(row.black, isLatest: row.blackIndex != nil && row.blackIndex == latestIndex)
        }
        .padding(.horizontal)
        .padding(.vertical, 2)
        .background(
            row.number.isMultiple(of: 2)
                ? Color(nsColor: NSColor.alternatingContentBackgroundColors[1])
                : Color.clear
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private func cell(_ notation: String?, isLatest: Bool) -> some View {
        Text(notation ?? "")
            .fontWeight(isLatest ? .semibold : .regular)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                if isLatest {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentColor.opacity(0.18))
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.accentColor, lineWidth: 1)
                }
            }
    }

    private var accessibilityLabel: String {
        var parts = ["Move \(row.number)"]
        if let white = row.white {
            parts.append("White \(white)")
        }
        if let black = row.black {
            parts.append("Black \(black)")
        }
        if let latestIndex, row.whiteIndex == latestIndex || row.blackIndex == latestIndex {
            parts.append("latest move")
        }
        return parts.joined(separator: ", ")
    }
}

private struct ModelResultView: View {
    let summary: DecisionSummary?

    @State private var expandedGroups: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Model")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                if let summary {
                    assessment(summary)
                    Divider()
                    choices(summary)
                } else {
                    Text("The model has not moved in this game.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .onChange(of: summary, initial: true) { _, summary in
            expandedGroups = Set(summary?.groups.last.map { [$0.id] } ?? [])
        }
    }

    @ViewBuilder
    private func assessment(_ summary: DecisionSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Position assessment")
                .font(.subheadline.weight(.semibold))
            Text("Describes the position before \(summary.mover.name) played \(summary.moveNotation).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent("Selected move", value: summary.moveNotation)
            LabeledContent("Time") {
                Text(summary.elapsed.formatted(.units(
                    allowed: [.seconds],
                    width: .abbreviated,
                    fractionalPart: .show(length: 2)
                )))
                .monospacedDigit()
            }
            ForEach(Array(PositionAssessment.levels.enumerated()), id: \.offset) { index, level in
                ProbabilityBar(
                    label: level,
                    probability: summary.levelProbabilities[safe: index] ?? 0,
                    isEmphasized: level == summary.mostLikelyLevel,
                    isSelection: false
                )
            }
            DisclosureGroup("Details") {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Expected level") {
                        Text("\(summary.expectedLevel, format: .number.precision(.fractionLength(2))) of 4")
                            .monospacedDigit()
                    }
                    Text("0 is a clear Black advantage and 4 is a clear White advantage.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("FEN")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(summary.assessedFEN)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func choices(_ summary: DecisionSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Move choices")
                .font(.subheadline.weight(.semibold))
            if summary.groups.isEmpty {
                Text("The position had one legal move, so the model did not choose.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("""
                    Each group is a separate question. \
                    Compare probabilities only within a group; \
                    probabilities from different groups do not form one distribution.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(summary.groups) { group in
                    DisclosureGroup(isExpanded: expansion(for: group.id)) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(group.options) { option in
                                ProbabilityBar(
                                    label: option.notation,
                                    probability: option.probability,
                                    isEmphasized: option.isSelected,
                                    isSelection: true
                                )
                            }
                        }
                        .padding(.top, 4)
                    } label: {
                        HStack {
                            Text("Round \(group.round), group \(group.group)")
                            Spacer()
                            Text("Chose \(group.selectedNotation)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func expansion(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedGroups.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    expandedGroups.insert(id)
                } else {
                    expandedGroups.remove(id)
                }
            }
        )
    }
}

private struct ProbabilityBar: View {
    let label: String
    let probability: Double
    let isEmphasized: Bool
    /// Marks the emphasized row as the selected option with a checkmark.
    let isSelection: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if isSelection {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .opacity(isEmphasized ? 1 : 0)
                }
                Text(label)
                    .fontWeight(isEmphasized ? .semibold : .regular)
                Spacer()
                Text(probability, format: .percent.precision(.fractionLength(1)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.25))
                    Capsule()
                        .fill(isEmphasized ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .frame(width: proxy.size.width * min(max(probability, 0), 1))
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        let percent = probability.formatted(.percent.precision(.fractionLength(1)))
        guard isEmphasized else { return percent }
        return "\(percent), \(isSelection ? "selected" : "most likely")"
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
