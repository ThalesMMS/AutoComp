#include "CLlamaBridge.h"

#include <llama.h>
#include <math.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct AutoCompLlamaSamplingSignature {
    int32_t max_tokens;
    float temperature;
    int32_t top_k;
    float top_p;
    uint32_t seed;
} AutoCompLlamaSamplingSignature;

struct AutoCompLlamaModel {
    struct llama_model *raw;
    struct llama_context *cached_ctx;
    llama_token *cached_prompt_tokens;
    int32_t cached_prompt_count;
    uint32_t cached_context_tokens;
    AutoCompLlamaSamplingSignature cached_sampling;
    uint64_t cache_hits;
    uint64_t cache_misses;
    uint64_t cache_resets;
};

static const int32_t autocomp_llama_top_k = 40;
static const float autocomp_llama_top_p = 0.95f;
static const uint32_t autocomp_llama_seed = 42;

static void autocomp_llama_set_error(AutoCompLlamaError *error, int code, const char *message) {
    if (error == NULL) {
        return;
    }

    error->code = code;
    if (message == NULL) {
        message = "Unknown llama.cpp error.";
    }
    snprintf(error->message, sizeof(error->message), "%s", message);
}

static void autocomp_llama_discard_log(enum ggml_log_level level, const char *text, void *user_data) {
    (void)level;
    (void)text;
    (void)user_data;
}

static float autocomp_llama_sanitized_temperature(float temperature) {
    if (!isfinite(temperature) || temperature < 0.0f) {
        return 0.20f;
    }
    return temperature;
}

static AutoCompLlamaSamplingSignature autocomp_llama_sampling_signature(
    int32_t max_tokens,
    float temperature
) {
    AutoCompLlamaSamplingSignature signature = {
        .max_tokens = max_tokens,
        .temperature = autocomp_llama_sanitized_temperature(temperature),
        .top_k = autocomp_llama_top_k,
        .top_p = autocomp_llama_top_p,
        .seed = autocomp_llama_seed
    };
    return signature;
}

static bool autocomp_llama_sampling_signature_equal(
    AutoCompLlamaSamplingSignature lhs,
    AutoCompLlamaSamplingSignature rhs
) {
    return lhs.max_tokens == rhs.max_tokens
        && fabsf(lhs.temperature - rhs.temperature) <= 0.0001f
        && lhs.top_k == rhs.top_k
        && fabsf(lhs.top_p - rhs.top_p) <= 0.0001f
        && lhs.seed == rhs.seed;
}

static int32_t autocomp_llama_common_prefix_count(
    const llama_token *lhs,
    int32_t lhs_count,
    const llama_token *rhs,
    int32_t rhs_count
) {
    int32_t limit = lhs_count < rhs_count ? lhs_count : rhs_count;
    int32_t count = 0;
    while (count < limit && lhs[count] == rhs[count]) {
        count += 1;
    }
    return count;
}

static void autocomp_llama_clear_cache(AutoCompLlamaModel *model, bool count_reset) {
    if (model == NULL) {
        return;
    }

    bool had_cache = model->cached_ctx != NULL || model->cached_prompt_tokens != NULL;
    if (model->cached_ctx != NULL) {
        llama_free(model->cached_ctx);
        model->cached_ctx = NULL;
    }
    free(model->cached_prompt_tokens);
    model->cached_prompt_tokens = NULL;
    model->cached_prompt_count = 0;
    model->cached_context_tokens = 0;
    memset(&model->cached_sampling, 0, sizeof(model->cached_sampling));

    if (count_reset && had_cache) {
        model->cache_resets += 1;
    }
}

static struct llama_context *autocomp_llama_create_context(
    struct llama_model *model,
    uint32_t context_tokens
) {
    struct llama_context_params context_params = llama_context_default_params();
    context_params.n_ctx = context_tokens;
    context_params.n_batch = context_tokens;
    context_params.n_ubatch = context_tokens;

    struct llama_context *ctx = llama_init_from_model(model, context_params);
    if (ctx != NULL) {
        llama_set_n_threads(ctx, 4, 4);
    }
    return ctx;
}

static char *autocomp_llama_format_chat_prompt(struct llama_model *model, const char *prompt) {
    const char *chat_template = llama_model_chat_template(model, NULL);
    if (chat_template == NULL) {
        return NULL;
    }

    const llama_chat_message message = {
        .role = "user",
        .content = prompt
    };
    int32_t length = llama_chat_apply_template(chat_template, &message, 1, true, NULL, 0);
    if (length <= 0) {
        return NULL;
    }

    char *buffer = (char *)malloc((size_t)length + 1);
    if (buffer == NULL) {
        return NULL;
    }

    int32_t written = llama_chat_apply_template(chat_template, &message, 1, true, buffer, length + 1);
    if (written < 0) {
        free(buffer);
        return NULL;
    }
    buffer[written] = '\0';
    return buffer;
}

