import AnyDecisionModel
import Foundation

// Routes support tickets with typed decisions.
//
// Usage:
//   TicketRouting [--model <hugging-face-id>] [--threshold <0...1>] [--jev]
//
// The default backend is MLX with Qwen3 4B.
// Pass --jev to use the Jev API with TYPESAFE_AI_API_KEY.
// Tickets whose routing confidence is below the threshold go to a person.
// The example never sends a ticket to a cloud model on its own.

enum Department: String, Choosable {
    case billing, technical, sales

    var optionDescription: String? {
        switch self {
        case .billing: "payments, charges, refunds, invoices"
        case .technical: "bugs, outages, errors, login problems"
        case .sales: "pricing questions, upgrades, new purchases"
        }
    }
}

let tickets = [
    "I was charged twice this month and nobody has answered my emails in a week. Fix this NOW.",
    "The app logs me out every time I switch tabs. Using Safari 19 on macOS.",
    "We are a team of 40. Is there a discount if we move to the annual plan?",
    "Hi, I have a question.",
]

var arguments = CommandLine.arguments.dropFirst()
var modelID = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
var threshold = 0.5
var useJev = false
while let argument = arguments.popFirst() {
    switch argument {
    case "--model": modelID = arguments.popFirst() ?? modelID
    case "--threshold": threshold = arguments.popFirst().flatMap(Double.init) ?? threshold
    case "--jev": useJev = true
    default:
        FileHandle.standardError.write(Data("Unknown argument: \(argument)\n".utf8))
        exit(2)
    }
}

let model: any DecisionModel = useJev ? JevDecisionModel() : MLXDecisionModel(modelID: modelID)
print("Model: \(model.modelID)")
print("Routing threshold: \(threshold) (confidence measures concentration, not correctness)\n")

for ticket in tickets {
    let session = DecisionSession(model: model, state: .text(ticket))
    let started = ContinuousClock.now

    let team = try await session.choice("Which team should handle this support ticket?", from: Department.self)
    let urgent = try await session.probability(of: "Does this ticket convey urgency?")
    let anger = try await session.score(
        "How frustrated is the customer?",
        levels: ["Calm", "Frustrated", "Very angry"]
    )

    let elapsed = ContinuousClock.now - started
    let route = team.confidence >= threshold ? team.value.rawValue : "human review"
    let distribution = team.distribution
        .map { "\($0.option.rawValue) \(String(format: "%.2f", $0.probability))" }
        .joined(separator: ", ")

    print("Ticket: \(ticket)")
    print("  team:    \(team.value.rawValue) [\(distribution)], confidence \(String(format: "%.2f", team.confidence))")
    print("  route:   \(route)")
    print("  urgent:  \(String(format: "%.3f", urgent))")
    print("  anger:   \(String(format: "%.2f", anger.value)) of 0 to 2 (\(anger.levels[anger.mostLikelyLevelIndex]))")
    print("  time:    \(elapsed.formatted(.units(allowed: [.milliseconds])))\n")
}
