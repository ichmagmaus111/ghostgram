import Foundation
import XCTest

// Host tests of the outgoing text pipeline core (compiled together with Sources/Pipeline/Core).
// Run: ./build-input/bazel-9.2.0-darwin-arm64 test //Ghostgram/Features/Messages:GGMessagesTests

final class GGTextPipelineTests: XCTestCase {
    private let plain = GGTextPipelineContext(isBot: false, isSavedMessages: false, isVerbatim: false)

    private func entity(_ range: Range<Int>, protected: Bool = false, overlay: Bool = false, tag: Int = 0) -> GGPipelineEntity {
        return GGPipelineEntity(range: range, isProtected: protected, excludesOverlay: overlay, tag: tag)
    }

    private func utf16Range(of needle: String, in text: String) -> Range<Int> {
        let range = (text as NSString).range(of: needle)
        return range.location ..< (range.location + range.length)
    }

    // MARK: Order

    func testOrderIsFixed() {
        XCTAssertEqual(GGTextPipeline.order, [.wordReplacement, .antiCaps, .hyperlink])
        let configuration = GGTextPipelineConfiguration(replacementRules: [GGTextReplacementRule(source: "a", replacement: "b")], antiCaps: true, hyperlink: true)
        XCTAssertEqual(GGTextPipeline.enabledStages(configuration: configuration, context: self.plain, text: "text"), GGTextPipeline.order)
    }

    func testOrderIsDeterministic() {
        let configuration = GGTextPipelineConfiguration(replacementRules: [GGTextReplacementRule(source: "ПРИВЕТ", replacement: "ЗДРАВСТВУЙТЕ")], antiCaps: true, hyperlink: false)
        let input = GGPipelineText(text: "ПРИВЕТ ДРУЗЬЯ КАК ДЕЛА", entities: [])
        let first = GGTextPipeline.run(input, configuration: configuration, context: self.plain)
        for _ in 0 ..< 5 {
            XCTAssertEqual(GGTextPipeline.run(input, configuration: configuration, context: self.plain), first)
        }
        // Replacement first (sees the typed caps), then anti-caps.
        XCTAssertEqual(first.text, "Здравствуйте друзья как дела")
    }

    func testBotsAndCopiesAreNeverTransformed() {
        let configuration = GGTextPipelineConfiguration(antiCaps: true, hyperlink: true)
        let input = GGPipelineText(text: "ПРИВЕТ БОТ", entities: [])
        XCTAssertEqual(GGTextPipeline.run(input, configuration: configuration, context: GGTextPipelineContext(isBot: true, isSavedMessages: false, isVerbatim: false)), input)
        XCTAssertEqual(GGTextPipeline.run(input, configuration: configuration, context: GGTextPipelineContext(isBot: false, isSavedMessages: false, isVerbatim: true)), input)
    }

    func testCommandsSkipTheCaseAndOverlayStages() {
        let configuration = GGTextPipelineConfiguration(antiCaps: true, hyperlink: true)
        XCTAssertEqual(GGTextPipeline.enabledStages(configuration: configuration, context: self.plain, text: "/START NOW"), [])
    }

    func testSavedMessagesGetNoMentionOverlay() {
        let configuration = GGTextPipelineConfiguration(antiCaps: true, hyperlink: true)
        let savedMessages = GGTextPipelineContext(isBot: false, isSavedMessages: true, isVerbatim: false)
        XCTAssertEqual(GGTextPipeline.enabledStages(configuration: configuration, context: savedMessages, text: "ПРИВЕТ ВСЕМ"), [.antiCaps])
    }

    // MARK: Entities survive

    func testEntityMovesWithReplacement() {
        let text = "да давай завтра"
        let bold = self.entity(self.utf16Range(of: "завтра", in: text), tag: 1)
        let input = GGPipelineText(text: text, entities: [bold])
        let rules = [GGTextReplacementRule(source: "да", replacement: "нет")]
        let output = GGTextPipeline.run(input, configuration: GGTextPipelineConfiguration(replacementRules: rules), context: self.plain)
        XCTAssertEqual(output.text, "нет давай завтра")
        XCTAssertEqual(output.entities.count, 1)
        XCTAssertEqual(output.substring(output.entities[0].range), "завтра")
        XCTAssertEqual(output.entities[0].tag, 1)
    }

    func testEntityCoveringChangedWordGrowsWithIt() {
        let text = "Привет мир"
        let italic = self.entity(self.utf16Range(of: "Привет", in: text), tag: 2)
        let input = GGPipelineText(text: text, entities: [italic])
        let rules = [GGTextReplacementRule(source: "привет", replacement: "здравствуйте")]
        let output = GGTextPipeline.run(input, configuration: GGTextPipelineConfiguration(replacementRules: rules), context: self.plain)
        XCTAssertEqual(output.text, "Здравствуйте мир")
        XCTAssertEqual(output.substring(output.entities[0].range), "Здравствуйте")
    }

