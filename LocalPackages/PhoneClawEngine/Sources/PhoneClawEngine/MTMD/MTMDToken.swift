//
//  MTMDToken.swift
//  MiniCPM-V-demo
//
//  Created by AI Assistant on 2024/12/19.
//

import Foundation
import llama

/// MTMD 流式输出 Token
@frozen public struct MTMDToken: Sendable {
    
    /// Token 内容
    public let content: String
    
    /// 是否为结束标记
    public let isEnd: Bool
    
    /// Token 索引（可选）
    public let index: Int?
    
    /// 创建时间戳
    public let timestamp: Date
    
    /// 初始化方法
    /// - Parameters:
    ///   - content: Token 内容
    ///   - isEnd: 是否为结束标记
    ///   - index: Token 索引
    public init(content: String, isEnd: Bool, index: Int? = nil) {
        self.content = content
        self.isEnd = isEnd
        self.index = index
        self.timestamp = Date()
    }
    
    /// 从 C 结构体创建
    /// - Parameter cToken: C 结构体 token
    /// - Returns: Swift Token 对象
    internal static func from(_ cToken: mtmd_ios_token, index: Int? = nil) -> MTMDToken {
        let content = cToken.token != nil ? String(cString: cToken.token) : ""
        return MTMDToken(content: content, isEnd: cToken.is_end, index: index)
    }
    
    /// 空 Token（用于初始化）
    public static let empty = MTMDToken(content: "", isEnd: false)
    
    /// 结束 Token
    public static let end = MTMDToken(content: "", isEnd: true)
}

/// MTMD 生成状态
@frozen public enum MTMDGenerationState: Equatable, Sendable {
    /// 空闲状态
    case idle
    
    /// 生成中
    case generating
    
    /// 生成完成
    case completed
    
    /// 生成失败
    case failed(MTMDError)
    
    /// 已取消
    case cancelled
    
    public static func == (lhs: MTMDGenerationState, rhs: MTMDGenerationState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.generating, .generating),
             (.completed, .completed),
             (.cancelled, .cancelled):
            return true
        case (.failed(let lhsError), .failed(let rhsError)):
            return lhsError.localizedDescription == rhsError.localizedDescription
        default:
            return false
        }
    }
}

/// MTMD 初始化状态
@frozen public enum MTMDInitializationState: Equatable, Sendable {
    /// 未初始化
    case notInitialized
    
    /// 初始化中
    case initializing
    
    /// 初始化完成
    case initialized
    
    /// 初始化失败
    case failed(MTMDError)
    
    public static func == (lhs: MTMDInitializationState, rhs: MTMDInitializationState) -> Bool {
        switch (lhs, rhs) {
        case (.notInitialized, .notInitialized),
             (.initializing, .initializing),
             (.initialized, .initialized):
            return true
        case (.failed(let lhsError), .failed(let rhsError)):
            return lhsError.localizedDescription == rhsError.localizedDescription
        default:
            return false
        }
    }
} 
