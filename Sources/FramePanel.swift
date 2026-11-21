import AppKit
import ServiceManagement
import SwiftUI

struct FramePanel: View {
    @ObservedObject var server: FrameServer
    @ObservedObject var appSettings: StudioAppSettings
    @Environment(\.dismiss) private var dismiss
    @StateObject private var form = FramePanelForm()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("连接映序").font(.title2.bold())
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Picker("局域网地址", selection: $form.selection) {
                            if form.interfaces.isEmpty { Text("未找到 IPv4 地址").tag(nil as FrameAddress?) }
                            ForEach(form.interfaces) { address in Text(address.id).tag(Optional(address)) }
                        }
                        .disabled(server.enabled || form.interfaces.isEmpty)
                        Spacer(minLength: 8)
                        Toggle("开启连接", isOn: Binding(
                            get: { server.enabled },
                            set: { server.setEnabled($0, interface: form.selection) }
                        ))
                        .toggleStyle(.switch)
                    }
                    if let address = server.address {
                        HStack {
                            Text("服务地址")
                            Text(address).monospaced().textSelection(.enabled)
                            Spacer()
                            Button("生成配对码") { server.newPairing() }
                        }
                        if let code = server.pairingCode, let expires = server.pairExpires {
                            LabeledContent("配对码") {
                                Text(code)
                                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                                    .textSelection(.enabled)
                            }
                            if let fingerprint = server.pairingFingerprint {
                                LabeledContent("证书指纹") {
                                    Text(fingerprint).monospaced().textSelection(.enabled)
                                }
                            }
                            Text("此码在 \(expires.formatted(date: .omitted, time: .shortened)) 前可使用一次。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else if server.starting {
                        ProgressView("正在启动局域网连接…").controlSize(.small)
                    } else if server.enabled {
                        Text("等待所选网络可用，连接恢复后会自动启动。")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Button("刷新局域网地址") { reloadInterfaces() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Toggle("自动启动", isOn: Binding(
                            get: { appSettings.launchesAtLogin },
                            set: { appSettings.setLaunchAtLogin($0) }
                        ))
                        .toggleStyle(.switch)
                        .help("登录 macOS 时启动 MFlux Studio")
                        Spacer()
                        Toggle("隐藏 Dock 栏图标", isOn: Binding(
                            get: { appSettings.hidesDock },
                            set: { appSettings.setDockHidden($0) }
                        ))
                        .toggleStyle(.switch)
                    }
                    if appSettings.loginApprovalRequired {
                        Button("在系统设置中允许自动启动") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            if let error = appSettings.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let error = server.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }

            if !server.devices.isEmpty {
                Text("已配对设备").font(.headline)
                ForEach(server.devices) { device in
                    HStack {
                        Text(device.name).lineLimit(1)
                        Spacer()
                        Button("移除", role: .destructive) { server.revoke(device.id) }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 530)
        .onAppear {
            reloadInterfaces()
            appSettings.refreshLoginStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appSettings.refreshLoginStatus()
        }
        .onChange(of: server.address) { _, _ in reloadInterfaces() }
    }

    private func reloadInterfaces() {
        form.interfaces = FrameAddress.available()
        if let selection = form.selection, form.interfaces.contains(selection) { return }
        form.selection = form.interfaces.first { $0.interfaceName == server.preferredInterface } ?? form.interfaces.first
    }
}


private final class FramePanelForm: ObservableObject {
    @Published var interfaces: [FrameAddress] = []
    @Published var selection: FrameAddress?
}


@MainActor
final class StudioAppSettings: ObservableObject {
    private static let hideDockKey = "MFluxStudioHidesDock"
    private let preferences = UserDefaults.standard
    private let login = SMAppService.mainApp

    @Published private(set) var hidesDock = UserDefaults.standard.bool(forKey: hideDockKey)
    @Published private(set) var loginStatus: SMAppService.Status = .notRegistered
    @Published private(set) var error: String?

    var launchesAtLogin: Bool { loginStatus == .enabled || loginApprovalRequired }
    var loginApprovalRequired: Bool { loginStatus == .requiresApproval }

    func refreshLoginStatus() {
        loginStatus = login.status
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        refreshLoginStatus()
        guard enabled != launchesAtLogin else { return }
        error = nil
        do {
            if enabled { try login.register() }
            else { try login.unregister() }
        } catch {
            refreshLoginStatus()
            if enabled != launchesAtLogin {
                self.error = "无法更新自动启动：\(error.localizedDescription)"
            }
        }
        refreshLoginStatus()
    }

    func restoreDockVisibility() {
        setDockHidden(hidesDock)
    }

    func setDockHidden(_ hidden: Bool) {
        let policy: NSApplication.ActivationPolicy = hidden ? .accessory : .regular
        if NSApp.activationPolicy() != policy {
            let window = NSApp.keyWindow ?? NSApp.mainWindow
            guard NSApp.setActivationPolicy(policy) else {
                hidesDock = NSApp.activationPolicy() == .accessory
                error = "无法更改 Dock 栏图标的显示状态。"
                return
            }
            if let window, window.isVisible {
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
            }
        }
        error = nil
        if hidesDock != hidden { hidesDock = hidden }
        preferences.set(hidden, forKey: Self.hideDockKey)
    }
}

final class StudioAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

struct StudioStatusMenu: View {
    @ObservedObject var appSettings: StudioAppSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("打开 MFlux Studio") { showStudio() }
        Button("显示 Dock 栏图标") {
            appSettings.setDockHidden(false)
            showStudio()
        }
        Divider()
        Button("退出 MFlux Studio") { NSApp.terminate(nil) }
    }

    private func showStudio() {
        openWindow(id: "studio")
        NSApp.activate()
    }
}
