import Foundation
import XCTest
import Tokenizers
@testable import LlameroMLXBridge

private struct AmberTrainingCorpusRow: Decodable {
    let kind: String?
    let prompt: String?
    let completion: String?
}

final class AdapterKeyRemappingTests: XCTestCase {
    func testLegacyGemmaKeysMapToVisionModelLayout() throws {
        let oldKeys = [
            "model.layers.30.self_attn.q_proj.lora_A.weight",
            "model.layers.30.self_attn.q_proj.lora_B.weight",
        ]
        let newKeys = [
            "language_model.model.layers.30.self_attn.q_proj.lora_A.weight",
            "language_model.model.layers.30.self_attn.q_proj.lora_B.weight",
        ]

        XCTAssertEqual(
            try AdapterKeyRemapping.mapping(sourceKeys: oldKeys, targetKeys: newKeys),
            Dictionary(uniqueKeysWithValues: zip(oldKeys, newKeys)))
    }

    func testVisionModelKeysKeepTheirLayout() throws {
        let keys = ["language_model.model.layers.30.self_attn.q_proj.lora_A.weight"]
        XCTAssertEqual(
            try AdapterKeyRemapping.mapping(sourceKeys: keys, targetKeys: keys),
            [keys[0]: keys[0]])
    }

    func testVisionModelKeysMapToLegacyLayout() throws {
        let oldKeys = ["model.layers.30.self_attn.q_proj.lora_A.weight"]
        let newKeys = ["language_model.model.layers.30.self_attn.q_proj.lora_A.weight"]
        XCTAssertEqual(
            try AdapterKeyRemapping.mapping(sourceKeys: newKeys, targetKeys: oldKeys),
            [newKeys[0]: oldKeys[0]])
    }

    func testMixedAndUnexpectedKeysFailClosed() {
        let mixedKeys = [
            "model.layers.30.self_attn.q_proj.lora_A.weight",
            "language_model.model.layers.30.self_attn.q_proj.lora_B.weight",
        ]
        let targets = [
            "language_model.model.layers.30.self_attn.q_proj.lora_A.weight",
            "language_model.model.layers.30.self_attn.q_proj.lora_B.weight",
        ]

        XCTAssertThrowsError(try AdapterKeyRemapping.mapping(sourceKeys: mixedKeys, targetKeys: targets))
        XCTAssertThrowsError(try AdapterKeyRemapping.mapping(sourceKeys: ["other.layers.0.weight"], targetKeys: targets))
    }

    func testDuplicateSourceKeysFailClosed() {
        let key = "model.layers.30.self_attn.q_proj.lora_A.weight"
        XCTAssertThrowsError(try AdapterKeyRemapping.mapping(sourceKeys: [key, key], targetKeys: [key]))
    }

    func testGemma3TrainingTextMatchesThePinnedInferenceTemplate() async throws {
        guard let modelDirectory = ProcessInfo.processInfo.environment["LLAMERO_GEMMA3_MODEL_DIR"] else {
            throw XCTSkip("Set LLAMERO_GEMMA3_MODEL_DIR to run the pinned tokenizer parity test")
        }

        let upstream = try await Tokenizers.AutoTokenizer.from(
            modelFolder: URL(fileURLWithPath: modelDirectory))
        let tokenizer = LlameroTokenizerBridge(upstream)
        let messages: [[String: any Sendable]] = [
            ["role": "system", "content": "You are an expert Amber V2 and Grant developer."],
            ["role": "user", "content": "Show an invoice query."],
        ]
        let inferenceTokens = try tokenizer.applyChatTemplate(
            messages: messages, tools: nil, additionalContext: nil)

        let trainingText = "<start_of_turn>user\n" +
            "You are an expert Amber V2 and Grant developer.\n\n" +
            "Show an invoice query.<end_of_turn>\n" +
            "<start_of_turn>model\nTenantInvoice.where(active: true)<end_of_turn>\n"
        let trainingTokenizer = SpecialTokenAwareTrainingTokenizer(tokenizer)
        let trainingTokens = trainingTokenizer.encode(
            text: trainingText, addSpecialTokens: true)

        XCTAssertGreaterThan(trainingTokens.count, inferenceTokens.count)
        XCTAssertEqual(Array(trainingTokens.prefix(inferenceTokens.count)), inferenceTokens)
    }

