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
} AutoCompLlamaCacheStats;

typedef struct AutoCompLlamaCacheDecision {
    bool can_reuse;
    int32_t common_prefix_tokens;
} AutoCompLlamaCacheDecision;

void autocomp_llama_backend_init(void);
void autocomp_llama_backend_free(void);

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

void autocomp_llama_model_free(AutoCompLlamaModel *model);
void autocomp_llama_string_free(char *string);
const char *autocomp_llama_error_message(const AutoCompLlamaError *error);

#ifdef __cplusplus
}
#endif

#endif