    func testCustomEmojiIsNeverTouched() {
        let text = "ОЧЕНЬ ХОРОШО 😀 ДА"
        let emoji = self.entity(self.utf16Range(of: "😀", in: text), protected: true, tag: 3)
        let input = GGPipelineText(text: text, entities: [emoji])
        let output = GGTextPipeline.run(input, configuration: GGTextPipelineConfiguration(antiCaps: true), context: self.plain)
        XCTAssertEqual(output.entities.count, 1)
        XCTAssertEqual(output.substring(output.entities[0].range), "😀")
    }

    // MARK: Word replacement

    func testWholeWordOnly() {
        let rules = [GGTextReplacementRule(source: "да", replacement: "нет")]
        let output = GGTextPipeline.run(GGPipelineText(text: "давай да", entities: []), configuration: GGTextPipelineConfiguration(replacementRules: rules), context: self.plain)
        XCTAssertEqual(output.text, "давай нет")
    }

    func testRulesDoNotChain() {
        let rules = [GGTextReplacementRule(source: "a", replacement: "b"), GGTextReplacementRule(source: "b", replacement: "c")]
        let output = GGTextPipeline.run(GGPipelineText(text: "a b", entities: []), configuration: GGTextPipelineConfiguration(replacementRules: rules), context: self.plain)
        XCTAssertEqual(output.text, "b c")
    }

    func testReplacementKeepsCase() {
        let rules = [GGTextReplacementRule(source: "привет", replacement: "здравствуй")]
        let output = GGTextPipeline.run(GGPipelineText(text: "Привет и ПРИВЕТ", entities: []), configuration: GGTextPipelineConfiguration(replacementRules: rules), context: self.plain)
        XCTAssertEqual(output.text, "Здравствуй и ЗДРАВСТВУЙ")
    }

    func testReplacementSkipsLinks() {
        let rules = [GGTextReplacementRule(source: "example", replacement: "x")]
        let output = GGTextPipeline.run(GGPipelineText(text: "see example.com example", entities: []), configuration: GGTextPipelineConfiguration(replacementRules: rules), context: self.plain)
        XCTAssertEqual(output.text, "see example.com x")
    }

    // MARK: Anti-caps

    func testAntiCaps() {
        let output = GGTextPipeline.run(GGPipelineText(text: "ПРИВЕТ ВСЕМ. КАК ДЕЛА", entities: []), configuration: GGTextPipelineConfiguration(antiCaps: true), context: self.plain)
        XCTAssertEqual(output.text, "Привет всем. Как дела")
    }

    func testAntiCapsKeepsCodesLinksAndMentions() {
        let text = "СМОТРИ HTTPS://EXAMPLE.COM/ABC @USERNAME КОД"
        let code = self.entity(self.utf16Range(of: "КОД", in: text), protected: true, overlay: true, tag: 4)
        let output = GGTextPipeline.run(GGPipelineText(text: text, entities: [code]), configuration: GGTextPipelineConfiguration(antiCaps: true), context: self.plain)
        XCTAssertTrue(output.text.hasPrefix("Смотри "))
        XCTAssertTrue(output.text.contains("HTTPS://EXAMPLE.COM/ABC"))
        XCTAssertTrue(output.text.contains("@USERNAME"))
        XCTAssertTrue(output.text.hasSuffix("КОД"))
    }

    func testAntiCapsLeavesNormalText() {
        let input = GGPipelineText(text: "Привет, это NASA", entities: [])
        XCTAssertEqual(GGTextPipeline.run(input, configuration: GGTextPipelineConfiguration(antiCaps: true), context: self.plain), input)
    }

    // MARK: Hyperlink

    func testHyperlinkKeepsFormattingAndSkipsLinks() {
        let text = "hello https://t.me/x world"
        let bold = self.entity(self.utf16Range(of: "hello", in: text), tag: 5)
        let url = self.entity(self.utf16Range(of: "https://t.me/x", in: text), protected: true, overlay: true, tag: 6)
        let output = GGTextPipeline.run(GGPipelineText(text: text, entities: [bold, url]), configuration: GGTextPipelineConfiguration(hyperlink: true), context: self.plain)
        XCTAssertEqual(output.text, text)
        let added = output.entities.filter { $0.tag == GGPipelineEntity.addedOverlay }
        XCTAssertEqual(added.map { output.substring($0.range) }, ["hello", "world"])
        XCTAssertEqual(output.entities.filter { $0.tag == 5 }.count, 1)
        XCTAssertEqual(output.entities.filter { $0.tag == 6 }.count, 1)
    }

    // MARK: Remap

    func testRemapInsideEdit() {
        let text = GGPipelineText(text: "abcdef", entities: [self.entity(2 ..< 4, tag: 7)])
        let output = text.applying([GGTextEdit(range: 1 ..< 5, replacement: "XY")])
        XCTAssertEqual(output.text, "aXYf")
        XCTAssertEqual(output.entities[0].range, 1 ..< 3)
    }

    func testRemapAfterEdit() {
        let text = GGPipelineText(text: "ab cd", entities: [self.entity(3 ..< 5, tag: 8)])
        let output = text.applying([GGTextEdit(range: 0 ..< 2, replacement: "abcd")])
        XCTAssertEqual(output.substring(output.entities[0].range), "cd")
    }
}
