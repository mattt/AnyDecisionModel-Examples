import Testing

@testable import decision_eval

@Test(arguments: [
    ([], defaultModelID),
    (["--model", "example/remote"], "example/remote"),
    (["--model-directory", "./fixtures/local-model"], "./fixtures/local-model"),
    (["--model", "example/remote", "--model-directory", "./fixtures/local-model"], "example/remote"),
])
func reportModel(arguments: [String], expected: String) throws {
    let options = try Options(["sanity"] + arguments)
    #expect(options.reportModel == expected)
}
