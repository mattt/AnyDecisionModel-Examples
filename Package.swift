// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AnyDecisionModelExamples",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "TicketRouting", targets: ["TicketRouting"]),
        .executable(name: "decision-eval", targets: ["decision-eval"]),
    ],
    dependencies: [
        .package(url: "https://github.com/mattt/AnyDecisionModel.git", exact: "0.6.0", traits: ["MLX"])
    ],
    targets: [
        .executableTarget(
            name: "TicketRouting",
            dependencies: [.product(name: "AnyDecisionModel", package: "AnyDecisionModel")]
        ),
        .target(
            name: "DecisionEvaluation",
            dependencies: [
                .product(name: "AnyDecisionModel", package: "AnyDecisionModel")
            ]
        ),
        .executableTarget(
            name: "decision-eval",
            dependencies: ["DecisionEvaluation"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "DecisionEvaluationTests",
            dependencies: ["DecisionEvaluation"]
        ),
    ]
)