AutoCompLlamaCacheDecision autocomp_llama_prompt_cache_decision(
    const int32_t *cached_tokens,
    int32_t cached_token_count,
    int32_t cached_max_tokens,
    float cached_temperature,
    const int32_t *prompt_tokens,
    int32_t prompt_token_count,
    int32_t max_tokens,
    float temperature
) {
    AutoCompLlamaCacheDecision decision = {
        .can_reuse = false,
        .common_prefix_tokens = 0
    };

    if (cached_tokens == NULL || prompt_tokens == NULL || cached_token_count <= 0 || prompt_token_count <= 0) {
        return decision;
    }

    AutoCompLlamaSamplingSignature cached_signature = autocomp_llama_sampling_signature(
        cached_max_tokens,
        cached_temperature
    );
    AutoCompLlamaSamplingSignature prompt_signature = autocomp_llama_sampling_signature(
        max_tokens,
        temperature
    );
    if (!autocomp_llama_sampling_signature_equal(cached_signature, prompt_signature)) {
        return decision;
    }

    decision.common_prefix_tokens = autocomp_llama_common_prefix_count(
        (const llama_token *)cached_tokens,
        cached_token_count,
        (const llama_token *)prompt_tokens,
        prompt_token_count
    );
    decision.can_reuse = decision.common_prefix_tokens > 0;
    return decision;
}

void autocomp_llama_backend_init(void) {
    llama_log_set(autocomp_llama_discard_log, NULL);
    llama_backend_init();
}

void autocomp_llama_backend_free(void) {
    llama_backend_free();
}

AutoCompLlamaModel *autocomp_llama_model_load(
    const char *path,
    bool load_vocabulary_only,
    AutoCompLlamaError *error
) {
    if (path == NULL || path[0] == '\0') {
        autocomp_llama_set_error(error, 1, "Model path is empty.");
        return NULL;
    }

    struct llama_model_params params = llama_model_default_params();
    params.vocab_only = load_vocabulary_only;
    params.n_gpu_layers = 0;
    params.use_mmap = true;

    struct llama_model *raw_model = llama_model_load_from_file(path, params);
    if (raw_model == NULL) {
        autocomp_llama_set_error(error, 2, "llama_model_load_from_file returned nil.");
        return NULL;
    }

    AutoCompLlamaModel *model = (AutoCompLlamaModel *)malloc(sizeof(AutoCompLlamaModel));
    if (model == NULL) {
        llama_model_free(raw_model);
        autocomp_llama_set_error(error, 3, "Could not allocate model wrapper.");
        return NULL;
    }

    model->raw = raw_model;
    model->cached_ctx = NULL;
    model->cached_prompt_tokens = NULL;
    model->cached_prompt_count = 0;
    model->cached_context_tokens = 0;
    memset(&model->cached_sampling, 0, sizeof(model->cached_sampling));
    model->cache_hits = 0;
    model->cache_misses = 0;
    model->cache_resets = 0;
    autocomp_llama_set_error(error, 0, "");
    return model;
}

