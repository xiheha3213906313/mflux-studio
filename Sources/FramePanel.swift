import AppKit
import SwiftUI

struct FramePanel: View {
    @ObservedObject var server: FrameServer
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
                    Text("开启后，每次打开 MFlux Studio 时会自动启动服务。")
                        .font(.callout).foregroundStyle(.secondary)
                    if let address = server.address {
                        LabeledContent("服务地址") {
                            Text(address).monospaced().textSelection(.enabled)
                        }
                        if let code = server.pairingCode, let expires = server.pairExpires {
                            LabeledContent("配对码") {
                                Text(code)
                                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                                    .textSelection(.enabled)
                                    .accessibilityLabel(Text("配对码 \(code)"))
                            }
                            HStack {
                                Text("在安卓映序选择这台 Mac，输入配对码。")
                                    .font(.callout).foregroundStyle(.secondary)
                                Spacer()
                                Button("重新生成") { server.newPairing() }
                            }
                            Text("此码在 \(expires.formatted(date: .omitted, time: .shortened)) 前可使用一次。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button("生成配对码") { server.newPairing() }
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
            if !server.jobs.isEmpty {
                Text("近期任务").font(.headline)
                ScrollView {
                    VStack(spacing: 7) {
                        ForEach(server.jobs, id: \.key) { job in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(job.plan.operation.title + " · " + job.plan.modelName).lineLimit(1)
                                    if let message = job.message {
                                        Text(message).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text(job.state.title).foregroundStyle(.secondary)
                                if job.state.active {
                                    Button("取消") { server.cancelFromMac(job) }.buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                    .padding(.trailing, 8)
                }
                .frame(maxHeight: 170)
            }
        }
        .padding(20)
        .frame(width: 530)
        .onAppear { reloadInterfaces() }
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
