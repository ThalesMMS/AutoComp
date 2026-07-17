#ifndef CLlamaBridge_h
#define CLlamaBridge_h

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AutoCompLlamaModel AutoCompLlamaModel;

typedef struct AutoCompLlamaError {
    int code;
    char message[512];
} AutoCompLlamaError;

typedef struct AutoCompLlamaCacheStats {
    uint64_t hits;
    uint64_t misses;
    uint64_t resets;
    int32_t retained_prompt_tokens;
    uint32_t context_tokens;
    int32_t last_prompt_tokens;
    int32_t last_common_prefix_tokens;
    int32_t last_reused_tokens;
    int32_t last_prefill_tokens;
    uint64_t last_tokenization_microseconds;
    uint64_t last_prefill_microseconds;
    uint64_t last_decode_microseconds;
    uint64_t cache_rebuilds;
    int32_t last_cache_miss_reason;
} AutoCompLlamaCacheStats;

typedef struct AutoCompLlamaCacheDecision {
    bool can_reuse;
    int32_t common_prefix_tokens;
} AutoCompLlamaCacheDecision;

typedef struct AutoCompLlamaTokenizerProfile {
    int32_t vocabulary_size;
    int32_t vocabulary_type;
    int32_t bos_token;
    int32_t eos_token;
    int32_t eot_token;
    int32_t newline_token;
    int32_t fim_prefix_token;
    int32_t fim_suffix_token;
    int32_t fim_middle_token;
    bool supports_fill_in_middle;
} AutoCompLlamaTokenizerProfile;

typedef struct AutoCompLlamaTokenMetadata {
    uint16_t flags;
    uint16_t approximate_display_width;
    int32_t byte_count;
} AutoCompLlamaTokenMetadata;

/// Called after each generated token with the UTF-8 text accumulated so far.
/// Return false to stop generation after the current token.
typedef bool (*AutoCompLlamaStreamCallback)(
    const char *accumulated_text,
    int32_t sequence,
    void *context
);

void autocomp_llama_backend_init(void);
void autocomp_llama_backend_free(void);
const char *autocomp_llama_system_info(void);

AutoCompLlamaModel *autocomp_llama_model_load(
    const char *path,
    bool load_vocabulary_only,
    AutoCompLlamaError *error
);

char *autocomp_llama_model_generate(
    AutoCompLlamaModel *model,
    const char *prompt,
    int32_t max_tokens,
    float temperature,
    const char * const *stop_sequences,
    int32_t stop_sequence_count,
    AutoCompLlamaError *error
);

char *autocomp_llama_model_generate_stream(
    AutoCompLlamaModel *model,
    const char *prompt,
    int32_t max_tokens,
    float temperature,
    const char * const *stop_sequences,
    int32_t stop_sequence_count,
    AutoCompLlamaStreamCallback callback,
    void *callback_context,
    AutoCompLlamaError *error
);

void autocomp_llama_model_reset_cache(AutoCompLlamaModel *model);
AutoCompLlamaCacheStats autocomp_llama_model_cache_stats(const AutoCompLlamaModel *model);

AutoCompLlamaCacheDecision autocomp_llama_prompt_cache_decision(
    const int32_t *cached_tokens,
    int32_t cached_token_count,
    int32_t cached_max_tokens,
    float cached_temperature,
    const int32_t *prompt_tokens,
    int32_t prompt_token_count,
    int32_t max_tokens,
    float temperature
);

bool autocomp_llama_model_tokenizer_profile(
    const AutoCompLlamaModel *model,
    AutoCompLlamaTokenizerProfile *profile,
    AutoCompLlamaError *error
);

bool autocomp_llama_model_token_metadata(
    const AutoCompLlamaModel *model,
    int32_t token,
    char *bytes,
    int32_t byte_capacity,
    AutoCompLlamaTokenMetadata *metadata,
    AutoCompLlamaError *error
);

int32_t autocomp_llama_model_top_tokens(
    AutoCompLlamaModel *model,
    const char *prompt,
    const int32_t *generated_tokens,
    int32_t generated_token_count,
    const int32_t *allowed_tokens,
    int32_t allowed_token_count,
    int32_t limit,
    int32_t *result_tokens,
    float *result_log_probabilities,
    AutoCompLlamaError *error
);

void autocomp_llama_model_free(AutoCompLlamaModel *model);
void autocomp_llama_string_free(char *string);
const char *autocomp_llama_error_message(const AutoCompLlamaError *error);

#ifdef __cplusplus
}
#endif

#endif
