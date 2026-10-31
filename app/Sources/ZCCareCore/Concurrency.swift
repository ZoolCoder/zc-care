/// Runs work on every item, at most `limit` at once, and hands each output
/// to `each` as it arrives, in the caller's isolation. A program per item,
/// such as spctl for each app, would otherwise all start together.
public func forEachConcurrently<Item: Sendable, Output: Sendable>(
    _ items: [Item], limit: Int = 8, isolation: isolated (any Actor)? = #isolation,
    work: @escaping @Sendable (Item) async -> Output, each: (Output) -> Void
) async {
    await withTaskGroup(of: Output.self) { group in
        // A closure runs on an isolated parameter's actor only if it captures it.
        _ = isolation
        var rest = items[...]
        func startNext() {
            guard let item = rest.popFirst() else { return }
            group.addTask { await work(item) }
        }
        for _ in 0..<max(limit, 1) { startNext() }
        for await output in group {
            each(output)
            startNext()
        }
    }
}