    func testCompletionMaskIncludesCompletionTokensAndExcludesPromptAndPadding() throws {
        let mask = try XCTUnwrap(CompletionLossMask.values(
            inputs: [5, 90, 91, 7, 8, 6, 4, 90, 91, 3],
            lengths: [6, 5],
            batchSize: 2,
            inputWidth: 5,
            marker: [90, 91]))

        XCTAssertEqual(mask, [0, 0, 1, 1, 1, 0, 0, 0, 1, 0])
    }

    func testCompletionMaskFailsWhenASequenceHasNoAssistantMarker() {
        XCTAssertNil(CompletionLossMask.values(
            inputs: [5, 6, 7, 0],
            lengths: [4],
            batchSize: 1,
            inputWidth: 4,
            marker: [90, 91]))
    }

    func testRound3TrainingCorpusLengthDistribution() async throws {
        guard let modelDirectory = ProcessInfo.processInfo.environment["LLAMERO_GEMMA3_MODEL_DIR"],
            let corpusPath = ProcessInfo.processInfo.environment["LLAMERO_AMBER_CORPUS_PATH"]
        else {
            throw XCTSkip("Set the pinned Gemma 3 model and Amber corpus paths to measure lengths")
        }

        let upstream = try await Tokenizers.AutoTokenizer.from(
            modelFolder: URL(fileURLWithPath: modelDirectory))
        let tokenizer = SpecialTokenAwareTrainingTokenizer(LlameroTokenizerBridge(upstream))
        let decoder = JSONDecoder()
        let content = try String(contentsOf: URL(fileURLWithPath: corpusPath), encoding: .utf8)
        let rows = try content.split(whereSeparator: { $0.isNewline })
            .map { try decoder.decode(AmberTrainingCorpusRow.self, from: Data($0.utf8)) }
            .filter { $0.kind == "pair" }
        XCTAssertEqual(rows.count, 296)

        let system = "You are an expert Amber V2 and Grant developer. Answer with correct, idiomatic Crystal code."
        let marker = tokenizer.encode(text: "<start_of_turn>model\n", addSpecialTokens: false)
        var rawLongRows = 0
        var rawMaximum = 0
        var rawHypotheticalTail = 0
        var sftLongRows = 0
        var sftMaximum = 0
        var sftHypotheticalCompletionTail = 0

        for row in rows {
            guard let prompt = row.prompt, let completion = row.completion else {
                XCTFail("pair row is missing prompt/completion")
                continue
            }
            let trimmedCompletion = completion.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawTokens = tokenizer.encode(text: trimmedCompletion, addSpecialTokens: true)
            rawMaximum = max(rawMaximum, rawTokens.count)
            if rawTokens.count > 2048 {
                rawLongRows += 1
                rawHypotheticalTail += rawTokens.count - 2048
            }

            let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let trainingText = "<start_of_turn>user\n\(system)\n\n\(trimmedPrompt)<end_of_turn>\n" +
                "<start_of_turn>model\n\(trimmedCompletion)<end_of_turn>\n"
            let trainingTokens = tokenizer.encode(text: trainingText, addSpecialTokens: true)
            sftMaximum = max(sftMaximum, trainingTokens.count)
            if trainingTokens.count > 2048 {
                sftLongRows += 1
                let markerStart = try XCTUnwrap(firstRange(of: marker, in: trainingTokens))
                let completionStart = markerStart + marker.count
                let firstDroppedIndex = max(2048, completionStart)
                sftHypotheticalCompletionTail += max(0, trainingTokens.count - firstDroppedIndex)
            }
        }

        print("ROUND3_LENGTHS rows=\(rows.count) cap=2048 raw_long=\(rawLongRows) raw_max=\(rawMaximum) raw_hypothetical_tail_tokens=\(rawHypotheticalTail) sft_long=\(sftLongRows) sft_max=\(sftMaximum) sft_hypothetical_completion_tail_tokens=\(sftHypotheticalCompletionTail) actual_truncated_rows=0")
        XCTAssertEqual(rawLongRows, 1)
        XCTAssertEqual(rawMaximum, 2105)
        XCTAssertEqual(rawHypotheticalTail, 57)
        XCTAssertEqual(sftLongRows, 1)
        XCTAssertEqual(sftMaximum, 2148)
        XCTAssertEqual(sftHypotheticalCompletionTail, 100)
    }

    private func firstRange(of needle: [Int], in values: [Int]) -> Int? {
        guard !needle.isEmpty, values.count >= needle.count else { return nil }
        return (0 ... values.count - needle.count).first { start in
            values[start ..< start + needle.count].elementsEqual(needle)
        }
    }
}
