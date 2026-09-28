enum AdapterKeyRemapping {
    static let legacyLayerPrefix = "model.layers."
    static let visionModelLayerPrefix = "language_model.model.layers."

    static func mapping(sourceKeys: [String], targetKeys: [String]) throws -> [String: String] {
        let sources = Set(sourceKeys)
        let targets = Set(targetKeys)
        guard sources.count == sourceKeys.count, targets.count == targetKeys.count else {
            throw BridgeError(message: "LoRA adapter contains duplicate parameter keys", code: "adapter_key_mismatch")
        }

        if sources == targets {
            return Dictionary(uniqueKeysWithValues: sourceKeys.map { ($0, $0) })
        }

        let candidates: [(String, String)] = [
            (legacyLayerPrefix, visionModelLayerPrefix),
            (visionModelLayerPrefix, legacyLayerPrefix),
        ]

        for (sourcePrefix, targetPrefix) in candidates {
            guard sourceKeys.allSatisfy({ $0.hasPrefix(sourcePrefix) }) else { continue }

            let mapped = sourceKeys.map { targetPrefix + String($0.dropFirst(sourcePrefix.count)) }
            guard Set(mapped).count == mapped.count, Set(mapped) == targets else { continue }
            return Dictionary(uniqueKeysWithValues: zip(sourceKeys, mapped))
        }

        throw BridgeError(
            message: "LoRA adapter keys do not match the model's trainable parameters in either supported Gemma 3 layout",
            code: "adapter_key_mismatch")
    }
}
