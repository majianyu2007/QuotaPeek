import SwiftUI
import QuotaCore

private typealias PanelState<Value> = SwiftUI.State<Value>

extension Preferences {
    var colorScheme: ColorScheme? { appearance == "dark" ? .dark : appearance == "light" ? .light : nil }
}

private func quotaColor(_ used: Double, threshold: Int, stale: Bool = false) -> Color {
    if stale { return .secondary }
    if used >= 100 { return .red }
    return used >= Double(threshold) ? .orange : .teal
}

private func ageLabel(_ date: Date, now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    if seconds < 60 { return "刚刚更新" }
    if seconds < 3600 { return "\(seconds / 60) 分钟前" }
    return "\(seconds / 3600) 小时前"
}

struct QuotaPanel: View {
    @ObservedObject var model: AppModel
    let openSettings: () -> Void
    let quit: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @PanelState private var showsInformation = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 9) {
                    Image(systemName: "chart.pie.fill")
                        .font(.system(size: 19)).foregroundStyle(.purple)
                    Text("QuotaPeek").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    if model.refreshing { ProgressView().controlSize(.mini) }
                    Text(model.statusTitle).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                if let error = model.globalError { errorNote(error) }
                if model.configured {
                    profileTabs
                    if let profile = model.selectedProfile {
                        profileDetail(profile, now: context.date)
                    } else {
                        overview(now: context.date)
                    }
                } else {
                    Button(action: openSettings) {
                        Label("添加槽位", systemImage: "plus")
                            .frame(maxWidth: .infinity).padding(.vertical, 32)
                    }.buttonStyle(.borderless).foregroundStyle(.secondary)
                }
                Divider()
                HStack(spacing: 14) {
                    Button { model.refresh() } label: {
                        Label(model.selectedProfile == nil ? "全部刷新" : "刷新", systemImage: "arrow.clockwise")
                    }
                    .disabled(!model.configured || model.saving || (model.selectedProfile.map { !$0.enabled || model.states[$0.id]?.refreshing == true } ?? model.refreshing))
                    .keyboardShortcut("r")
                    Spacer()
                    Button { showsInformation.toggle() } label: {
                        Image(systemName: "info.circle").frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .help("额度说明")
                    .accessibilityLabel("额度说明")
                    .popover(isPresented: $showsInformation, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("各槽位显示其 Key 可见的账号额度，不合计。查看指定 VM 请使用限定该 VM 的 Key；修改名称不会改变查询对象。")
                            Text("更新时间是本机查询时间；服务端可能返回缓存额度。")
                                .foregroundStyle(.secondary)
                            HStack {
                                Spacer()
                                Button("关闭") { showsInformation = false }
                                    .keyboardShortcut(.cancelAction)
                            }
                        }
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(16).frame(width: 280)
                    }
                    Button(action: openSettings) { Image(systemName: "gearshape").frame(width: 22, height: 22) }
                        .help("设置").accessibilityLabel("设置").keyboardShortcut(",")
                    Button(action: quit) { Image(systemName: "power").frame(width: 22, height: 22) }
                        .help("退出").accessibilityLabel("退出")
                }.font(.system(size: 12)).buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            .padding(18).frame(width: 400)
            .background {
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    LinearGradient(colors: [.purple.opacity(colorScheme == .dark ? 0.12 : 0.045), .clear],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
        }
        .preferredColorScheme(model.preferences.colorScheme)
    }

    private var profileTabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                tab("全部", id: nil, icon: "square.grid.2x2")
                ForEach(model.preferences.profiles) { profile in
                    tab(profile.name, id: profile.id, icon: profile.enabled ? "server.rack" : "pause.circle")
                }
                Button(action: openSettings) { Image(systemName: "plus").frame(width: 28, height: 28) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("管理槽位")
            }
        }.scrollIndicators(.hidden)
    }

    private func tab(_ name: String, id: String?, icon: String) -> some View {
        let selected = model.preferences.selectedProfileID == id
        return Button { model.selectProfile(id) } label: {
            Label(name, systemImage: icon)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .lineLimit(1).padding(.horizontal, 11).padding(.vertical, 7)
                .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.75))
                .background(selected ? Color.purple : Color.primary.opacity(0.055), in: Capsule())
        }.buttonStyle(.plain).help(name)
            .accessibilityIdentifier("slot-tab-\(id ?? "all")")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private func profileDetail(_ profile: ConnectionProfile, now: Date) -> some View {
        let state = model.states[profile.id] ?? ProfileState()
        let stale = state.isStale(intervalMinutes: model.preferences.refreshMinutes, now: now) || !profile.enabled
        if !profile.enabled {
            Label("已暂停", systemImage: "pause.circle").font(.callout).foregroundStyle(.secondary)
        }
        if let error = state.error { errorNote(error) }
        if let snapshot = state.snapshot {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(snapshot.windows) { window in
                    QuotaCard(window: window, showRemaining: model.preferences.showRemaining,
                              warningPercent: model.preferences.warningPercent, stale: stale, now: now)
                }
            }
            HStack {
                Text(stale ? "上次数据 · \(ageLabel(snapshot.fetchedAt, now: now))" : ageLabel(snapshot.fetchedAt, now: now))
                Spacer()
                Text(URL(string: profile.baseURL)?.host ?? "")
                    .lineLimit(1).truncationMode(.middle)
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        } else {
            VStack(spacing: 10) {
                if state.refreshing { ProgressView().controlSize(.small) }
                Text(state.refreshing ? "更新中…" : profile.enabled ? "暂无数据" : "暂停查询")
                    .font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(.vertical, 34)
        }
    }

    private func overview(now: Date) -> some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(model.preferences.profiles) { profile in
                    let state = model.states[profile.id] ?? ProfileState()
                    Button { model.selectProfile(profile.id) } label: {
                        SlotSummary(profile: profile, state: state, preferences: model.preferences, now: now)
                    }.buttonStyle(.plain).accessibilityIdentifier("slot-summary-\(profile.id)")
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: min(CGFloat(model.preferences.profiles.count) * 140 - 10, 420))
    }

    private func errorNote(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.system(size: 12)).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.075), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct SlotSummary: View {
    let profile: ConnectionProfile
    let state: ProfileState
    let preferences: Preferences
    let now: Date
    private var stale: Bool { !profile.enabled || state.isStale(intervalMinutes: preferences.refreshMinutes, now: now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "server.rack").foregroundStyle(.purple)
                Text(profile.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                if state.refreshing { ProgressView().controlSize(.mini) }
                Text(!profile.enabled ? "已暂停" : state.error != nil ? "连接异常" : stale ? "已过期" : "")
                    .font(.system(size: 10)).foregroundStyle(state.error == nil ? Color.secondary : .orange)
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            if let snapshot = state.snapshot {
                HStack(spacing: 16) {
                    ForEach(Array(snapshot.windows.prefix(2))) { window in
                        let value = preferences.showRemaining ? 100 - window.usedPercent : window.usedPercent
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(window.title).font(.system(size: 11)).foregroundStyle(.secondary)
                                Spacer(minLength: 2)
                                Text("\(Int(value.rounded()))%")
                                    .font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
                            }
                            ProgressView(value: value, total: 100)
                                .tint(quotaColor(window.usedPercent, threshold: preferences.warningPercent, stale: stale))
                        }.frame(maxWidth: .infinity)
                    }
                }
                HStack {
                    Text(preferences.showRemaining ? "剩余" : "已用")
                    Spacer()
                    Text(ageLabel(snapshot.fetchedAt, now: now))
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Text(state.error ?? (profile.enabled ? "等待更新" : "暂停查询"))
                    .font(.system(size: 12)).foregroundStyle(state.error == nil ? Color.secondary : .orange)
                    .lineLimit(2).frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            }
        }
        .padding(13).frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.065)))
        .opacity(profile.enabled ? 1 : 0.6)
        .help(state.error ?? profile.name)
    }
}

