//
//  MTMDError.swift
//  MiniCPM-V-demo
//
//  Created by AI Assistant on 2024/12/19.
//

import Foundation

/// MTMD 多模态推理错误类型
@frozen public enum MTMDError: Error, LocalizedError, Sendable {
    
    /// 初始化失败
    case initializationFailed(String)
    
    /// 模型路径无效
    case invalidModelPath
    
    /// 图片路径无效
    case invalidImagePath
    
    /// 图片加载失败
    case imageLoadFailed(String)
    
    /// 文本添加失败
    case textAddFailed(String)
    
    /// 推理失败
    case generationFailed(String)
    
    /// 上下文未初始化
    case contextNotInitialized
    
    /// 推理进行中
    case generationInProgress
    
    /// 没有内容可以生成
    case noContentToGenerate
    
    /// 已经初始化
    case alreadyInitialized
    
    /// 正在初始化中
    case alreadyInitializing
    
    /// 内存不足
    case outOfMemory

    /// 调用超时（典型场景：mtmd_ios_prefill_image 内部 ANE/CoreML 阻塞过久）
    case timeout(String)

    /// 未知错误
    case unknown(String)
    
    /// 错误描述
    public var errorDescription: String? {
        switch self {
        case .initializationFailed(let message):
            return "初始化失败: \(message)"
        case .invalidModelPath:
            return "模型路径无效"
        case .invalidImagePath:
            return "图片路径无效"
        case .imageLoadFailed(let message):
            return "图片加载失败: \(message)"
        case .textAddFailed(let message):
            return "文本添加失败: \(message)"
        case .generationFailed(let message):
            return "推理失败: \(message)"
        case .contextNotInitialized:
            return "上下文未初始化，请先调用 initialize 方法"
        case .generationInProgress:
            return "推理正在进行中，请等待完成"
        case .noContentToGenerate:
            return "没有内容可以生成，请先添加图片或文本"
        case .alreadyInitialized:
            return "已经初始化，无需重复初始化"
        case .alreadyInitializing:
            return "正在初始化中，请等待完成"
        case .outOfMemory:
            return "内存不足"
        case .timeout(let message):
            return "调用超时: \(message)"
        case .unknown(let message):
            return "未知错误: \(message)"
        }
    }
} 