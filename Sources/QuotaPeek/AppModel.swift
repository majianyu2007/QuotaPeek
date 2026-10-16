import AppKit
import Combine
import QuotaCore
import ServiceManagement
import UserNotifications

struct ProfileState {
    var snapshot: QuotaSnapshot?
    var refreshing = false
    var error: String?
    var lastAttempt: Date?

    init() {}

    func isStale(intervalMinutes: Int, now: Date = Date()) -> Bool {
        guard let snapshot else { return false }
        return error != nil || now.timeIntervalSince(snapshot.fetchedAt) > Double(max(1, intervalMinutes)) * 120
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var preferences = Preferences()
    @Published private(set) var states: [String: ProfileState] = [:]
    @Published private(set) var saving = false
    @Published private(set) var settingsMessage: String?
    @Published private(set) var globalError: String?
    @Published private(set) var loginEnabled = SMAppService.mainApp.status == .enabled
    var onChange: (() -> Void)?

    private var apiKeys: [String: String] = [:]
    private var refreshTasks: [String: Task<Void, Never>] = [:]
    private var requestTokens: [String: UUID] = [:]
    private var refreshQueue: [String] = []
    private var connectionWaiter: CheckedContinuation<Void, Never>?
    private var configurationLoaded = false
    private var storageRecoveryRequired = false
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?

    private struct NotificationWindow: Hashable {
        let id: String
        let resetsAt: Date?
    }
    private var notifiedWindows: [String: Set<NotificationWindow>] = [:]
    private var notificationRequests: [String: [NotificationWindow: String]] = [:]

    var selectedProfile: ConnectionProfile? {
        guard let id = preferences.selectedProfileID else { return nil }
        return preferences.profiles.first { $0.id == id }
    }
    var configured: Bool { !preferences.profiles.isEmpty }
    var refreshing: Bool { states.values.contains { $0.refreshing } }

    private func mostUsed(for id: String) -> QuotaWindow? {
        states[id]?.snapshot?.windows.max { $0.usedPercent < $1.usedPercent }
    }

    /// An overview compares individual windows, never sums unrelated quotas or uses failed/stale data.
    private var tightestProfile: (profile: ConnectionProfile, window: QuotaWindow)? {
        var result: (profile: ConnectionProfile, window: QuotaWindow)?
        for profile in preferences.profiles where profile.enabled {
            guard let state = states[profile.id], state.error == nil,
                  !state.isStale(intervalMinutes: preferences.refreshMinutes),
                  let window = mostUsed(for: profile.id) else { continue }
            if result == nil || window.usedPercent > result!.window.usedPercent {
                result = (profile, window)
            }
        }
        return result
    }

    private var hasProfileIssues: Bool {
        preferences.profiles.contains { profile in
            guard profile.enabled, let state = states[profile.id] else { return false }
            return state.error != nil || state.isStale(intervalMinutes: preferences.refreshMinutes)
        }
    }

    var statusTitle: String {
        if globalError != nil { return "配置异常" }
        guard configured else { return "待配置" }
        if let profile = selectedProfile {
            guard profile.enabled else { return "已暂停" }
            let state = states[profile.id]
            if state?.error != nil { return state?.snapshot == nil ? "连接异常" : "数据已过期" }
            if state?.refreshing == true { return "更新中" }
            if state?.isStale(intervalMinutes: preferences.refreshMinutes) == true { return "数据已过期" }
            return usageStatus(mostUsed(for: profile.id)?.usedPercent)
        }
        guard preferences.profiles.contains(where: { $0.enabled }) else { return "全部已暂停" }
        if hasProfileIssues { return tightestProfile == nil ? "连接异常" : "部分异常" }
        if refreshing { return "更新中" }
        return usageStatus(tightestProfile?.window.usedPercent)
    }

    var menuTitle: String {
        guard configured else { return globalError == nil ? "" : "!" }
        let attention = globalError != nil || hasProfileIssues
        let profile: ConnectionProfile?
        let window: QuotaWindow?
        if preferences.menuBarMode == "selected", let selected = selectedProfile {
            profile = selected
            window = selected.enabled ? mostUsed(for: selected.id) : nil
        } else {
            let tightest = tightestProfile
            profile = tightest?.profile
            window = tightest?.window
        }
        let name = preferences.showProfileName ? profile.map { "\(String($0.name.prefix(18))) " } ?? "" : ""
        let value: String
        if let window {
            let percent = preferences.showRemaining ? 100 - window.usedPercent : window.usedPercent
            value = "\(Int(percent.rounded()))%"
        } else if profile?.enabled == false || !preferences.profiles.contains(where: { $0.enabled }) {
            value = "已暂停"
        } else {
            value = attention ? "—" : "…"
        }
        return "\(name)\(value)\(attention ? " !" : "")"
    }

    var menuTooltip: String {
        if let globalError { return "QuotaPeek · 配置异常\n\(globalError)" }
        guard configured else { return "QuotaPeek · 添加连接以查看额度" }
        var lines = ["QuotaPeek · \(statusTitle)"]
        for profile in preferences.profiles {
            guard profile.enabled else {
                if profile.id == preferences.selectedProfileID { lines.append("\(profile.name)：已暂停") }
                continue
            }
            let state = states[profile.id]
            var detail = "等待数据"
            if let window = mostUsed(for: profile.id) {
                let percent = preferences.showRemaining ? 100 - window.usedPercent : window.usedPercent
                detail = "\(window.title) · \(preferences.showRemaining ? "剩余" : "已用") \(Int(percent.rounded()))%"
            }
            if let error = state?.error { detail += " · \(error)" }
            else if state?.isStale(intervalMinutes: preferences.refreshMinutes) == true { detail += " · 数据已过期" }
            else if state?.refreshing == true { detail += " · 更新中" }
            lines.append("\(profile.name)：\(detail)")
        }
        return lines.joined(separator: "\n")
    }

    init() {
        do {
            preferences = try ConfigurationStore.load()
            configurationLoaded = true
            for profile in preferences.profiles {
                var state = ProfileState()
                do {
                    let key = try KeyStore.read(for: profile.id)
                    apiKeys[profile.id] = key
                    if key.isEmpty { state.error = "未找到此连接的 API Key，请在设置中重新保存。" }
                } catch {
                    state.error = "无法读取此连接的钥匙串，请解锁登录钥匙串后重试。"
                }
                states[profile.id] = state
            }
        } catch {
            globalError = "读取本机配置失败。为避免覆盖原有连接，已停止保存；请检查或恢复 preferences.json 后重新启动。"
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
        restartTimer()
    }

    func savedKey(for id: String) -> String { apiKeys[id] ?? "" }

    func selectProfile(_ id: String?) {
        guard canPersist(), id != preferences.selectedProfileID,
              id == nil || preferences.profiles.contains(where: { $0.id == id }) else { return }
        var candidate = preferences
        candidate.selectedProfileID = id
        _ = persist(candidate)
    }

    func refresh() {
        if let id = preferences.selectedProfileID { refresh(id: id) }
        else { refreshAll() }
    }

    func refresh(id: String) {
        enqueueRefresh(id)
        drainRefreshQueue()
        onChange?()
    }

    func refreshAll() {
        for profile in preferences.profiles where profile.enabled { enqueueRefresh(profile.id) }
        drainRefreshQueue()
        onChange?()
    }

    private func enqueueRefresh(_ id: String) {
        guard preferences.profiles.contains(where: { $0.id == id && $0.enabled }),
              refreshTasks[id] == nil, !refreshQueue.contains(id) else { return }
        refreshQueue.append(id)
        states[id]?.refreshing = true
    }

    private func drainRefreshQueue() {
        // A connection validation reserves the next available slot and pauses the ordinary queue.
        if saving {
            if refreshTasks.count < 3, let waiter = connectionWaiter {
                connectionWaiter = nil
                waiter.resume()
            }
            return
        }
        while refreshTasks.count < 3, !refreshQueue.isEmpty {
            let id = refreshQueue.removeFirst()
            guard let profile = preferences.profiles.first(where: { $0.id == id && $0.enabled }) else {
                states[id]?.refreshing = false
                continue
            }
            states[id]?.lastAttempt = Date()
            let key: String
            do {
                if let cached = apiKeys[id], !cached.isEmpty { key = cached }
                else {
                    key = try KeyStore.read(for: id)
                    apiKeys[id] = key
                }
            } catch {
                states[id]?.error = "无法读取此连接的钥匙串，请解锁登录钥匙串后重试。"
                states[id]?.refreshing = false
                continue
            }
            guard !key.isEmpty else {
                states[id]?.error = "未找到此连接的 API Key，请在设置中重新保存。"
                states[id]?.refreshing = false
                continue
            }
            let token = UUID()
            requestTokens[id] = token
            refreshTasks[id] = Task { [weak self] in
                defer { self?.finishRefresh(id: id, token: token) }
                do {
                    let result = try await QuotaClient.fetch(baseURL: profile.baseURL, apiKey: key, timeout: 15)
                    guard !Task.isCancelled, let self, self.isCurrent(id: id, token: token) else { return }
                    self.states[id]?.snapshot = result
                    self.states[id]?.error = nil
                    self.onChange?()
                    await self.notifyIfNeeded(result, for: id, token: token)
                } catch {
                    guard !Task.isCancelled, let self, self.isCurrent(id: id, token: token) else { return }
                    self.states[id]?.error = self.connectionError(error)
                }
            }
        }
    }

    private func finishRefresh(id: String, token: UUID) {
        guard requestTokens[id] == token else { return }
        refreshTasks.removeValue(forKey: id)
        states[id]?.refreshing = false
        drainRefreshQueue()
        onChange?()
    }

    @discardableResult
    private func cancelRefresh(id: String) -> UUID {
        let token = UUID()
        requestTokens[id] = token
        refreshQueue.removeAll { $0 == id }
        refreshTasks.removeValue(forKey: id)?.cancel()
        states[id]?.refreshing = false
        return token
    }

    private func isCurrent(id: String, token: UUID) -> Bool {
        requestTokens[id] == token && preferences.profiles.contains { $0.id == id && $0.enabled }
    }

    /// The supplied key, not the local display name, determines which server account/VM is queried.
    func upsertProfile(_ profile: ConnectionProfile, key: String) async -> Bool {
        guard !saving, canPersist() else { return false }
        guard !profile.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            settingsMessage = "连接标识无效，请重新添加连接。"
            return false
        }
        saving = true
        settingsMessage = nil
        let token = cancelRefresh(id: profile.id)
        defer {
            saving = false
            if !preferences.profiles.contains(where: { $0.id == profile.id }) {
                requestTokens.removeValue(forKey: profile.id)
            }
            drainRefreshQueue()
            onChange?()
        }
        var profile = profile
        profile.baseURL = profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.name = String(profile.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        if profile.name.isEmpty { profile.name = "我的额度" }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if refreshTasks.count >= 3 {
            await withCheckedContinuation { connectionWaiter = $0 }
        }
        let result: QuotaSnapshot
        let attemptedAt = Date()
        do {
            try Task.checkCancellation()
            result = try await QuotaClient.fetch(baseURL: profile.baseURL, apiKey: key, timeout: 15)
            try Task.checkCancellation()
        } catch {
            settingsMessage = error is CancellationError ? "连接已取消，原有配置未更改。" : connectionError(error)
            return false
        }
        let oldKey: String
        do { oldKey = try KeyStore.read(for: profile.id, allowInteraction: true) }
        catch {
            settingsMessage = "无法读取原有钥匙串，未保存更改。请解锁登录钥匙串后重试。"
            return false
        }
        var candidate = preferences
        let oldProfile = candidate.profiles.first { $0.id == profile.id }
        if let index = candidate.profiles.firstIndex(where: { $0.id == profile.id }) {
            candidate.profiles[index] = profile
        } else {
            candidate.profiles.append(profile)
            if candidate.profiles.count == 1 { candidate.selectedProfileID = profile.id }
        }
        candidate = candidate.validated()
        do { try KeyStore.save(key, for: profile.id) }
        catch {
            settingsMessage = "无法保存此连接的 API Key，原有配置未更改。请检查登录钥匙串。"
            return false
        }
        do { try ConfigurationStore.save(candidate) }
        catch {
            let restored = restoreKey(oldKey, for: profile.id)
            settingsMessage = restored ? "无法保存配置，已恢复原有 API Key；原有连接未更改。" : globalError
            return false
        }
        let changedConnection = oldProfile?.baseURL != profile.baseURL || apiKeys[profile.id] != key
        preferences = candidate
        apiKeys[profile.id] = key
        var state = ProfileState()
        state.snapshot = result
        state.lastAttempt = attemptedAt
        states[profile.id] = state
        clearNotifications(for: profile.id, resetDeduplication: changedConnection || !profile.enabled)
        restartTimer()
        settingsMessage = "已保存"
        onChange?()
        await notifyIfNeeded(result, for: profile.id, token: token)
        return true
    }

    func deleteProfile(id: String) -> Bool {
        guard !saving, canPersist(), let index = preferences.profiles.firstIndex(where: { $0.id == id }) else { return false }
        var candidate = preferences
        candidate.profiles.remove(at: index)
        if candidate.selectedProfileID == id { candidate.selectedProfileID = nil }
        let oldKey: String
        do { oldKey = try KeyStore.read(for: id, allowInteraction: true) }
        catch {
            settingsMessage = "无法读取此连接的钥匙串，未删除连接。请解锁登录钥匙串后重试。"
            return false
        }
        do { try KeyStore.delete(for: id) }
        catch {
            settingsMessage = "无法删除此连接的 API Key，连接配置已保留。"
            return false
        }
        do { try ConfigurationStore.save(candidate) }
        catch {
            let restored = restoreKey(oldKey, for: id)
            settingsMessage = restored ? "无法保存删除操作，已恢复此连接的 API Key；连接未删除。" : globalError
            return false
        }
        preferences = candidate
        cancelRefresh(id: id)
        clearNotifications(for: id)
        apiKeys.removeValue(forKey: id)
        states.removeValue(forKey: id)
        requestTokens.removeValue(forKey: id)
        settingsMessage = "已删除"
        restartTimer()
        drainRefreshQueue()
        onChange?()
        return true
    }

    func setProfileEnabled(id: String, enabled: Bool) {
        guard !saving, canPersist(), let index = preferences.profiles.firstIndex(where: { $0.id == id }),
              preferences.profiles[index].enabled != enabled else { return }
        var candidate = preferences
        candidate.profiles[index].enabled = enabled
        guard persist(candidate) else { return }
        if enabled { enqueueRefresh(id) }
        else {
            cancelRefresh(id: id)
            clearNotifications(for: id)
        }
        restartTimer()
        drainRefreshQueue()
        onChange?()
    }

    func moveProfile(id: String, offset: Int) {
        guard !saving, canPersist(), let index = preferences.profiles.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + max(-index, min(offset, preferences.profiles.count - 1 - index))
        guard destination != index else { return }
        var candidate = preferences
        let profile = candidate.profiles.remove(at: index)
        candidate.profiles.insert(profile, at: destination)
        _ = persist(candidate)
    }

    func savePreferences(_ candidate: Preferences) async -> Bool {
        guard !saving, canPersist() else { return false }
        saving = true
        settingsMessage = nil
        defer {
            saving = false
            drainRefreshQueue()
            onChange?()
        }
        var candidate = candidate
        candidate.profiles = preferences.profiles
        candidate.selectedProfileID = preferences.selectedProfileID
        candidate = candidate.validated()
        let enablingNotifications = candidate.notifications && !preferences.notifications
        let intervalChanged = candidate.refreshMinutes != preferences.refreshMinutes
        guard persist(candidate) else { return false }
        if intervalChanged { restartTimer() }
        if !candidate.notifications {
            for profile in preferences.profiles { clearNotifications(for: profile.id) }
        }
        settingsMessage = "已保存"
        if enablingNotifications {
            do {
                let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                if !allowed { settingsMessage = "设置已保存。提醒未获授权，可在系统设置 → 通知中开启。" }
            } catch { settingsMessage = "设置已保存，但无法开启通知。请检查系统通知设置。" }
        }
        return true
    }

    func clearSettingsMessage() { settingsMessage = nil }

    func setLoginEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if enabled && !loginEnabled {
                settingsMessage = "请在系统设置 → 通用 → 登录项中允许 QuotaPeek。"
            }
        } catch {
            settingsMessage = "无法更改开机启动。请先将 App 移到「应用程序」，再重试。"
        }
    }

