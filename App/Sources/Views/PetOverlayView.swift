//
//  PetOverlayView.swift
//  CogniTerm
//
//  终端工具栏里的那只胖鱼，以及它的候选：
//  - 点鱼 → 系统 popover 里的完整气泡
//  - 打字时 → PetAutoPanel 主动展开（窗口内浮层，不抢键盘焦点）
//
//  两个刻意的选择（延续上一版的经验）：
//
//  1. **不往 TerminalView 的交互路径里插东西**。终端的选区、回看、鼠标编码
//     由 SwiftTerm 自己管；行内灰字走单独的「非交互子视图」路线
//     （见 `CogniTerminalView`）。自动面板也是普通 SwiftUI 视图，挂在
//     面板最外层 overlay 上，靠 anchorPreference 钉在鱼身上 —— 不用
//     NSPopover：popover 一旦出现会把 first responder 从终端抢走，
//     用户的下一个键就敲不进 shell 了。
//  2. **不做 ZStack 角落浮层定位宠物**。在 ZStack 里靠 alignment 定位的浮层，
//     一旦内容尺寸变化（气泡展开）就会跟着漂 —— 实测过宠物从右下角跑到半空。
//     放进工具栏 HStack 是确定性布局：它就在那一行里，位置由兄弟视图决定。
//
//  候选项接受 = 把整行写进终端但**不回车**，和对话里代码块的「插入」同语义：
//  决定权始终在人手上。
//

import SwiftUI

struct PetOverlayView: View {

    @ObservedObject var session: TerminalSession

    /// 是否真的被人点过。实测：直接绑 `isExpanded` 时，popover 会在启动
    /// 首帧就自己弹出来（工具栏里的 popover 有过这种表现）。加一道显式
    /// 交互闸门，只有点过才允许呈现。
    @State private var isExpanded = false
    @State private var hasInteracted = false

    // 动画状态：眨眼。尾巴摆动由鱼身体内部自己管。
    @State private var isBlinking = false

    private var input: PetInputBuffer { session.petInput }
    private var suggestions: [PetSuggestion] { session.petSuggestions }

    /// 行内灰字正在显示 = 鱼已经把最好的候选主动递出去了 → 兴奋态。
    private var mood: PetMood {
        session.petGhostSuffix.map { _ in .excited } ?? .idle
    }

    /// 完整气泡正在展示（点鱼触发）。开着时自动面板让位，不叠两层。
    private var popoverPresented: Bool { hasInteracted && isExpanded }

    /// 打字过程中是否该**主动**展开候选面板。判定规则在纯函数
    /// `PetAutoPanelPolicy` 里，视图只负责照做。
    private var autoVisible: Bool {
        PetAutoPanelPolicy.isVisible(
            input: input,
            suggestions: suggestions,
            popoverPresented: popoverPresented,
            dismissed: session.petAutoPanelDismissed
        )
    }

