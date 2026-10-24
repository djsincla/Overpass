/// Runs async operations one at a time, in order.
///
/// Actors are re-entrant: while one command awaits its reply, another call on the same actor can
/// start and write its own command. Replies carry no command identifier, so they must never
/// overlap; every exchange with the mount goes through this.
actor SerialExecutor {
    private var tail: Task<Void, Never>?

    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task<T, Error> {
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}