    private func canPersist() -> Bool {
        guard configurationLoaded, !storageRecoveryRequired else {
            settingsMessage = globalError ?? "本机存储不可用，未更改配置。"
            return false
        }
        return true
    }

    private func persist(_ candidate: Preferences) -> Bool {
        do {
            try ConfigurationStore.save(candidate)
            preferences = candidate
            onChange?()
            return true
        } catch {
            settingsMessage = "无法保存本机配置，原有设置未更改。请检查文件权限和可用空间。"
            return false
        }
    }

    private func restoreKey(_ key: String, for id: String) -> Bool {
        do {
            if key.isEmpty { try KeyStore.delete(for: id) }
            else { try KeyStore.save(key, for: id) }
            return true
        } catch {
            storageRecoveryRequired = true
            globalError = "配置保存失败，且此连接的钥匙串无法恢复。已停止继续保存；请解锁钥匙串并检查本机配置后重新启动。"
            onChange?()
            return false
        }
    }

    private func connectionError(_ error: Error) -> String {
        // Only our fixed, sanitized errors may be displayed; arbitrary system/server text could contain secrets.
        (error as? QuotaError)?.errorDescription ?? "无法读取额度，请检查网络及连接设置。"
    }

    private func usageStatus(_ usedPercent: Double?) -> String {
        guard let usedPercent else { return "等待数据" }
        return usedPercent >= 100 ? "额度耗尽" : usedPercent >= Double(preferences.warningPercent) ? "留意用量" : "额度充足"
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        guard preferences.profiles.contains(where: { $0.enabled }) else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Double(preferences.refreshMinutes) * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
    }

