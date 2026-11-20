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
                        .disabled(server.live || form.interfaces.isEmpty)
                        if server.live {
                            Button("关闭连接") { server.stop() }
                        } else {
                            Button("开启连接") { if let selection = form.selection { server.start(on: selection) } }
                                .buttonStyle(.borderedProminent).disabled(form.selection == nil)
                        }
                    }
                    if let address = server.address {
                        LabeledContent("服务地址") {
                            Text(address).monospaced().textSelection(.enabled)
                        }
                        HStack {
                            Button("生成配对信息") { form.copied = false; server.newPairing() }
                            if let pairing = server.pairingText {
                                Button(form.copied ? "已复制" : "复制配对信息") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(pairing, forType: .string)
                                    form.copied = true
                                }
                            }
                        }
                        if let expires = server.pairExpires {
                            Text("在映序的连接设置中粘贴配对信息。\(expires.formatted(date: .omitted, time: .shortened)) 前可使用一次。")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    } else if server.starting {
                        ProgressView("正在启动局域网连接…").controlSize(.small)
                    } else {
                        Text("开启后，已配对的安卓设备可使用此 Mac 的本地模型。")
                            .font(.callout).foregroundStyle(.secondary)
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
    }

    private func reloadInterfaces() {
        form.interfaces = FrameAddress.available()
        if let selection = form.selection, form.interfaces.contains(selection) { return }
        form.selection = form.interfaces.first
    }
}


private final class FramePanelForm: ObservableObject {
    @Published var interfaces: [FrameAddress] = []
    @Published var selection: FrameAddress?
    @Published var copied = false
}