struct QuotaCard: View {
    let window: QuotaWindow
    let showRemaining: Bool
    let warningPercent: Int
    let stale: Bool
    let now: Date
    private var color: Color { quotaColor(window.usedPercent, threshold: warningPercent, stale: stale) }
    private var displayed: Double { showRemaining ? 100 - window.usedPercent : window.usedPercent }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 5) {
                Image(systemName: window.id.contains("seven") ? "calendar" : "clock")
                Text(window.title).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                Circle().fill(color).frame(width: 5, height: 5)
                    .accessibilityLabel(stale ? "过期数据" : window.usedPercent >= 100 ? "耗尽" : "")
            }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(displayed.formatted(.number.precision(.fractionLength(0...1))))
                    .font(.system(size: 29, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("%").font(.system(size: 15)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(showRemaining ? "剩余" : "已用").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.13))
                    Capsule().fill(color.gradient).frame(width: proxy.size.width * displayed / 100)
                }
            }.frame(height: 5)
                .accessibilityLabel("\(window.title)\(showRemaining ? "剩余" : "已用") \(Int(displayed))%")
            Text(resetText).font(.system(size: 10)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
                .help(window.resetsAt?.formatted(date: .complete, time: .shortened) ?? "接口未提供重置时间")
        }
        .padding(13).frame(maxWidth: .infinity, minHeight: 140)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.075)))
    }

    private var resetText: String {
        guard let reset = window.resetsAt else { return "重置时间未知" }
        let minutes = Int(ceil(reset.timeIntervalSince(now) / 60))
        if minutes <= 0 { return "等待重置更新" }
        if minutes < 60 { return "\(minutes) 分钟后重置" }
        if minutes < 1440 { return "\(minutes / 60) 小时 \(minutes % 60) 分钟后重置" }
        return "\(minutes / 1440) 天 \((minutes % 1440) / 60) 小时后重置"
    }
}
