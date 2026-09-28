import XCTest
@testable import LlameroMLXBridge

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
}
