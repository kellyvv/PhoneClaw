#ifndef PIPER_PLUS_H_
#define PIPER_PLUS_H_

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ===== ABI Policy =====
 * - All input structs (Config, SynthOptions) have _reserved fields for future
 *   expansion without breaking ABI. Output structs (AudioChunk, PhonemeInfo,
 *   TimingResult) are read-only and versioned via PIPER_PLUS_API_VERSION.
 * - Callers MUST zero-initialize input structs with memset() or = {0} before
 *   populating fields. This ensures that _reserved fields and any fields added
 *   in future versions default to zero.
 * - _reserved fields MUST be zero. Non-zero values in _reserved are reserved
 *   for future use and may cause errors in later versions.
 * - Query functions (piper_plus_sample_rate, num_speakers, num_languages,
 *   language_id, dict_entry_count) return a sentinel value on error (see each
 *   function's documentation) rather than a Status code, for ergonomic use in
 *   expressions. Use piper_plus_get_last_error() if you need the error message.
 */

/* ===== Export macro ===== */
#if defined(_WIN32) || defined(_WIN64)
  #ifdef PIPER_PLUS_BUILDING_DLL
    #define PIPER_PLUS_API __declspec(dllexport)
  #else
    #define PIPER_PLUS_API __declspec(dllimport)
  #endif
#elif defined(__GNUC__) && __GNUC__ >= 4
  #define PIPER_PLUS_API __attribute__((visibility("default")))
#else
  #define PIPER_PLUS_API
#endif

/* ===== Version ===== */
#define PIPER_PLUS_API_VERSION 1

/** Returns version string. The returned pointer is static storage; do not free. */
PIPER_PLUS_API const char *piper_plus_version(void);
PIPER_PLUS_API int32_t     piper_plus_api_version(void);

/* ===== Status codes ===== */

typedef enum PiperPlusStatus {
    PIPER_PLUS_OK          =  0,
    PIPER_PLUS_DONE        =  1,
    PIPER_PLUS_ERR         = -1,
    PIPER_PLUS_ERR_MODEL   = -2,
    PIPER_PLUS_ERR_CONFIG  = -3,
    PIPER_PLUS_ERR_TEXT    = -4,
    PIPER_PLUS_ERR_BUSY    = -5,
    PIPER_PLUS_ERR_ORT     = -6
} PiperPlusStatus;

/* ===== Error ===== */

/** Returns the error message for the CALLING thread (thread-local storage).
 *  @return NUL-terminated error string, or NULL if no error has occurred.
 *  @note The returned pointer is valid until the next piper_plus_* call on
 *        the same thread. Caller should copy the string if persistence is
 *        needed beyond that point.
 *  @threading Safe to call from any thread. Each thread has independent
 *             error state. */
PIPER_PLUS_API const char *piper_plus_get_last_error(void);

/* ===== Opaque engine handle ===== */

/**
 * Opaque engine handle.
 *
 * @note PiperPlusEngine is NOT thread-safe. Do not call any function on
 *       the same engine from multiple threads concurrently.
 *       Use one engine per thread, or protect with an external mutex.
 */
typedef struct PiperPlusEngine PiperPlusEngine;

/* ===== Config structs (POD, memset-safe) ===== */

typedef struct PiperPlusConfig {
    const char *model_path;       /* Required: .onnx model file path (UTF-8) */
    const char *config_path;      /* Optional: .json config path (NULL = model_path + ".json") */
    const char *provider;         /* Optional: "cpu","cuda","coreml","directml" (NULL = "cpu") */
    int32_t     num_threads;      /* ONNX intra-op threads (0 = auto) */
    int32_t     gpu_device_id;    /* GPU device index (ignored for cpu) */
    const char *dict_dir;         /* Optional: OpenJTalk dict dir (NULL = auto-detect) */
    int32_t     _reserved[7];     /* Must be zero */
} PiperPlusConfig;

/** @note Zero-init safe: noise_scale, length_scale, noise_w が 0.0 の場合は
 *        デフォルト値 (0.667, 1.0, 0.8) に自動置換されます。 */
typedef struct PiperPlusSynthOptions {
    int32_t speaker_id;                 /* Speaker index (default: 0) */
    int32_t language_id;                /* Language index (-1 = auto-detect, default: -1) */
    float   noise_scale;                /* VITS noise_scale (default: 0.667) */
    float   length_scale;               /* VITS length_scale (default: 1.0) */
    float   noise_w;                    /* VITS noise_w (default: 0.8) */
    float   sentence_silence_sec;       /* Silence between sentences in sec (default: 0.2) */
    const float *speaker_embedding;     /* Voice cloning: float32 embedding (NULL = use speaker_id) */
    int32_t      speaker_embedding_dim; /* Number of elements in speaker_embedding (0 = disabled) */
    int32_t _reserved[5];               /* Must be zero */
} PiperPlusSynthOptions;

/* ===== Lifecycle ===== */

PIPER_PLUS_API PiperPlusStatus  piper_plus_create(const PiperPlusConfig *config,
                                                  PiperPlusEngine      **out_engine);
PIPER_PLUS_API void             piper_plus_free(PiperPlusEngine *engine);

/* ===== Default options ===== */

PIPER_PLUS_API PiperPlusSynthOptions piper_plus_default_options(void);

/* ===== One-shot synthesis ===== */

PIPER_PLUS_API PiperPlusStatus piper_plus_synthesize(
    PiperPlusEngine              *engine,
    const char                   *text,
    const PiperPlusSynthOptions  *opts,       /* NULL = defaults */
    float                       **out_samples,
    int32_t                      *out_num_samples,
    int32_t                      *out_sample_rate);

PIPER_PLUS_API void piper_plus_free_audio(float *samples);

/* ===== Query =====
 * These functions return scalar values directly for ergonomic use.
 * On error (NULL engine, invalid argument), they return a sentinel value
 * (0 or -1 as documented below) and set the thread-local error string. */

/** Returns sample rate in Hz, or 0 on error (NULL engine). */
PIPER_PLUS_API int32_t piper_plus_sample_rate(const PiperPlusEngine *engine);

/** Returns number of speakers in the model, or 0 on error (NULL engine). */
PIPER_PLUS_API int32_t piper_plus_num_speakers(const PiperPlusEngine *engine);

/** Returns number of languages in the model, or 0 on error (NULL engine). */
PIPER_PLUS_API int32_t piper_plus_num_languages(const PiperPlusEngine *engine);

/** Returns language index for the given name, or -1 if not found or on error.
 *  @param language_name  Language code string (e.g. "ja", "en"). */
PIPER_PLUS_API int32_t piper_plus_language_id(
    const PiperPlusEngine *engine,
    const char            *language_name);

/* ===== ZH-EN code-switching dispatch (Issue #384) ===== */

/** Toggle the ZH-EN code-switching dispatch path.
 *
 *  When enabled (default = 1), an English text segment that is adjacent to
 *  a Chinese segment is routed through the loanword path so e.g. "GPS" sounds
 *  Mandarin-style. Set to 0 to restore the v1.11 CMU-only behavior.
 *
 *  @threading Inherits ``PiperPlusEngine``'s "one engine per thread" contract.
 *    This function MUST NOT be called concurrently with synthesis or any
 *    other engine call on the same handle. The toggle is a plain (non-atomic)
 *    write because the engine is already single-threaded; if you need to
 *    flip the flag from another thread, serialize the call yourself or use a
 *    dedicated control engine.
 *
 *  @param engine   Engine handle.
 *  @param enabled  0 = disable, non-zero = enable.
 *  @return         PIPER_PLUS_OK on success, error code on NULL engine. */
PIPER_PLUS_API PiperPlusStatus piper_plus_set_zh_en_dispatch(
    PiperPlusEngine *engine,
    int32_t          enabled);

/** Returns 1 if the ZH-EN code-switching dispatch is currently enabled, 0 if
 *  disabled, or -1 on error (NULL engine).
 *
 *  @warning Callers MUST check the -1 sentinel before any boolean coercion.
 *    A naive ``if (piper_plus_is_zh_en_dispatch_enabled(eng))`` will treat
 *    -1 (error) as enabled. The signed-int pattern is shared with
 *    ``piper_plus_language_id``. */
PIPER_PLUS_API int32_t piper_plus_is_zh_en_dispatch_enabled(
    const PiperPlusEngine *engine);

/* ===== Audio chunk (for iterator/streaming) ===== */

/**
 * Audio data returned by iterator/streaming synthesis.
 *
 * @lifetime The samples pointer is BORROWED from the engine's internal buffer.
 *   - For synth_next(): valid until the next synth_next() or synth_start() call
 *     on the same engine.
 *   - For streaming callback (PiperPlusAudioCallback / PiperPlusAudioCallbackEx):
 *     valid only during the callback invocation.
 *   - Caller MUST copy the data if retention is needed beyond these boundaries.
 */
typedef struct PiperPlusAudioChunk {
    const float *samples;         /**< BORROWED: see struct-level @lifetime doc */
    int32_t      num_samples;     /**< Number of float samples */
    int32_t      sample_rate;     /**< Sample rate in Hz */
    int32_t      is_last;         /**< 1 if this is the last chunk, 0 otherwise */
} PiperPlusAudioChunk;

/* ===== Iterator pattern (sentence-by-sentence synthesis) ===== */

/**
 * Start iterative synthesis.
 * Splits text into sentences and prepares internal queue.
 * Call piper_plus_synth_next() repeatedly to get audio chunks.
 *
 * @note One engine = one synthesis at a time (NOT thread-safe).
 * @note out_chunk->samples points to internal buffer;
 *       valid until next synth_next() or synth_start() call.
 */
PIPER_PLUS_API PiperPlusStatus piper_plus_synth_start(
    PiperPlusEngine              *engine,
    const char                   *text,
    const PiperPlusSynthOptions  *opts);

PIPER_PLUS_API PiperPlusStatus piper_plus_synth_next(
    PiperPlusEngine      *engine,
    PiperPlusAudioChunk  *out_chunk);

/* ===== Streaming callback synthesis ===== */

/** Audio callback for streaming synthesis.
 *  @param samples      BORROWED: valid only during this callback invocation.
 *                      Caller MUST copy if retention is needed.
 *  @param num_samples  Number of float samples in the buffer.
 *  @param sample_rate  Sample rate in Hz.
 *  @param user_data    Opaque pointer passed to synthesize_streaming(). */
typedef void (*PiperPlusAudioCallback)(
    const float *samples,
    int32_t      num_samples,
    int32_t      sample_rate,
    void        *user_data);

/**
 * Synthesize text with streaming callback.
 * Internally drives synth_start/synth_next and delivers chunks via callback.
 *
 * @note Callback is invoked on caller's thread (synchronous).
 * @note samples pointer in callback is valid only during invocation.
 */
PIPER_PLUS_API PiperPlusStatus piper_plus_synthesize_streaming(
    PiperPlusEngine              *engine,
    const char                   *text,
    const PiperPlusSynthOptions  *opts,
    PiperPlusAudioCallback        callback,
    void                         *user_data);

/* ===== Cancellable streaming callback (M5-7) ===== */

/** Cancellable audio callback. Return 0 to continue, non-zero to abort.
 *  @param samples      BORROWED: valid only during this callback invocation.
 *                      Caller MUST copy if retention is needed.
 *  @param num_samples  Number of float samples in the buffer.
 *  @param sample_rate  Sample rate in Hz.
 *  @param user_data    Opaque pointer passed to synthesize_streaming_ex().
 *  @return 0 to continue synthesis, non-zero to abort (not treated as error). */
typedef int (*PiperPlusAudioCallbackEx)(
    const float *samples,
    int32_t      num_samples,
    int32_t      sample_rate,
    void        *user_data);

/** Synthesize with cancellable streaming.
 *  If callback returns non-zero, synthesis stops and function returns
 *  PIPER_PLUS_OK (not an error -- caller requested abort). */
PIPER_PLUS_API PiperPlusStatus piper_plus_synthesize_streaming_ex(
    PiperPlusEngine              *engine,
    const char                   *text,
    const PiperPlusSynthOptions  *opts,
    PiperPlusAudioCallbackEx      callback,
    void                         *user_data);

/* ===== Custom dictionary (M4-1) ===== */

PIPER_PLUS_API PiperPlusStatus piper_plus_load_custom_dict(
    PiperPlusEngine *engine,
    const char      *dict_path);

PIPER_PLUS_API PiperPlusStatus piper_plus_clear_custom_dict(PiperPlusEngine *engine);

PIPER_PLUS_API PiperPlusStatus piper_plus_add_dict_word(
    PiperPlusEngine *engine,
    const char      *word,
    const char      *pronunciation,
    int32_t          priority);

/** Returns number of entries in the custom dictionary, or 0 on error
 *  (NULL engine or no dictionary loaded). */
PIPER_PLUS_API int32_t piper_plus_dict_entry_count(const PiperPlusEngine *engine);

/* ===== Phoneme timing (M4-2) ===== */

/**
 * Phoneme timing entry from the last synthesis.
 *
 * @lifetime All BORROWED pointers (phoneme string, entries array) are valid
 *   until the next synthesis call (synthesize, synth_start, synth_next, or
 *   synthesize_streaming*) on the same engine. Caller MUST copy the data if
 *   retention is needed beyond that point.
 */
typedef struct PiperPlusPhonemeInfo {
    const char *phoneme;       /**< BORROWED: phoneme string (UTF-8, NUL-terminated) */
    float       start_time;    /**< Start time in seconds */
    float       end_time;      /**< End time in seconds */
} PiperPlusPhonemeInfo;

typedef struct PiperPlusTimingResult {
    const PiperPlusPhonemeInfo *entries;  /**< BORROWED: array of timing entries */
    int32_t                     count;    /**< Number of entries */
} PiperPlusTimingResult;

/** Get phoneme timing from the last synthesis.
 *  @lifetime Result is BORROWED; valid until next synthesis call on this engine.
 *  Caller MUST copy entries if persistence is needed. */
PIPER_PLUS_API PiperPlusStatus piper_plus_get_phoneme_timing(
    PiperPlusEngine         *engine,
    PiperPlusTimingResult   *out_timing);

/* ===== G2P / Phonemization (M4-3) ===== */

/**
 * Result of piper_plus_phonemize().
 *
 * @lifetime BORROWED pointers (phonemes, language) are valid until the next
 *   piper_plus_phonemize() or synthesis call on the same engine. Caller MUST
 *   copy strings if persistence is needed.
 */
typedef struct PiperPlusPhonemeResult {
    const char *phonemes;      /**< BORROWED: space-separated IPA phoneme string */
    const char *language;      /**< BORROWED: detected/resolved language code */
    int32_t     num_phonemes;  /**< Number of phoneme tokens */
    int32_t     _reserved[4];  /**< Must be zero -- reserved for future fields */
} PiperPlusPhonemeResult;

/** Phonemize text without synthesis. language=NULL for auto-detect. */
PIPER_PLUS_API PiperPlusStatus piper_plus_phonemize(
    PiperPlusEngine         *engine,
    const char              *text,
    const char              *language,
    PiperPlusPhonemeResult  *out_result);

/** Get available language codes as a comma-separated string (e.g. "en,fr,ja").
 *  @return BORROWED pointer; valid until next call to this function on the
 *          same engine. Returns "" (empty string) on error (NULL engine or
 *          no language map). Caller MUST copy if persistence is needed. */
PIPER_PLUS_API const char *piper_plus_available_languages(PiperPlusEngine *engine);

/* ===== ZH-EN code-switching loanword (Issue #384, TICKET-05 P4) =====
 *
 * Standalone API to phonemize English tokens embedded in Chinese context as
 * Mandarin pinyin. Independent of the synthesis engine — useful for callers
 * (Dart FFI / Godot / Unity) that want to compute the loanword IPA tokens
 * separately from the audio pipeline.
 *
 * Output format: space-separated IPA phoneme string with PUA-mapped tone
 * markers (U+E020..E04A). Caller copies the string if persistence is needed.
 *
 * Lifecycle:
 *   PiperPlusLoanwordHandle *h = piper_plus_loanword_load_default();
 *   if (h) {
 *       PiperPlusPhonemeResult result;
 *       piper_plus_phonemize_embedded_english(h, "GPS", &result);
 *       // result.phonemes valid until the next call on h
 *       piper_plus_loanword_free(h);
 *   }
 */
typedef struct PiperPlusLoanwordHandle PiperPlusLoanwordHandle;

/** Load the bundled default ZH-EN loanword data.
 *  @return Handle on success, NULL on failure (call piper_plus_get_last_error()).
 *  @threading Safe to call concurrently; the underlying default-data init is
 *             single-flight. The returned handles are independent and may be
 *             freed in any order. */
PIPER_PLUS_API PiperPlusLoanwordHandle *piper_plus_loanword_load_default(void);

/** Load loanword data from a custom JSON file path.
 *  @param path  UTF-8 path to a zh_en_loanword.json-shaped file.
 *  @return Handle on success, NULL on failure (call piper_plus_get_last_error()). */
PIPER_PLUS_API PiperPlusLoanwordHandle *piper_plus_loanword_load_from_path(
    const char *path);

/** Free a loanword handle. Safe to pass NULL. */
PIPER_PLUS_API void piper_plus_loanword_free(PiperPlusLoanwordHandle *handle);

/** Phonemize embedded English text using the given loanword data.
 *
 *  Output is written into `out_result` (BORROWED pointers, valid until the
 *  next call on the same handle).
 *
 *  @param handle      Loanword handle from piper_plus_loanword_load_default()
 *                     or piper_plus_loanword_load_from_path().
 *  @param text        UTF-8 input text. Empty / whitespace-only / punctuation
 *                     yields zero phonemes (PIPER_PLUS_OK with num_phonemes=0).
 *  @param out_result  Receives a borrowed pointer to a space-separated IPA
 *                     phoneme string + token count.
 *  @return PIPER_PLUS_OK on success, PIPER_PLUS_ERR on invalid arguments. */
PIPER_PLUS_API PiperPlusStatus piper_plus_phonemize_embedded_english(
    PiperPlusLoanwordHandle *handle,
    const char              *text,
    PiperPlusPhonemeResult  *out_result);

/* ===== Engine-less G2P (Issue #388, Kotlin AAR / Dart FFI / Godot etc.) =====
 *
 * Phonemization without an ONNX model.
 *
 * Use case: callers (e.g. the Kotlin Android G2P AAR) want piper-plus's
 * 8-language G2P (text -> phoneme string) without bundling a synthesis model.
 * This handle uses a built-in language ID map (ja=0, en=1, zh=2, es=3, fr=4,
 * pt=5, ko=6, sv=7) and reuses the same MultilingualPhonemizer pipeline as
 * `piper_plus_phonemize()`, so output is byte-for-byte identical for the
 * shared 8 languages.
 *
 * Lifecycle:
 *   PiperPlusG2pHandle *h = piper_plus_g2p_create(dict_dir_or_null);
 *   if (!h) { fprintf(stderr, "%s", piper_plus_get_last_error()); return 1; }
 *   PiperPlusPhonemeResult result;
 *   piper_plus_g2p_phonemize(h, "Hello world", "en", &result);
 *   // result.phonemes / result.language are BORROWED, valid until the next
 *   // piper_plus_g2p_phonemize() call on the same handle.
 *   piper_plus_g2p_free(h);
 *
 * Threading: per-handle single-threaded. Multiple handles are independent.
 * Note: the underlying OpenJTalk dictionary is selected via global state, so
 * passing different `dict_dir` values to concurrent `_create()` calls is not
 * supported.
 */
typedef struct PiperPlusG2pHandle PiperPlusG2pHandle;

/** Create a G2P handle without an ONNX model.
 *
 *  Uses a built-in language ID map for: en, fr, ja, ko, es, pt, sv, zh.
 *  English/Chinese/Korean/Spanish/French/Portuguese/Swedish all work without
 *  any external dictionary (rules and embedded data are statically linked).
 *  Japanese requires an OpenJTalk dictionary; pass its directory in `dict_dir`
 *  or set the dictionary via the usual auto-detect / `PIPER_OPENJTALK_DICT_DIR`
 *  environment variable mechanism.
 *
 *  CMU / pinyin auxiliary dictionaries (cmudict_data.json, pinyin_single.json,
 *  pinyin_phrases.json) are searched in `dict_dir` first (if non-NULL), then
 *  the `PIPER_DICTIONARIES_PATH` environment variable. The exe-relative
 *  `<exe>/../share/piper/dicts/` branch used by the CLI is intentionally NOT
 *  consulted by the engine-less G2P path because callers (Android AAR, JNI
 *  consumers) have no installed exe to anchor on. When not found,
 *  English/Chinese fall back to the embedded loanword dataset and rule-based
 *  output (still functional).
 *
 *  @param dict_dir  Optional directory containing OpenJTalk and/or CMU/pinyin
 *                   dictionaries. NULL = auto-detect only.
 *  @return Handle on success, NULL on failure (call piper_plus_get_last_error()).
 *  @threading Per-handle single-threaded; multiple handles are independent. */
PIPER_PLUS_API PiperPlusG2pHandle *piper_plus_g2p_create(const char *dict_dir);

/** Free a G2P handle. Safe to pass NULL. */
PIPER_PLUS_API void piper_plus_g2p_free(PiperPlusG2pHandle *handle);

/** Phonemize text without synthesis.
 *
 *  @param handle      Handle from piper_plus_g2p_create().
 *  @param text        UTF-8 input text. NULL or empty yields zero phonemes
 *                     with PIPER_PLUS_OK.
 *  @param language    Language code (e.g. "en", "ja"). NULL or empty enables
 *                     auto-detection via Unicode script analysis.
 *  @param out_result  Receives BORROWED pointers to a space-separated IPA
 *                     phoneme string and the resolved language code. Valid
 *                     until the next piper_plus_g2p_phonemize() call on the
 *                     same handle.
 *  @return PIPER_PLUS_OK on success, error code otherwise. */
PIPER_PLUS_API PiperPlusStatus piper_plus_g2p_phonemize(
    PiperPlusG2pHandle      *handle,
    const char              *text,
    const char              *language,
    PiperPlusPhonemeResult  *out_result);

/** Available language codes as a comma-separated string (e.g.
 *  "en,es,fr,ja,ko,pt,sv,zh"). The returned pointer is BORROWED and valid
 *  until the next call to this function on the same handle. Returns "" on
 *  error (NULL handle). */
PIPER_PLUS_API const char *piper_plus_g2p_available_languages(
    PiperPlusG2pHandle *handle);

/** Load a custom dictionary (JSON v1.0 / v2.0 schema). Replaces any previously
 *  loaded custom dictionary on this handle.
 *
 *  @param handle     Handle from piper_plus_g2p_create().
 *  @param dict_path  UTF-8 path to a custom dictionary JSON file.
 *  @return PIPER_PLUS_OK on success, PIPER_PLUS_ERR on parse/IO failure. */
PIPER_PLUS_API PiperPlusStatus piper_plus_g2p_load_custom_dict(
    PiperPlusG2pHandle *handle,
    const char         *dict_path);

/** Toggle the ZH-EN code-switching dispatch path on this G2P handle.
 *  See piper_plus_set_zh_en_dispatch() for semantics. Default = enabled (1). */
PIPER_PLUS_API PiperPlusStatus piper_plus_g2p_set_zh_en_dispatch(
    PiperPlusG2pHandle *handle,
    int32_t             enabled);

/** Returns 1 if ZH-EN dispatch is enabled, 0 if disabled, -1 on error. */
PIPER_PLUS_API int32_t piper_plus_g2p_is_zh_en_dispatch_enabled(
    const PiperPlusG2pHandle *handle);

/* ===== Speaker Encoder (EXPERIMENTAL -- not yet implemented) ========= */

/**
 * Opaque speaker encoder handle.
 * Wraps an ECAPA-TDNN ONNX model for extracting speaker embeddings.
 *
 * @note EXPERIMENTAL: The speaker encoder API surface is defined for forward
 *       compatibility but the implementation is not yet connected to a backend.
 *       All functions currently return an error or NULL.
 */
typedef struct PiperPlusSpeakerEncoder PiperPlusSpeakerEncoder;

/** Create a speaker encoder from an ONNX model file.
 *  @param model_path  Path to the speaker encoder .onnx file.
 *  @return Handle on success, or NULL on error (see piper_plus_get_last_error()). */
PIPER_PLUS_API PiperPlusSpeakerEncoder* piper_plus_speaker_encoder_create(
    const char *model_path);

/** Encode audio samples into a speaker embedding.
 *  @param encoder        Speaker encoder handle (must not be NULL).
 *  @param audio_samples  Mono float32 PCM audio samples.
 *  @param num_samples    Number of float samples in audio_samples.
 *  @param sample_rate    Sample rate of the input audio (e.g. 16000, 22050, 44100).
 *  @param embedding_out  Output buffer to receive the embedding (caller-allocated).
 *  @param embedding_dim  Size of embedding_out buffer (e.g. 256).
 *  @return Number of embedding dimensions written on success, or -1 on error. */
PIPER_PLUS_API int32_t piper_plus_speaker_encoder_encode(
    PiperPlusSpeakerEncoder *encoder,
    const float *audio_samples,
    int32_t      num_samples,
    int32_t      sample_rate,
    float       *embedding_out,
    int32_t      embedding_dim);

/** Destroy a speaker encoder and release its resources. */
PIPER_PLUS_API void piper_plus_speaker_encoder_destroy(
    PiperPlusSpeakerEncoder *encoder);

#ifdef __cplusplus
}
#endif

#endif /* PIPER_PLUS_H_ */