    private func clearNotifications(for id: String, resetDeduplication: Bool = true) {
        if let requests = notificationRequests.removeValue(forKey: id), !requests.isEmpty {
            let identifiers = Array(requests.values)
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
        if resetDeduplication { notifiedWindows.removeValue(forKey: id) }
    }

    private func notifyIfNeeded(_ result: QuotaSnapshot, for id: String, token: UUID) async {
        guard preferences.notifications, isCurrent(id: id, token: token), !Task.isCancelled else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized, preferences.notifications,
              isCurrent(id: id, token: token), !Task.isCancelled else { return }
        let now = Date()
        let currentWindows = Set(result.windows.compactMap { window -> NotificationWindow? in
            guard window.resetsAt.map({ $0 > now }) ?? true else { return nil }
            return NotificationWindow(id: window.id, resetsAt: window.resetsAt)
        })
        notifiedWindows[id] = (notifiedWindows[id] ?? []).intersection(currentWindows)
        if let requests = notificationRequests[id] {
            for (window, identifier) in requests where !currentWindows.contains(window) {
                center.removePendingNotificationRequests(withIdentifiers: [identifier])
                center.removeDeliveredNotifications(withIdentifiers: [identifier])
                notificationRequests[id]?.removeValue(forKey: window)
            }
        }
        for window in result.windows {
            guard preferences.notifications, isCurrent(id: id, token: token), !Task.isCancelled,
                  let profile = preferences.profiles.first(where: { $0.id == id }) else { return }
            let notificationWindow = NotificationWindow(id: window.id, resetsAt: window.resetsAt)
            guard currentWindows.contains(notificationWindow), window.usedPercent >= Double(preferences.warningPercent),
                  !(notifiedWindows[id]?.contains(notificationWindow) ?? false) else { continue }
            let identifier = "quota-\(id)-\(token.uuidString)-\(window.id)-\(window.resetsAt?.timeIntervalSince1970 ?? 0)"
            let content = UNMutableNotificationContent()
            content.title = "\(profile.name) · 额度提醒"
            content.body = "\(window.title)已使用 \(Int(window.usedPercent.rounded()))%，请留意重置时间。"
            content.sound = .default
            notificationRequests[id, default: [:]][notificationWindow] = identifier
            do {
                try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
                guard preferences.notifications, isCurrent(id: id, token: token), !Task.isCancelled else {
                    // A profile can change while the notification daemon is accepting this request.
                    center.removePendingNotificationRequests(withIdentifiers: [identifier])
                    center.removeDeliveredNotifications(withIdentifiers: [identifier])
                    if notificationRequests[id]?[notificationWindow] == identifier {
                        notificationRequests[id]?.removeValue(forKey: notificationWindow)
                    }
                    return
                }
                notifiedWindows[id, default: []].insert(notificationWindow)
            } catch {
                if notificationRequests[id]?[notificationWindow] == identifier {
                    notificationRequests[id]?.removeValue(forKey: notificationWindow)
                }
                // Notification delivery failure must not invalidate successful quota data.
            }
        }
    }
}
