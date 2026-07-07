import Testing
@testable import PRWatch

@Suite struct PRParsingTests {
    @Test func parsesOwnerRepoHashNumber() {
        let p = GitHubClient.parsePR("RiverFinancial/alto#13290")
        #expect(p?.owner == "RiverFinancial")
        #expect(p?.repo == "alto")
        #expect(p?.number == 13290)
    }

    @Test func parsesFullURL() {
        let p = GitHubClient.parsePR("https://github.com/RiverFinancial/alto/pull/42")
        #expect(p?.owner == "RiverFinancial")
        #expect(p?.repo == "alto")
        #expect(p?.number == 42)
    }

    @Test func normalizesURLToCanonicalForm() {
        #expect(GitHubClient.normalizePR("https://github.com/o/r/pull/7") == "o/r#7")
        #expect(GitHubClient.normalizePR("  o/r#7  ") == "o/r#7")
    }

    @Test func rejectsGarbage() {
        #expect(GitHubClient.parsePR("not a pr") == nil)
        #expect(GitHubClient.parsePR("owner/repo") == nil)      // no number
        #expect(GitHubClient.parsePR("owner#5") == nil)         // no repo
        #expect(GitHubClient.normalizePR("") == nil)
    }
}
