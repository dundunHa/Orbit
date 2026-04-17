import Testing
@testable import Orbit

@Suite("TokenFormatting Tests")
struct TokenFormattingTests {
    @Test("formatTokens formats small values")
    func testFormatTokensSmallValues() {
        #expect(TokenFormatting.formatTokens(0) == "0")
        #expect(TokenFormatting.formatTokens(999) == "999")
    }
    
    @Test("formatTokens formats thousands")
    func testFormatTokensThousands() {
        #expect(TokenFormatting.formatTokens(1_000) == "1.0K")
        #expect(TokenFormatting.formatTokens(1_500) == "1.5K")
        #expect(TokenFormatting.formatTokens(999_999) == "1000.0K")
    }
    
    @Test("formatTokens formats millions")
    func testFormatTokensMillions() {
        #expect(TokenFormatting.formatTokens(1_000_000) == "1.0M")
        #expect(TokenFormatting.formatTokens(1_500_000) == "1.5M")
    }
    
    @Test("tokenStatsText omits rate when empty")
    func testTokenStatsTextWithoutRate() {
        #expect(TokenFormatting.tokenStatsText(tokensIn: 0, tokensOut: 0, outRate: 0) == "today: ↓0 ↑0")
    }
    
    @Test("tokenStatsText shows rate when available")
    func testTokenStatsTextWithRate() {
        #expect(TokenFormatting.tokenStatsText(tokensIn: 1_200, tokensOut: 2_500, outRate: 12.3) == "today: ↓1.2K ↑2.5K (12.3 tok/s)")
    }
}
