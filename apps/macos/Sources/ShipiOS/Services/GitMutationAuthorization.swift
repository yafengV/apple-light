/// Rechecked after asynchronous preflight, immediately before a repository write.
typealias GitMutationAuthorization = @MainActor @Sendable () throws -> Void
