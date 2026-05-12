// CMTMDBridge.h
//
// 纯 C 接口, 把 OpenBMB mtmd-ios C++ API (std::string 等 STL 类型) 包装成
// Swift 可直接调用的 C 入口。
//
// 为什么要这一层:
//   - mtmd-ios.h 是 C++ 头, 含 `std::string`, 把它直接暴露给 Swift 会
//     强制开 Swift/C++ interop (.interoperabilityMode(.Cxx))。
//   - Cxx interop 是病毒性的: MTMDEngine 开了之后, PhoneClaw app target
//     也必须开, app 开了之后 Clang 对 CocoaPods (Yams 等) C 头的模块
//     编译会按 cxx 严格规则跑, 撞 `extern "C"` 里的 `#include <string.h>`
//     直接挂掉。
//   - 解决思路: 把 C++ 边界**收敛**到 CMTMDBridge.cpp 一个文件里, 对外
//     只暴露 C 字符串 + 基础类型, Swift 用普通 C interop 即可。
//
// 调用方:
//   Swift (MTMDEngine target, 无 cxx interop) → CMTMDBridge.h C 接口
//        → CMTMDBridge.cpp (.cxxLanguageStandard) → mtmd-ios.h (C++)
//        → llama.framework 内部实现

#ifndef CMTMDBRIDGE_H
#define CMTMDBRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 不透明上下文句柄。Swift 端拿到只能透传给本文件其它函数, 不可解引用。
typedef struct CMTMDContext CMTMDContext;

/// loop() 返回的单 token 结构。布局跟 mtmd_ios_token 完全一致, .cpp
/// 内部直接 reinterpret_cast / 字段拷贝。
///
/// token 字段是 C 字符串, 调用方拿到后必须用 cmtmd_string_free 释放,
/// 否则泄漏。is_end == true 时是最后一个 token, 之后不要再 loop。
typedef struct {
    char* token;
    bool  is_end;
} CMTMDToken;

/// 初始化上下文。所有路径走 UTF-8 C 字符串, 内部转 std::string。
///
/// - coreml_path: 传 NULL 或空字符串关掉 ANE vision 加速 (fallback 到
///   llama.cpp GPU/CPU vision, 视频场景几乎不可用)。
/// - 返回 NULL 表示初始化失败 (model 文件路径错 / OOM / 不支持的格式)。
///   调用方应 fallback 到错误处理路径, 不要透传 NULL 给其它 cmtmd_* 函数。
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
    int32_t     image_max_slice_nums);

/// 释放上下文。调用后 ctx 不再可用。NULL 安全。
void cmtmd_free(CMTMDContext* ctx);

/// 预填充图片。image_path 是磁盘上的图片文件路径。
/// 返回 0 成功, -1 失败 (用 cmtmd_get_last_error 拿原因)。
int32_t cmtmd_prefill_image(CMTMDContext* ctx, const char* image_path);

/// 同上, 但走"视频帧"路径 — 模型对帧序列做时间维度优化。
int32_t cmtmd_prefill_frame(CMTMDContext* ctx, const char* image_path);

/// 预填充文本。role 通常是 "system" / "user" / "assistant",
/// mtmd_ios 内部按 Qwen3.5 chat template 包装。
int32_t cmtmd_prefill_text(CMTMDContext* ctx, const char* text, const char* role);

/// 单次解码一个 token。阻塞直到生成出来。
///
/// 返回 CMTMDToken: token 是 malloc 的 C 字符串 (用完调
/// cmtmd_string_free), is_end 表示这是最后一个 token。
///
/// 出错时 token = NULL, is_end = true。用 cmtmd_get_last_error 拿错误信息。
CMTMDToken cmtmd_loop(CMTMDContext* ctx);

/// 拿最近一次失败的错误描述。返回值生命周期跟 ctx 同, 不需要 free。
const char* cmtmd_get_last_error(CMTMDContext* ctx);

/// 释放 cmtmd_loop 返回的 token 字符串。NULL 安全。
void cmtmd_string_free(char* str);

/// 清掉 KV cache, 准备开始新对话。保留 ctx, 不重新加载权重。
bool cmtmd_clean_kv_cache(CMTMDContext* ctx);

/// 运行时切换 llava-uhd 风格图片切片数 (MiniCPM-V 1~9, -1 = 模型默认)。
/// 1 最快但丢细节, 9 最清晰但慢。无需 reload mmproj。
void cmtmd_set_image_max_slice_nums(CMTMDContext* ctx, int32_t n);

#ifdef __cplusplus
}
#endif

#endif /* CMTMDBRIDGE_H */
