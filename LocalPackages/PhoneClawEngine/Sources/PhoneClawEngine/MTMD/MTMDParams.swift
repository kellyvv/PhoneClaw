//
//  MTMDParams.swift
//  MiniCPM-V-demo
//
//  Created by AI Assistant on 2024/12/19.
//

import Foundation
import llama

/// MTMD 参数配置
@frozen public struct MTMDParams: Sendable {
    
    /// 模型路径
    public let modelPath: String
    
    /// 多模态投影模型路径
    public let mmprojPath: String
    
    /// CoreML 模型路径（用于 ANE 加速）
    public let coremlPath: String
    
    /// 预测长度
    public let nPredict: Int
    
    /// 上下文长度
    public let nCtx: Int
    
    /// 线程数
    public let nThreads: Int
    
    /// 温度参数
    public let temperature: Float
    
    /// 是否使用 GPU
    public let useGPU: Bool
    
    /// 多模态投影是否使用 GPU
    public let mmprojUseGPU: Bool
    
    /// 是否预热
    public let warmup: Bool

    /// 单张图最大切片数（仅对 llava-uhd 风格模型生效，例如 MiniCPM-V）。
    /// - `-1`：按模型默认（MiniCPM-V 当前 9 片）
    /// - `1`：不切图（仅 overview，~9× 更少图像 token，速度最快但丢细节）
    /// - `2..9`：用户在对话页用滑条选的档位
    public let imageMaxSliceNums: Int
    
    /// 初始化方法
    /// - Parameters:
    ///   - modelPath: 模型路径
    ///   - mmprojPath: 多模态投影模型路径
    ///   - coremlPath: CoreML 模型路径，默认为空（不使用 ANE 加速）
    ///   - nPredict: 预测长度，默认 100
    ///   - nCtx: 上下文长度，默认 4096（V2.6 / V4.0 用此默认，避免高 KV 内存压力）。
    ///     V4.6 视频路径调用方应显式传入 8192：v46 在 slice=1 下每帧编码
    ///     ~64 visual tokens，64 帧 × 64 = 4096 token 恰好顶死 4096 上下文，
    ///     再叠加 system prompt + chat template wrapper 必然溢出 KV cache。
    ///     v46 模型本身 max_position_embeddings ≥ 32K，远高于 8192；
    ///     KV 多占约 270 MB，iPhone 14 Pro 及以上完全 hold 得住。
    ///   - nThreads: 线程数，默认 4
    ///   - temperature: 温度参数，默认 0.7（对齐模型 generation_config.json：
    ///     do_sample=true, temperature=0.7, top_k=0, top_p=1.0, repetition_penalty=1.0；
    ///     top_k 与 top_p 由 mtmd-ios.cpp 内部统一设为禁用值，纯温度采样）
    ///   - useGPU: 是否使用 GPU，默认 false
    ///   - mmprojUseGPU: 多模态投影是否使用 GPU，默认 false
    ///   - warmup: 是否预热，默认 true
    ///   - imageMaxSliceNums: 单张图最大切片数，默认 9（MiniCPM-V 自身上限，"开启大图"模式）。用户可在对话页用滑条往下调到 1（不切图，最快）。
    public init(
        modelPath: String,
        mmprojPath: String,
        coremlPath: String = "",
        nPredict: Int = 100,
        nCtx: Int = 4096,
        nThreads: Int = 4,
        temperature: Float = 0.7,
        useGPU: Bool = true,
        mmprojUseGPU: Bool = true,
        warmup: Bool = true,
        imageMaxSliceNums: Int = 9
    ) {
        self.modelPath = modelPath
        self.mmprojPath = mmprojPath
        self.coremlPath = coremlPath
        self.nPredict = nPredict
        self.nCtx = nCtx
        self.nThreads = nThreads
        self.temperature = temperature
        self.useGPU = useGPU
        self.mmprojUseGPU = mmprojUseGPU
        self.warmup = warmup
        self.imageMaxSliceNums = imageMaxSliceNums
    }
    
    /// 创建默认参数
    /// - Parameters:
    ///   - modelPath: 模型路径
    ///   - mmprojPath: 多模态投影模型路径
    /// - Returns: 默认参数配置
    public static func `default`(modelPath: String, mmprojPath: String, coremlPath: String = "") -> MTMDParams {
        return MTMDParams(
            modelPath: modelPath,
            mmprojPath: mmprojPath,
            coremlPath: coremlPath
        )
    }
    
    /// 转换为 C 结构体
    internal func toCParams() -> mtmd_ios_params {
        var params = mtmd_ios_params_default()
        params.model_path = std.string(modelPath)
        params.mmproj_path = std.string(mmprojPath)
        params.coreml_path = std.string(coremlPath)
        params.n_predict = Int32(nPredict)
        params.n_ctx = Int32(nCtx)
        params.n_threads = Int32(nThreads)
        params.temperature = temperature
        params.use_gpu = useGPU
        params.mmproj_use_gpu = mmprojUseGPU
        params.warmup = warmup
        params.image_max_slice_nums = Int32(imageMaxSliceNums)
        return params
    }
} 
