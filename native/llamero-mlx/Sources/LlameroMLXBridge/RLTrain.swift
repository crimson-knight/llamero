import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import MLXOptimizers
import Tokenizers

// Reinforcement-style training built on the same LoRA autodiff machinery the SFT
// path uses (valueAndGrad over the trainable LoRA params + Adam.update). Two
// methods:
//   - DPO: preference optimization over (prompt, chosen, rejected) triples,
//     relative to a cached frozen reference (the base model, no LoRA).
//   - Weighted/GRPO: advantage-weighted policy update — minimize
//     (-advantage * completion logprob), so positive-advantage samples are
//     reinforced and negative ones suppressed.
//
// The bridge orchestrates LoRA ordering: for DPO it caches references on the
// BASE, then installs LoRA, then runs the loop.
enum RLTrain {
    struct DPORow: Codable { let prompt: String; let chosen: String; let rejected: String }
    struct WeightedRow: Codable { let prompt: String; let completion: String; let weight: Float }

    struct Pref {
        let chosenFull: [Int]; let chosenPromptLen: Int
        let rejectedFull: [Int]; let rejectedPromptLen: Int
        var refChosen: Float = 0; var refRejected: Float = 0
    }

    struct WeightedSample { let full: [Int]; let promptLen: Int; let weight: Float }

    // Differentiable sum of log p(token) over the COMPLETION span of a full
    // (prompt+completion) token sequence. crossEntropy gives -logp per position;
    // we mask out the prompt positions and negate.
    static func completionLogprob(_ model: Module, _ fullTokens: [Int], _ promptLen: Int) -> MLXArray {
        let llm = model as! any LLMModel
        let n = fullTokens.count
        let input = MLXArray(fullTokens.map { Int32($0) }).reshaped([1, n])
        let logits = llm(input, cache: nil).asType(.float32) // [1, n, V]
        let shifted = logits[0..., 0 ..< (n - 1), 0...]       // predict token i from pos i-1
        let targets = MLXArray(fullTokens[1...].map { Int32($0) }).reshaped([1, n - 1])
        let ce = crossEntropy(logits: shifted, targets: targets) // [1, n-1] = -logp
        var maskVals = [Float](repeating: 0, count: n - 1)
        let lo = max(promptLen - 1, 0)
        if lo < n - 1 { for i in lo ..< (n - 1) { maskVals[i] = 1 } } // completion positions
        let mask = MLXArray(maskVals).reshaped([1, n - 1])
        return -(ce * mask).sum()
    }

    private static func loadLines(_ dataDir: URL) throws -> [String] {
        let url = dataDir.appending(component: "train.jsonl")
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.contains("{") }
    }

    private static func encode(_ tokenizer: any MLXLMCommon.Tokenizer, _ text: String) -> [Int] {
        tokenizer.encode(text: text)
    }

    // ---- DPO ----

    static func loadPrefs(dataDir: URL, tokenizer: any MLXLMCommon.Tokenizer) throws -> [Pref] {
        let decoder = JSONDecoder()
        var prefs: [Pref] = []
        for line in try loadLines(dataDir) {
            guard let row = try? decoder.decode(DPORow.self, from: Data(line.utf8)) else { continue }
            let pl = encode(tokenizer, row.prompt).count
            prefs.append(Pref(
                chosenFull: encode(tokenizer, row.prompt + row.chosen), chosenPromptLen: pl,
                rejectedFull: encode(tokenizer, row.prompt + row.rejected), rejectedPromptLen: pl))
        }
        if prefs.isEmpty { throw BridgeError(message: "DPO dataset has no valid {prompt,chosen,rejected} rows") }
        return prefs
    }

    // Cache reference logprobs from the FROZEN base — call BEFORE LoRA is installed.
    static func cacheReferences(model: Module, prefs: inout [Pref]) {
        for i in prefs.indices {
            let rc = completionLogprob(model, prefs[i].chosenFull, prefs[i].chosenPromptLen)
            let rr = completionLogprob(model, prefs[i].rejectedFull, prefs[i].rejectedPromptLen)
            eval(rc, rr)
            prefs[i].refChosen = rc.item(Float.self)
            prefs[i].refRejected = rr.item(Float.self)
        }
    }

    // Run the DPO loop on a model that NOW has LoRA installed. Reports
    // (iteration, loss, running-mean preference margin).
    static func runDPO(
        model: Module, prefs: [Pref],
        iterations: Int, learningRate: Float, beta: Float, stepsPerReport: Int,
        report: (Int, Double, Double) -> Void
    ) -> Double {
        let optimizer = Adam(learningRate: learningRate)
        var lastLoss = 0.0
        var marginSum = 0.0
        for iter in 0 ..< iterations {
            let p = prefs[iter % prefs.count]
            let refC = MLXArray(p.refChosen)
            let refR = MLXArray(p.refRejected)
            let b = MLXArray(beta)
            let lossAndGrad = valueAndGrad(model: model) { (m: Module, _: [MLXArray]) -> [MLXArray] in
                let polC = completionLogprob(m, p.chosenFull, p.chosenPromptLen)
                let polR = completionLogprob(m, p.rejectedFull, p.rejectedPromptLen)
                let margin = b * ((polC - refC) - (polR - refR))
                let loss = -log(sigmoid(margin))
                return [loss, margin]
            }
            let (vals, grad) = lossAndGrad(model, [])
            optimizer.update(model: model, gradients: grad)
            eval(model, optimizer, vals[0], vals[1])
            lastLoss = Double(vals[0].item(Float.self))
            marginSum += Double(vals[1].item(Float.self))
            if iter % stepsPerReport == 0 { report(iter, lastLoss, marginSum / Double(iter + 1)) }
        }
        return lastLoss
    }

    // ---- Weighted / GRPO ----

    static func runWeighted(
        model: Module, dataDir: URL, tokenizer: any MLXLMCommon.Tokenizer,
        iterations: Int, learningRate: Float, stepsPerReport: Int,
        report: (Int, Double) -> Void
    ) throws -> Double {
        let decoder = JSONDecoder()
        var samples: [WeightedSample] = []
        for line in try loadLines(dataDir) {
            guard let row = try? decoder.decode(WeightedRow.self, from: Data(line.utf8)) else { continue }
            let pl = encode(tokenizer, row.prompt).count
            let full = encode(tokenizer, row.prompt + row.completion)
            if full.count > pl { samples.append(WeightedSample(full: full, promptLen: pl, weight: row.weight)) }
        }
        if samples.isEmpty { throw BridgeError(message: "Weighted dataset has no valid {prompt,completion,weight} rows") }

        let optimizer = Adam(learningRate: learningRate)
        var lastLoss = 0.0
        for iter in 0 ..< iterations {
            let s = samples[iter % samples.count]
            let nTok = Float(max(s.full.count - s.promptLen, 1))
            let w = MLXArray(-s.weight / nTok) // minimize -weight*logp/ntok -> push logp by sign of weight
            let lossAndGrad = valueAndGrad(model: model) { (m: Module, _: [MLXArray]) -> [MLXArray] in
                [w * completionLogprob(m, s.full, s.promptLen)]
            }
            let (vals, grad) = lossAndGrad(model, [])
            optimizer.update(model: model, gradients: grad)
            eval(model, optimizer, vals[0])
            lastLoss = Double(vals[0].item(Float.self))
            if iter % stepsPerReport == 0 { report(iter, lastLoss) }
        }
        return lastLoss
    }
}
