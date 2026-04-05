import SwiftUI

// MARK: - Configurations 弹窗（iOS 版，适配 Theme 暖色系）

struct ConfigurationsView: View {
    @Bindable var engine: AgentEngine
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = 0  // 0=Model Configs, 1=System Prompt, 2=Skills

    // 本地编辑状态（确认后才应用）
    @State private var maxTokens: Double = 4000
    @State private var topK: Double = 64
    @State private var topP: Double = 0.95
    @State private var temperature: Double = 1.0
    @State private var systemPrompt: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab 切换
                HStack(spacing: 0) {
                    tabButton("Model Configs", tag: 0)
                    tabButton("System Prompt", tag: 1)
                    tabButton("Skills", tag: 2)
                }
                .padding(.horizontal)

                Rectangle().fill(Theme.border).frame(height: 1)

                Group {
                    if selectedTab == 0 {
                        modelConfigsTab
                    } else if selectedTab == 1 {
                        systemPromptTab
                    } else {
                        skillsTab
                    }
                }

                Rectangle().fill(Theme.border).frame(height: 1)

                // 底部按钮
                HStack(spacing: 20) {
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                    Button("OK") {
                        applySettings()
                        dismiss()
                    }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                    .background(Theme.accent.opacity(0.15), in: Capsule())
                }
                .padding()
            }
            .navigationTitle("Configurations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .background(Theme.bgElevated)
        }
        .preferredColorScheme(.dark)
        .onAppear { loadCurrentSettings() }
    }

    // MARK: - Tab 按钮

    private func tabButton(_ title: String, tag: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { selectedTab = tag }
        } label: {
            VStack(spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(selectedTab == tag ? .semibold : .regular))
                    .foregroundStyle(selectedTab == tag ? Theme.textPrimary : Theme.textTertiary)

                Rectangle()
                    .fill(selectedTab == tag ? Theme.accent : .clear)
                    .frame(height: 2)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Model Configs

    private var modelConfigsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                configSlider(
                    title: "Max Tokens",
                    value: $maxTokens,
                    range: 128...8192,
                    displayValue: "\(Int(maxTokens))"
                )
                configSlider(
                    title: "TopK",
                    value: $topK,
                    range: 1...128,
                    displayValue: "\(Int(topK))"
                )
                configSlider(
                    title: "TopP",
                    value: $topP,
                    range: 0...1,
                    displayValue: String(format: "%.2f", topP)
                )
                configSlider(
                    title: "Temperature",
                    value: $temperature,
                    range: 0...2,
                    displayValue: String(format: "%.2f", temperature)
                )
            }
            .padding()
        }
    }

    // MARK: - System Prompt

    private var systemPromptTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextEditor(text: $systemPrompt)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Theme.border, lineWidth: 1)
                )

            Button("Restore default") {
                systemPrompt = engine.defaultSystemPrompt
            }
            .font(.subheadline)
            .foregroundStyle(Theme.accent)
        }
        .padding()
    }

    // MARK: - Skills Tab

    private var skillsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Header
                HStack {
                    Text("\(engine.skillEntries.filter(\.isEnabled).count)/\(engine.skillEntries.count) enabled")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)

                    Spacer()

                    Button("Enable all") { engine.setAllSkills(enabled: true) }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                    Button("Disable all") { engine.setAllSkills(enabled: false) }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 4)

                // Skill rows
                ForEach(engine.skillEntries.indices, id: \.self) { i in
                    HStack(spacing: 10) {
                        Image(systemName: engine.skillEntries[i].icon)
                            .font(.system(size: 13))
                            .foregroundStyle(engine.skillEntries[i].isEnabled ? Theme.accent : Theme.textTertiary)
                            .frame(width: 28, height: 28)
                            .background(
                                engine.skillEntries[i].isEnabled ? Theme.accentSubtle : Theme.textTertiary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 7)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(engine.skillEntries[i].name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.textPrimary)
                            Text(engine.skillEntries[i].description)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Toggle("", isOn: $engine.skillEntries[i].isEnabled)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding()
        }
    }

    // MARK: - 配置 Slider

    private func configSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        displayValue: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)

            HStack(spacing: 12) {
                Slider(value: value, in: range)
                    .tint(Theme.accent)

                Text(displayValue)
                    .font(.body.monospaced())
                    .foregroundStyle(Theme.textPrimary.opacity(0.8))
                    .frame(width: 56)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    // MARK: - 加载 / 应用

    private func loadCurrentSettings() {
        maxTokens = Double(engine.config.maxTokens)
        topK = Double(engine.config.topK)
        topP = engine.config.topP
        temperature = engine.config.temperature
        systemPrompt = engine.config.systemPrompt
    }

    private func applySettings() {
        engine.config.maxTokens = Int(maxTokens)
        engine.config.topK = Int(topK)
        engine.config.topP = topP
        engine.config.temperature = temperature
        engine.config.systemPrompt = systemPrompt

        // 同步采样参数到 LLM（下次生成立即生效）
        engine.applySamplingConfig()
    }
}