char *autocomp_llama_model_generate(
    AutoCompLlamaModel *model,
    const char *prompt,
    int32_t max_tokens,
    float temperature,
    AutoCompLlamaError *error
) {
    if (model == NULL || model->raw == NULL) {
        autocomp_llama_set_error(error, 4, "Model is not loaded.");
        return NULL;
    }
    if (prompt == NULL || prompt[0] == '\0') {
        autocomp_llama_set_error(error, 5, "Prompt is empty.");
        return NULL;
    }
    if (max_tokens <= 0) {
        autocomp_llama_set_error(error, 6, "Max tokens must be positive.");
        return NULL;
    }

    AutoCompLlamaSamplingSignature sampling = autocomp_llama_sampling_signature(max_tokens, temperature);
    const struct llama_vocab *vocab = llama_model_get_vocab(model->raw);
    char *formatted_prompt = autocomp_llama_format_chat_prompt(model->raw, prompt);
    const char *prompt_to_tokenize = formatted_prompt != NULL ? formatted_prompt : prompt;
    const int32_t prompt_length = (int32_t)strlen(prompt_to_tokenize);
    int32_t prompt_token_count = llama_tokenize(vocab, prompt_to_tokenize, prompt_length, NULL, 0, true, true);
    if (prompt_token_count == INT32_MIN) {
        free(formatted_prompt);
        autocomp_llama_set_error(error, 7, "Prompt tokenization overflowed.");
        return NULL;
    }
    if (prompt_token_count < 0) {
        prompt_token_count = -prompt_token_count;
    }
    if (prompt_token_count <= 0) {
        free(formatted_prompt);
        autocomp_llama_set_error(error, 8, "Prompt produced no tokens.");
        return NULL;
    }

    llama_token *prompt_tokens = (llama_token *)malloc((size_t)prompt_token_count * sizeof(llama_token));
    if (prompt_tokens == NULL) {
        free(formatted_prompt);
        autocomp_llama_set_error(error, 9, "Could not allocate prompt tokens.");
        return NULL;
    }

    int32_t tokenized = llama_tokenize(
        vocab,
        prompt_to_tokenize,
        prompt_length,
        prompt_tokens,
        prompt_token_count,
        true,
        true
    );
    free(formatted_prompt);
    if (tokenized < 0) {
        free(prompt_tokens);
        autocomp_llama_set_error(error, 10, "Prompt tokenization failed.");
        return NULL;
    }
    prompt_token_count = tokenized;

    uint32_t context_tokens = (uint32_t)(prompt_token_count + max_tokens + 8);
    if (context_tokens < 512) {
        context_tokens = 512;
    }
    if (context_tokens > 4096) {
        context_tokens = 4096;
    }
    if ((uint32_t)(prompt_token_count + max_tokens) >= context_tokens) {
        free(prompt_tokens);
        autocomp_llama_set_error(error, 11, "Prompt is too large for the local generation context.");
        return NULL;
    }

    bool can_reuse_cache = false;
    int32_t decode_start = 0;
    if (model->cached_ctx != NULL
        && model->cached_prompt_tokens != NULL
        && model->cached_prompt_count > 0
        && model->cached_context_tokens == context_tokens
        && autocomp_llama_sampling_signature_equal(model->cached_sampling, sampling)) {
        int32_t common_prefix = autocomp_llama_common_prefix_count(
            model->cached_prompt_tokens,
            model->cached_prompt_count,
            prompt_tokens,
            prompt_token_count
        );
        if (common_prefix > 0) {
            decode_start = common_prefix - 1;
            llama_memory_t memory = llama_get_memory(model->cached_ctx);
            can_reuse_cache = llama_memory_seq_rm(memory, 0, decode_start, -1);
            if (!can_reuse_cache) {
                autocomp_llama_clear_cache(model, true);
                decode_start = 0;
            }
        }
    }

    struct llama_context *ctx = NULL;
    if (can_reuse_cache) {
        model->cache_hits += 1;
        ctx = model->cached_ctx;
    } else {
        model->cache_misses += 1;
        autocomp_llama_clear_cache(model, true);
        ctx = autocomp_llama_create_context(model->raw, context_tokens);
        if (ctx == NULL) {
            free(prompt_tokens);
            autocomp_llama_set_error(error, 12, "llama_init_from_model returned nil.");
            return NULL;
        }
        model->cached_ctx = ctx;
        model->cached_context_tokens = context_tokens;
        model->cached_sampling = sampling;
    }

    struct llama_batch prompt_batch = llama_batch_get_one(
        prompt_tokens + decode_start,
        prompt_token_count - decode_start
    );
    int32_t decode_result = llama_decode(ctx, prompt_batch);
    if (decode_result != 0) {
        free(prompt_tokens);
        autocomp_llama_clear_cache(model, true);
        autocomp_llama_set_error(error, 13, "llama_decode failed for the prompt.");
        return NULL;
    }

    free(model->cached_prompt_tokens);
    model->cached_prompt_tokens = prompt_tokens;
    model->cached_prompt_count = prompt_token_count;
    model->cached_context_tokens = context_tokens;
    model->cached_sampling = sampling;
    prompt_tokens = NULL;

    struct llama_sampler_chain_params sampler_params = llama_sampler_chain_default_params();
    struct llama_sampler *sampler = llama_sampler_chain_init(sampler_params);
    if (sampler == NULL) {
        autocomp_llama_clear_cache(model, true);
        autocomp_llama_set_error(error, 14, "Could not initialize sampler.");
        return NULL;
    }
    llama_sampler_chain_add(sampler, llama_sampler_init_top_k(sampling.top_k));
    llama_sampler_chain_add(sampler, llama_sampler_init_top_p(sampling.top_p, 1));
    llama_sampler_chain_add(sampler, llama_sampler_init_temp(sampling.temperature));
    llama_sampler_chain_add(sampler, llama_sampler_init_dist(sampling.seed));

    llama_token *generated_tokens = (llama_token *)malloc((size_t)max_tokens * sizeof(llama_token));
    if (generated_tokens == NULL) {
        llama_sampler_free(sampler);
        autocomp_llama_clear_cache(model, true);
        autocomp_llama_set_error(error, 15, "Could not allocate generated tokens.");
        return NULL;
    }

    int32_t generated_count = 0;
    for (int32_t i = 0; i < max_tokens; i++) {
        llama_token token = llama_sampler_sample(sampler, ctx, -1);
        if (llama_vocab_is_eog(vocab, token)) {
            break;
        }

        llama_sampler_accept(sampler, token);
        generated_tokens[generated_count] = token;
        generated_count += 1;

        if (i == max_tokens - 1) {
            break;
        }

        struct llama_batch next_batch = llama_batch_get_one(&token, 1);
        decode_result = llama_decode(ctx, next_batch);
        if (decode_result != 0) {
            free(generated_tokens);
            llama_sampler_free(sampler);
            autocomp_llama_clear_cache(model, true);
            autocomp_llama_set_error(error, 16, "llama_decode failed during generation.");
            return NULL;
        }
    }

    if (generated_count == 0) {
        free(generated_tokens);
        llama_sampler_free(sampler);
        autocomp_llama_clear_cache(model, true);
        autocomp_llama_set_error(error, 17, "Generation produced no tokens.");
        return NULL;
    }

    int32_t text_capacity = generated_count * 32 + 64;
    char *text = (char *)malloc((size_t)text_capacity);
    if (text == NULL) {
        free(generated_tokens);
        llama_sampler_free(sampler);
        autocomp_llama_clear_cache(model, true);
        autocomp_llama_set_error(error, 18, "Could not allocate generated text.");
        return NULL;
    }

    int32_t detokenized = llama_detokenize(
        vocab,
        generated_tokens,
        generated_count,
        text,
        text_capacity,
        false,
        false
    );
    if (detokenized < 0) {
        text_capacity = -detokenized + 1;
        char *larger_text = (char *)realloc(text, (size_t)text_capacity);
        if (larger_text == NULL) {
            free(text);
            free(generated_tokens);
            llama_sampler_free(sampler);
            autocomp_llama_clear_cache(model, true);
            autocomp_llama_set_error(error, 19, "Could not grow generated text buffer.");
            return NULL;
        }
        text = larger_text;
        detokenized = llama_detokenize(
            vocab,
            generated_tokens,
            generated_count,
            text,
            text_capacity,
            false,
            false
        );
    }

    free(generated_tokens);
    llama_sampler_free(sampler);

    if (detokenized < 0) {
        free(text);
        autocomp_llama_clear_cache(model, true);
        autocomp_llama_set_error(error, 20, "Could not detokenize generated text.");
        return NULL;
    }

    text[detokenized] = '\0';
    autocomp_llama_set_error(error, 0, "");
    return text;
}

