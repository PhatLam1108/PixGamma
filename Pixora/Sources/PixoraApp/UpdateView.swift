import AppKit
import PixoraCore
import SwiftUI

/// Checks GitHub for a newer Pixora, downloads and installs it (see `Updater`).
@MainActor
final class UpdateController: ObservableObject {
    enum Phase: Equatable {
        case idle, needToken, checking, upToDate, available(Updater.Release)
        case downloading(Double), ready(String), failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var showing = false
    private var prepared: Updater.PreparedUpdate?
    private let lastCheckKey = "updateLastCheck"

    var hasToken: Bool { Updater.token != nil }

    /// Menu command: always shows the sheet.
    func checkNow() {
        showing = true
        guard hasToken else { phase = .needToken; return }
        Task { await check(silent: false) }
    }

    /// At launch: once a day, quietly; the sheet only opens when there is an update.
    func checkOnLaunch() {
        guard hasToken else { return }
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 24 * 3600 else { return }
        Task { await check(silent: true) }
    }

    func saveToken(_ value: String) {
        Updater.setToken(value)
        phase = .checking
        Task { await check(silent: false) }
    }

    func forgetToken() {
        Updater.setToken(nil)
        phase = .needToken
    }

    private func check(silent: Bool) async {
        if !silent { phase = .checking }
        do {
            let r = try await Updater.latest()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
            if Updater.isNewer(r.version, than: APIServer.version) {
                phase = .available(r)
                showing = true
            } else if !silent {
                phase = .upToDate
            }
        } catch {
            if !silent { phase = .failed(error.localizedDescription) }
        }
    }

    func install(_ r: Updater.Release) {
        phase = .downloading(0)
        Task {
            do {
                prepared = try await Updater.prepare(r) { p in
                    Task { @MainActor in if case .downloading = self.phase { self.phase = .downloading(p) } }
                }
                phase = .ready(r.version)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func relaunch() {
        guard let prepared else { return }
        do {
            try prepared.relaunch()
            NSApp.terminate(nil)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

struct UpdateSheet: View {
    @EnvironmentObject var updates: UpdateController
    @State private var token = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle").font(.system(size: 22)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cập nhật Pixora").font(.system(size: 15, weight: .semibold))
                    Text("Bản đang dùng: \(APIServer.version)").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }
            content
            HStack {
                if updates.hasToken, updates.phase != .needToken {
                    Button("Xoá token") { updates.forgetToken() }.buttonStyle(.link).font(.system(size: 12))
                }
                Spacer()
                actions
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(Theme.base)
        .foregroundStyle(Theme.textPrimary)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var content: some View {
        switch updates.phase {
        case .idle, .checking:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Đang kiểm tra bản mới…") }
        case .needToken:
            VStack(alignment: .leading, spacing: 8) {
                Text("Repo Pixora là riêng tư, nên app cần một token GitHub chỉ đọc để xem và tải bản mới. Token được cất trong Keychain của máy này.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                Text("Tạo token: Fine-grained token → Repository access: chỉ chọn Pixora → Permissions: Contents = Read-only.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                Link("Mở trang tạo token trên GitHub", destination: Updater.tokenHelpURL).font(.system(size: 12))
                SecureField("github_pat_…", text: $token).textFieldStyle(.roundedBorder)
            }
        case .upToDate:
            Label("Bạn đang dùng bản mới nhất.", systemImage: "checkmark.circle").foregroundStyle(Theme.success)
        case .available(let r):
            VStack(alignment: .leading, spacing: 8) {
                Text("Có bản mới: \(r.version)").font(.system(size: 13, weight: .semibold))
                ScrollView {
                    Text(r.notes.isEmpty ? "(Không có ghi chú)" : r.notes)
                        .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(height: 220)
                .padding(8)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radiusControl))
                Text(r.dmg.map { "Tải \(ByteCountFormatter.string(fromByteCount: Int64($0.size), countStyle: .file)). Model Recover (nếu có) không đổi, cập nhật riêng khi cần." }
                     ?? "Bản này chưa có file cài đặt .dmg, hãy tải thủ công ở trang Releases.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
        case .downloading(let p):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: p)
                Text(p < 0.9 ? "Đang tải… \(Int(p * 100))%" : "Đang kiểm tra mã SHA-256 và chuẩn bị cài…").font(.system(size: 12))
            }
        case .ready(let v):
            Text("Bản \(v) đã sẵn sàng. Pixora sẽ đóng, thay bản mới rồi tự mở lại.").font(.system(size: 12))
        case .failed(let m):
            Label(m, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.danger).font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var actions: some View {
        switch updates.phase {
        case .needToken:
            Button("Huỷ") { updates.showing = false }
            Button("Lưu và kiểm tra") { updates.saveToken(token); token = "" }
                .keyboardShortcut(.defaultAction).disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
        case .available(let r):
            Button("Để sau") { updates.showing = false }
            Button("Cập nhật ngay") { updates.install(r) }.keyboardShortcut(.defaultAction).disabled(r.dmg == nil)
        case .downloading:
            EmptyView()
        case .ready:
            Button("Khởi động lại") { updates.relaunch() }.keyboardShortcut(.defaultAction)
        case .failed:
            Button("Đóng") { updates.showing = false }
            Button("Thử lại") { updates.checkNow() }.keyboardShortcut(.defaultAction)
        default:
            Button("Đóng") { updates.showing = false }.keyboardShortcut(.defaultAction)
        }
    }
}
