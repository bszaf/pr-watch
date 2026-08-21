import Testing
@testable import PRWatch

@Suite struct GitHubClientTests {
    // A stale PR whose phase-B fetch failed must keep its OLD cache stamp so the
    // threads are retried next poll — stamping the new updatedAt would freeze the
    // cached review info until the PR happens to change again.
    @Test func failedFreshFetchKeepsOldCacheStamp() {
        #expect(GitHubClient.cacheStamp(nodeUpdatedAt: "T2", wasStale: true, gotFresh: false, previous: "T1") == "T1")
        // Never-fetched PR stays unstamped → retried.
        #expect(GitHubClient.cacheStamp(nodeUpdatedAt: "T2", wasStale: true, gotFresh: false, previous: nil) == nil)
    }

    @Test func successfulOrUnchangedFetchStampsCurrent() {
        #expect(GitHubClient.cacheStamp(nodeUpdatedAt: "T2", wasStale: true, gotFresh: true, previous: "T1") == "T2")
        #expect(GitHubClient.cacheStamp(nodeUpdatedAt: "T2", wasStale: false, gotFresh: false, previous: "T2") == "T2")
    }

    // Queries are built by interpolation; a quote/backslash in a settings value must be
    // dropped rather than break the whole GraphQL query.
    @Test func unsafeQueryValuesAreDropped() {
        #expect(GitHubClient.safeName("Acme/app") == "Acme/app")
        #expect(GitHubClient.safeName("owner/repo.name-x_1") == "owner/repo.name-x_1")
        #expect(GitHubClient.safeName("bad\"quote") == nil)
        #expect(GitHubClient.safeName("back\\slash") == nil)
        #expect(GitHubClient.safeName("") == nil)
    }
}
