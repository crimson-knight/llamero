enum CompletionLossMask {
    static func containsCompletion(_ tokenIds: [Int], marker: [Int]) -> Bool {
        guard !marker.isEmpty, tokenIds.count >= marker.count else { return false }
        return (0 ... tokenIds.count - marker.count).contains { start in
            tokenIds[start ..< start + marker.count].elementsEqual(marker)
        }
    }

    static func values(
        inputs: [Int32],
        lengths: [Int32],
        batchSize: Int,
        inputWidth: Int,
        marker: [Int]
    ) -> [Float]? {
        guard marker.count > 0,
            lengths.count == batchSize,
            inputs.count == batchSize * inputWidth
        else {
            return nil
        }

        let markerIds = marker.map(Int32.init)
        var mask = Array(repeating: 0.0 as Float, count: inputs.count)

        for row in 0 ..< batchSize {
            let validTargetCount = Int(lengths[row]) - 1
            guard validTargetCount > 0, validTargetCount <= inputWidth else { return nil }

            let rowStart = row * inputWidth
            let rowEnd = rowStart + validTargetCount
            guard validTargetCount >= markerIds.count else { return nil }
            let markerStart = (rowStart ... rowEnd - markerIds.count).first { start in
                inputs[start ..< start + markerIds.count].elementsEqual(markerIds)
            }
            guard let markerStart else { return nil }

            let completionStart = markerStart - rowStart + markerIds.count - 1
            guard completionStart < validTargetCount else { return nil }
            for targetIndex in completionStart ..< validTargetCount {
                mask[rowStart + targetIndex] = 1.0
            }
        }

        return mask
    }
}
