import SwiftUI
import QuotaCore

// Use the property wrapper on SDKs that also expose a same-named State macro.
private typealias ViewState<Value> = SwiftUI.State<Value>

struct SettingsView: View {
    @ObservedObject var model: AppModel
    let showQuota: () -> Void
    @ViewState private var editingID: String?
    @ViewState private var profile = ConnectionProfile()
    @ViewState private var originalProfile = ConnectionProfile()
    @ViewState private var key = ""
    @ViewState private var originalKey = ""
    @ViewState private var general = false
    @ViewState private var preferences = Preferences()
    @ViewState private var originalPreferences = Preferences()
    @ViewState private var saved = false
    @ViewState private var deleteConfirmation = false
    @ViewState private var discardConfirmation = false
    @ViewState private var pending: Destination?
    private enum Destination { case profile(String), new, general }

    private var dirty: Bool {
        general ? preferences != originalPreferences : profile != originalProfile || key != originalKey
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(general ? "通用" : editingID == nil ? "添加槽位" : profile.name)
                        .font(.system(size: 19, weight: .semibold)).lineLimit(1)
                    Spacer()
                    if !general, editingID != nil {
                        Button(role: .destructive) { deleteConfirmation = true } label: {
                            Image(systemName: "trash")
                        }.buttonStyle(.borderless).help("删除槽位").accessibilityLabel("删除槽位")
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if general { generalForm } else { connectionForm }
                        if let error = model.globalError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let message = model.settingsMessage {
                            Label(message, systemImage: saved ? "checkmark.circle" : "info.circle")
                                .font(.callout).foregroundStyle(saved ? Color.teal : .orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("connectionResult")
                        }
                    }.padding(.trailing, 3)
                }.scrollIndicators(.hidden)
                Spacer(minLength: 0)
                HStack {
                    if model.saving { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("完成", action: showQuota).disabled(dirty || model.saving || !model.configured)
                    Button(general ? "保存" : "验证并保存") { save() }
                        .buttonStyle(.borderedProminent).tint(.purple)
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.saving || (!general && (profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)))
                        .accessibilityIdentifier("saveConnection")
                }
            }
            .padding(24).frame(maxWidth: .infinity)
            .disabled(model.saving)
        }
        .frame(width: 650, height: 510)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(general ? preferences.colorScheme : model.preferences.colorScheme)
        .onAppear {
            if let id = model.selectedProfile?.id ?? model.preferences.profiles.first?.id { load(.profile(id)) }
            else { load(.new) }
        }
        .onChange(of: profile) { saved = false }
        .onChange(of: key) { saved = false }
        .onChange(of: preferences) { saved = false }
        .confirmationDialog("删除这个槽位？", isPresented: $deleteConfirmation) {
            Button("删除", role: .destructive) {
                if let id = editingID, model.deleteProfile(id: id) {
                    if let next = model.preferences.profiles.first { load(.profile(next.id)) }
                    else { load(.new) }
                }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("只删除本机连接与 Key。") }
        .confirmationDialog("放弃未保存的修改？", isPresented: $discardConfirmation) {
            Button("放弃修改", role: .destructive) {
                if let destination = pending { load(destination) }
                pending = nil
            }
            Button("继续编辑", role: .cancel) { pending = nil }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("槽位").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { navigate(.new) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help("添加槽位").accessibilityLabel("添加槽位")
                    .accessibilityIdentifier("addProfile")
            }.padding(.horizontal, 12)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(model.preferences.profiles) { item in
                        Button { navigate(.profile(item.id)) } label: {
                            HStack(spacing: 7) {
                                Image(systemName: item.enabled ? "server.rack" : "pause.circle")
                                    .foregroundStyle(.secondary)
                                Text(item.name).lineLimit(1)
                                Spacer(minLength: 0)
                                if model.states[item.id]?.error != nil {
                                    Image(systemName: "exclamationmark.circle.fill").font(.caption).foregroundStyle(.orange)
                                }
                            }
                            .font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 10)
                            .background(!general && editingID == item.id ? Color.purple.opacity(0.13) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).help(item.name).accessibilityIdentifier("edit-profile-\(item.id)")
                    }
                    if editingID == nil && !general {
                        Label("新槽位", systemImage: "plus.circle")
                            .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10).background(.purple.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
                    }
                }.padding(.horizontal, 6)
            }.scrollIndicators(.hidden)
            if let id = editingID, !general, let index = model.preferences.profiles.firstIndex(where: { $0.id == id }) {
                HStack(spacing: 16) {
                    Button { model.moveProfile(id: id, offset: -1) } label: { Image(systemName: "arrow.up") }
                        .disabled(index == 0).help("上移").accessibilityLabel("上移")
                    Button { model.moveProfile(id: id, offset: 1) } label: { Image(systemName: "arrow.down") }
                        .disabled(index == model.preferences.profiles.count - 1).help("下移").accessibilityLabel("下移")
                }.buttonStyle(.borderless).foregroundStyle(.secondary).padding(.horizontal, 14)
            }
            Divider()
            Button { navigate(.general) } label: {
                Label("通用", systemImage: "gearshape")
                    .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .background(general ? Color.purple.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).padding(.horizontal, 6).accessibilityIdentifier("generalSettings")
        }
        .padding(.vertical, 16).frame(width: 170)
        .background(Color.primary.opacity(0.025))
        .disabled(model.saving)
    }

    private var connectionForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            field("名称") {
                TextField("vm-01", text: $profile.name).accessibilityIdentifier("profileName")
            }
            field("API 地址") {
                TextField("https://api.example.com", text: $profile.baseURL)
                    .textContentType(.URL).accessibilityIdentifier("baseURL")
                    .help("支持根地址、/v1 或完整 /v1/usage。")
            }
            field("API Key") {
                SecureField("sk-…", text: $key).accessibilityIdentifier("apiKey")
                    .help("保存在本机钥匙串。查询特定 VM 请使用限定该 VM 的 Key，名称不改变服务端路由。")
            }
            Toggle("启用", isOn: Binding(get: { profile.enabled }, set: { enabled in
                if let id = editingID {
                    model.setProfileEnabled(id: id, enabled: enabled)
                    if let stored = model.preferences.profiles.first(where: { $0.id == id }) {
                        profile.enabled = stored.enabled
                        originalProfile.enabled = stored.enabled
                    }
                } else { profile.enabled = enabled }
            })).font(.callout)
                .help("立即生效。暂停后不自动查询，也不参与菜单栏汇总和提醒。")
        }.textFieldStyle(.roundedBorder).controlSize(.large)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            content()
        }
    }

    private var generalForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("自动刷新", selection: $preferences.refreshMinutes) {
                ForEach([1, 2, 5, 15, 30], id: \.self) { Text("每 \($0) 分钟").tag($0) }
            }
            Picker("额度显示", selection: $preferences.showRemaining) {
                Text("剩余").tag(true)
                Text("已用").tag(false)
            }
            Picker("菜单栏", selection: $preferences.menuBarMode) {
                Text("当前槽位").tag("selected")
                Text("最紧张槽位").tag("tightest")
            }
            Toggle("菜单栏显示槽位名称", isOn: $preferences.showProfileName)
            Picker("外观", selection: $preferences.appearance) {
                Text("跟随系统").tag("system")
                Text("浅色").tag("light")
                Text("深色").tag("dark")
            }
            Divider()
            Toggle("额度提醒", isOn: $preferences.notifications)
            if preferences.notifications {
                Picker("已用达到", selection: $preferences.warningPercent) {
                    ForEach([50, 60, 70, 80, 90, 95], id: \.self) { Text("\($0)%").tag($0) }
                }
            }
            Toggle("登录时启动", isOn: Binding(get: { model.loginEnabled }, set: { model.setLoginEnabled($0) }))
                .help("立即生效。其他设置保存后生效。")
        }.font(.callout)
    }

    private func navigate(_ destination: Destination) {
        guard !model.saving else { return }
        if case .profile(let id) = destination, id == editingID, !general { return }
        if case .general = destination, general { return }
        if dirty { pending = destination; discardConfirmation = true }
        else { load(destination) }
    }

    private func load(_ destination: Destination) {
        saved = false
        model.clearSettingsMessage()
        switch destination {
        case .general:
            general = true
            preferences = model.preferences
            originalPreferences = preferences
        case .profile(let id):
            guard let existing = model.preferences.profiles.first(where: { $0.id == id }) else { return }
            general = false
            editingID = id
            profile = existing
            key = model.savedKey(for: id)
            originalProfile = profile
            originalKey = key
        case .new:
            let baseURL = model.preferences.profiles.first(where: { $0.id == editingID })?.baseURL
                ?? model.preferences.profiles.first?.baseURL ?? ""
            var number = 1
            let names = Set(model.preferences.profiles.map(\.name))
            while names.contains(String(format: "vm-%02d", number)) { number += 1 }
            general = false
            editingID = nil
            profile = ConnectionProfile(name: String(format: "vm-%02d", number), baseURL: baseURL)
            originalProfile = profile
            key = ""
            originalKey = ""
        }
    }

    private func save() {
        guard !model.saving else { return }
        saved = false
        Task {
            if general {
                saved = await model.savePreferences(preferences)
                if saved { preferences = model.preferences; originalPreferences = preferences }
            } else {
                saved = await model.upsertProfile(profile, key: key)
                if saved {
                    editingID = profile.id
                    if let stored = model.preferences.profiles.first(where: { $0.id == profile.id }) { profile = stored }
                    originalProfile = profile
                    originalKey = key
                }
            }
        }
    }
}