    var body: some View {
        glyph
            .help(hint)
            // 把鱼在面板坐标系里的锚点 + 面板可见性上报给最外层容器，
            // 由它在终端之上渲染自动面板（见 TerminalPaneView.body）。
            .anchorPreference(key: PetPanelPreferenceKey.self, value: .bounds) { anchor in
                PetPanelPreference(anchor: anchor, visible: autoVisible)
            }
            .popover(isPresented: presentation, arrowEdge: .bottom) {
                bubble
            }
            .onChange(of: isExpanded) { _, expanded in
                if !expanded { session.petArmedCommand = nil }
            }
            .task {
                // 眨眼：3 秒左右一次，140ms 闭合。只做有限动画。
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 3_200_000_000)
                    isBlinking = true
                    try? await Task.sleep(nanoseconds: 140_000_000)
                    isBlinking = false
                }
            }
    }

    private var hint: String {
        guard !suggestions.isEmpty else { return "胖鱼：暂时没有可提示的内容" }
        return "胖鱼：\(suggestions.count) 条候选 · 行内灰字按 Tab 或 → 接受"
    }

    /// 呈现闸门：没点过就永远不呈现。
    private var presentation: Binding<Bool> {
        Binding(
            get: { hasInteracted && isExpanded },
            set: { isExpanded = $0 }
        )
    }

    // MARK: 胖鱼

    private var glyph: some View {
        Button {
            hasInteracted = true
            isExpanded.toggle()
        } label: {
            PetBody(mood: mood, isBlinking: isBlinking)
                .overlay(alignment: .topTrailing) {
                    if !isExpanded, !suggestions.isEmpty {
                        Circle()
                            .fill(Color(red: 0.09, green: 0.78, blue: 0.61))
                            .frame(width: 5, height: 5)
                            .offset(x: 3, y: -2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    // MARK: 气泡

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            if suggestions.isEmpty {
                Text("先敲点什么，或者跟 agent 聊两句。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
            } else {
                ForEach(suggestions) { suggestion in
                    PetSuggestionRow(
                        suggestion: suggestion,
                        armed: session.petArmedCommand == suggestion.command,
                        isGhost: isGhost(suggestion),
                        onAccept: { accept(suggestion) }
                    )
                }
                footnote
            }
        }
        .frame(width: 340, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(input.isEmpty ? "要跑点什么？" : "接着打…")
                .font(.caption.weight(.medium))
            Spacer(minLength: 6)
            if case .stale(let reason) = input.confidence {
                // 不偷偷降级：先说清为什么现在只给「常用」不给「按你打的补」。
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var footnote: some View {
        HStack(spacing: 6) {
            Text("行内灰字 Tab / → 接受 · 点击只键入、不回车")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 6)
            if !input.isEmpty, input.confidence.isExact {
                Text(input.text)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// 这条候选是否正是行内灰字补的那一条（list 和灰字由此对得上号）。
    private func isGhost(_ suggestion: PetSuggestion) -> Bool {
        guard let suffix = session.petGhostSuffix, !suffix.isEmpty else { return false }
        return suggestion.command == input.text + suffix
    }

    // MARK: 动作

    private func accept(_ suggestion: PetSuggestion) {
        session.acceptPetSuggestion(suggestion)
        // 风险命令第一次点击只武装（armed 仍非空），气泡保持打开；
        // 真的键入了（armed 被清空）才关气泡。
        if session.petArmedCommand == nil { isExpanded = false }
    }
}

// MARK: - 共享候选行

/// 气泡和自动面板共用的一行候选。三处信息位：命令本体 / 风险标 /
/// 「Tab」灰字标 / 来源标。
struct PetSuggestionRow: View {

    let suggestion: PetSuggestion
    let armed: Bool
    /// 正是行内灰字给出的那一条：打个 Tab 小标，把列表和灰字关联起来。
    let isGhost: Bool
    let onAccept: () -> Void

    var body: some View {
        Button(action: onAccept) {
            HStack(spacing: 7) {
                Text(suggestion.command)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(suggestion.isRisky ? Color.orange : Color.primary)
                Spacer(minLength: 6)
                if suggestion.isRisky {
                    Text(armed ? "再点一次" : "有风险")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                } else if isGhost {
                    Text("Tab")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color(red: 0.09, green: 0.78, blue: 0.61).opacity(0.16)))
                        .foregroundStyle(Color(red: 0.05, green: 0.55, blue: 0.44))
                } else {
                    Text(suggestion.source.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(armed ? Color.orange.opacity(0.15) : Color.clear)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 主动展开的候选面板

/// 打字时主动展开的候选列表。它是**窗口内普通 SwiftUI 视图**，不是
/// NSPopover —— 这样键盘焦点始终留在终端里，用户可以一边看着列表一边
/// 继续打字（接受走 Tab / →，鼠标点击是辅助路径）。
struct PetAutoPanel: View {

    let suggestions: [PetSuggestion]
    /// 行内灰字对应的完整命令（nil = 当前没有灰字）。
    let ghostCommand: String?
    let armedCommand: String?
    let onAccept: (PetSuggestion) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("胖鱼建议")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("继续打字忽略 · Tab / → 接受灰字")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 6)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .padding(.vertical, 6)

            Divider().opacity(0.4)

            ForEach(suggestions) { suggestion in
                PetSuggestionRow(
                    suggestion: suggestion,
                    armed: armedCommand == suggestion.command,
                    isGhost: suggestion.command == ghostCommand,
                    onAccept: { onAccept(suggestion) }
                )
            }
        }
        .frame(width: 320, alignment: .leading)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.28), radius: 7, x: 0, y: 3)
    }
}

/// 鱼身锚点 + 自动面板可见性，从工具栏里的鱼上报给最外层容器。
struct PetPanelPreference: Equatable {
    var anchor: Anchor<CGRect>?
    var visible: Bool
}

struct PetPanelPreferenceKey: PreferenceKey {
    static let defaultValue = PetPanelPreference(anchor: nil, visible: false)

    static func reduce(value: inout PetPanelPreference, nextValue: () -> PetPanelPreference) {
        let next = nextValue()
        // 全树只有鱼一个上报方；有锚点就采用，可见性以最新值为准。
        if let anchor = next.anchor { value.anchor = anchor }
        value.visible = next.visible
    }
}

/// 鱼的情绪。决定眼睛、尾巴节奏和泡泡 —— 可爱来自「它对发生的事有反应」，
/// 不是来自更复杂的静态轮廓。
enum PetMood {
    case idle
    case excited
}

/// 一只圆滚滚的薄荷绿胖鱼：椭圆身体 + 浅肚皮 + 扇尾 + 两只大眼 + 腮红。
/// 全部用 SwiftUI 形状拼，不引任何资源，随主题色走。
///
/// 刻意**不用 GeometryReader**：它没有固有尺寸、会吃掉全部可用空间，
/// 放进工具栏的 HStack 里会把按钮撑开（老版踩过一次）。尺寸写死成常量。
private struct PetBody: View {
    let mood: PetMood
    let isBlinking: Bool

    @State private var tailWag = false

    private static let mint = Color(red: 0.36, green: 1.0, blue: 0.87)
    private static let deepMint = Color(red: 0.09, green: 0.78, blue: 0.61)
    private static let belly = Color(white: 1.0).opacity(0.82)
    private static let ink = Color(white: 0.09)
    private static let blush = Color(red: 1.0, green: 0.56, blue: 0.69)

    var body: some View {
        ZStack {
            tail
            bubble
            fin
            torso
            face
        }
        .frame(width: 28, height: 24)
        // 兴奋时轻轻「浮」一下，落点是持续的 1.5pt 抬升 + 一次弹簧入场。
        .offset(y: mood == .excited ? -1.5 : 0)
        .animation(.spring(response: 0.34, dampingFraction: 0.38), value: mood)
        .task(id: mood) { await wagLoop() }
    }

    // MARK: 零件

    private var tail: some View {
        // 两片小扇叶，根部藏在身体轮廓后面，绕身体侧的枢轴整体摆动。
        ZStack {
            Capsule()
                .fill(Self.deepMint)
                .frame(width: 3.2, height: 6.5)
                .rotationEffect(.degrees(-42))
                .offset(x: 9, y: -3)
            Capsule()
                .fill(Self.deepMint)
                .frame(width: 3.2, height: 6.5)
                .rotationEffect(.degrees(42))
                .offset(x: 9, y: 3)
        }
        .rotationEffect(.degrees(tailWag ? -13 : 11), anchor: UnitPoint(x: 0.25, y: 0.5))
        .animation(.easeInOut(duration: 0.17), value: tailWag)
    }

    private var fin: some View {
        // 背上的小鳍。
        Triangle()
            .fill(Self.deepMint.opacity(0.85))
            .frame(width: 8, height: 6)
            .offset(x: -1, y: -10.5)
    }

    private var torso: some View {
        ZStack {
            Ellipse()
                .fill(
                    LinearGradient(
                        colors: [Self.mint, Self.deepMint],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 21, height: 17)
                .overlay(
                    Ellipse()
                        .strokeBorder(Color.black.opacity(0.18), lineWidth: 0.8)
                )
            // 肚皮
            Ellipse()
                .fill(Self.belly)
                .frame(width: 13, height: 7.5)
                .offset(y: 4.5)
            // 28pt 下不再画胸鳍：试过，它和右腮红挤成一个糊点。
            // 扇尾 + 背鳍 + 肚皮已经足够把物种说清楚。
        }
    }

    @ViewBuilder
    private var face: some View {
        // 腮红
        HStack(spacing: 8.5) {
            Circle().fill(Self.blush.opacity(0.55)).frame(width: 2.6, height: 2.6)
            Circle().fill(Self.blush.opacity(0.55)).frame(width: 2.6, height: 2.6)
        }
        .offset(y: 3.4)

        if mood == .excited {
            // 笑眼 ＾ ＾
            HStack(spacing: 5.5) {
                happyEye
                happyEye
            }
            .offset(y: -1)
        } else {
            // 普通大眼；眨眼时压成一条缝。
            HStack(spacing: 5.5) {
                eye
                eye
            }
            .offset(y: -1)
        }

        // 小嘴：兴奋时张成一个小椭圆。
        if mood == .excited {
            Ellipse()
                .fill(Self.ink)
                .frame(width: 3, height: 2.2)
                .offset(y: 3.6)
        } else {
            SmileShape()
                .stroke(Self.ink, style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
                .frame(width: 4.2, height: 2)
                .offset(y: 3.4)
        }
    }

    private var eye: some View {
        ZStack {
            Circle()
                .fill(Color.white)
                .frame(width: 5.6, height: isBlinking ? 1.1 : 5.6)
            if !isBlinking {
                Circle()
                    .fill(Self.ink)
                    .frame(width: 3.4, height: 3.4)
                Circle()
                    .fill(Color.white)
                    .frame(width: 1.1, height: 1.1)
                    .offset(x: 0.9, y: -0.9)
            }
        }
        .frame(width: 5.6, height: 5.6)
        .animation(.easeOut(duration: 0.09), value: isBlinking)
    }

    private var happyEye: some View {
        // 倒弧 ＾
        Path { p in
            p.move(to: CGPoint(x: 0, y: 2))
            p.addQuadCurve(to: CGPoint(x: 4.4, y: 2), control: CGPoint(x: 2.2, y: -2))
        }
        .stroke(Self.ink, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        .frame(width: 4.4, height: 3.2)
    }

    private var bubble: some View {
        // 兴奋时在头顶吐出两个泡泡。
        ZStack {
            Circle()
                .strokeBorder(Self.mint.opacity(0.9), lineWidth: 1)
                .frame(width: 3.2, height: 3.2)
                .offset(x: 10.5, y: -10.5)
            Circle()
                .strokeBorder(Self.mint.opacity(0.7), lineWidth: 0.8)
                .frame(width: 2, height: 2)
                .offset(x: 7, y: -13)
        }
        .opacity(mood == .excited ? 1 : 0)
        .scaleEffect(mood == .excited ? 1 : 0.3, anchor: .bottomTrailing)
        .animation(.spring(response: 0.3, dampingFraction: 0.45), value: mood)
    }

    /// 有限的摆尾节奏：不使用 repeatForever 隐式动画 —— 老版实测它会让
    /// 工具栏这层一直挂着陈旧几何导致宠物漂移。这里由 Task 驱动状态翻转，
    /// 每次都是有起止的有限动画；兴奋时节奏更快。
    private func wagLoop() async {
        while !Task.isCancelled {
            let pause: UInt64 = mood == .excited ? 1_500_000_000 : 5_200_000_000
            try? await Task.sleep(nanoseconds: pause)
            guard !Task.isCancelled else { return }
            tailWag = true
            try? await Task.sleep(nanoseconds: 170_000_000)
            tailWag = false
            try? await Task.sleep(nanoseconds: 120_000_000)
            tailWag = true
            try? await Task.sleep(nanoseconds: 170_000_000)
            tailWag = false
        }
    }
}

/// 背鳍用的小圆角三角。
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.maxY),
                control: CGPoint(x: rect.midX, y: rect.minY - 1)
            )
            p.closeSubpath()
        }
    }
}

/// 微笑弧。
private struct SmileShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.minY),
                control: CGPoint(x: rect.midX, y: rect.maxY)
            )
        }
    }
}
