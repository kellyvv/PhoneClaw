// CMTMDBridge.cpp
//
// C++ → C 转换层。把 OpenBMB mtmd-ios C++ API 包装成 CMTMDBridge.h 里
// 声明的纯 C 接口。
//
// 见 include/CMTMDBridge.h 顶部注释了解为什么需要这层桥接。

#include "CMTMDBridge.h"

#include <cstdlib>
#include <cstring>
#include <string>

// llama.framework 的 C++ 子模块 — 只在编译此 .cpp 时被引入,
// 不会泄漏到对外暴露的 .h。
#include <llama/mtmd-ios.h>

extern "C" {

// 内部 helper: 把 nullable C-string 转成 std::string (NULL → "")。
static inline std::string c2s(const char* s) {
    return s ? std::string(s) : std::string();
}

CMTMDContext* cmtmd_init(
    const char* model_path,
    const char* mmproj_path,
    const char* coreml_path,
    int32_t     n_predict,
    int32_t     n_ctx,
    int32_t     n_threads,
    float       temperature,
    bool        use_gpu,
    bool        mmproj_use_gpu,
    bool        warmup,
    int32_t     image_max_slice_nums) {

    mtmd_ios_params params = mtmd_ios_params_default();
    params.model_path           = c2s(model_path);
    params.mmproj_path          = c2s(mmproj_path);
    params.coreml_path          = c2s(coreml_path);
    params.n_predict            = n_predict;
    params.n_ctx                = n_ctx;
    params.n_threads            = n_threads;
    params.temperature          = temperature;
    params.use_gpu              = use_gpu;
    params.mmproj_use_gpu       = mmproj_use_gpu;
    params.warmup               = warmup;
    params.image_max_slice_nums = image_max_slice_nums;

    mtmd_ios_context* ctx = mtmd_ios_init(&params);
    return reinterpret_cast<CMTMDContext*>(ctx);
}

void cmtmd_free(CMTMDContext* ctx) {
    if (!ctx) return;
    mtmd_ios_free(reinterpret_cast<mtmd_ios_context*>(ctx));
}

int32_t cmtmd_prefill_image(CMTMDContext* ctx, const char* image_path) {
    if (!ctx) return -1;
    return mtmd_ios_prefill_image(reinterpret_cast<mtmd_ios_context*>(ctx), c2s(image_path));
}

int32_t cmtmd_prefill_frame(CMTMDContext* ctx, const char* image_path) {
    if (!ctx) return -1;
    return mtmd_ios_prefill_frame(reinterpret_cast<mtmd_ios_context*>(ctx), c2s(image_path));
}

int32_t cmtmd_prefill_text(CMTMDContext* ctx, const char* text, const char* role) {
    if (!ctx) return -1;
    return mtmd_ios_prefill_text(reinterpret_cast<mtmd_ios_context*>(ctx), c2s(text), c2s(role));
}

CMTMDToken cmtmd_loop(CMTMDContext* ctx) {
    CMTMDToken result = { nullptr, true };
    if (!ctx) return result;

    mtmd_ios_token raw = mtmd_ios_loop(reinterpret_cast<mtmd_ios_context*>(ctx));

    // mtmd_ios_token.token 来源:
    //   - 上游 mtmd-ios.cpp 用 strdup() 返回, 调用方负责释放。
    //   - Swift 端通过 cmtmd_string_free 释放, 内部就是 free()。
    // 我们直接透传指针, 不做拷贝。
    result.token  = raw.token;
    result.is_end = raw.is_end;
    return result;
}

const char* cmtmd_get_last_error(CMTMDContext* ctx) {
    if (!ctx) return "ctx is null";
    return mtmd_ios_get_last_error(reinterpret_cast<mtmd_ios_context*>(ctx));
}

void cmtmd_string_free(char* str) {
    if (!str) return;
    // 直接走 mtmd_ios_string_free 让上游决定释放器 (free / delete[] 都可能)。
    mtmd_ios_string_free(str);
}

bool cmtmd_clean_kv_cache(CMTMDContext* ctx) {
    if (!ctx) return false;
    return mtmd_ios_clean_kv_cache(reinterpret_cast<mtmd_ios_context*>(ctx));
}

void cmtmd_set_image_max_slice_nums(CMTMDContext* ctx, int32_t n) {
    if (!ctx) return;
    mtmd_ios_set_image_max_slice_nums(reinterpret_cast<mtmd_ios_context*>(ctx), n);
}

} // extern "C"
