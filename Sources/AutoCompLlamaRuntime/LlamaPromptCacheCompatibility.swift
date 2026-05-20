import CLlamaBridge

struct LlamaPromptCacheCompatibility: Equatable, Sendable {
    let canReuse: Bool
    let commonPrefixTokens: Int

    static func evaluate(
        cachedTokens: [Int32],
        cachedMaxTokens: Int32,
        cachedTemperature: Float,
        promptTokens: [Int32],
        maxTokens: Int32,
        temperature: Float
    ) -> LlamaPromptCacheCompatibility {
        let decision = cachedTokens.withUnsafeBufferPointer { cachedBuffer in
            promptTokens.withUnsafeBufferPointer { promptBuffer in
                autocomp_llama_prompt_cache_decision(
                    cachedBuffer.baseAddress,
                    Int32(cachedBuffer.count),
                    cachedMaxTokens,
                    cachedTemperature,
                    promptBuffer.baseAddress,
                    Int32(promptBuffer.count),
                    maxTokens,
                    temperature
                )
            }
        }

        return LlamaPromptCacheCompatibility(
            canReuse: decision.can_reuse,
            commonPrefixTokens: Int(decision.common_prefix_tokens)
        )
    }
}