void autocomp_llama_model_reset_cache(AutoCompLlamaModel *model) {
    autocomp_llama_clear_cache(model, true);
}

AutoCompLlamaCacheStats autocomp_llama_model_cache_stats(const AutoCompLlamaModel *model) {
    AutoCompLlamaCacheStats stats = {
        .hits = 0,
        .misses = 0,
        .resets = 0,
        .retained_prompt_tokens = 0,
        .context_tokens = 0
    };
    if (model == NULL) {
        return stats;
    }

    stats.hits = model->cache_hits;
    stats.misses = model->cache_misses;
    stats.resets = model->cache_resets;
    stats.retained_prompt_tokens = model->cached_prompt_count;
    stats.context_tokens = model->cached_context_tokens;
    return stats;
}

void autocomp_llama_model_free(AutoCompLlamaModel *model) {
    if (model == NULL) {
        return;
    }

    autocomp_llama_clear_cache(model, false);
    if (model->raw != NULL) {
        llama_model_free(model->raw);
    }
    free(model);
}

void autocomp_llama_string_free(char *string) {
    free(string);
}

const char *autocomp_llama_error_message(const AutoCompLlamaError *error) {
    if (error == NULL || error->message[0] == '\0') {
        return "Unknown llama.cpp error.";
    }
    return error->message;
}
