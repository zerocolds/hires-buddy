import HiResBuddyCore
import LDACEncoder
import SwiftUI

/// The menu bar panel: headphones and status, the LDAC toggle, quality, stream stats, device choice.
struct PanelView: View {
    @ObservedObject var controller: SessionController

    private var isOn: Bool { controller.phase == .connecting || controller.phase == .streaming }
    /// Stopping, or waiting for the headphones to reconnect to macOS: nothing but «Выход» may be touched.
    private var isBusy: Bool { controller.phase == .stopping || controller.isReturningHeadphones }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Toggle("Hi-Res (LDAC)", isOn: Binding(get: { isOn }, set: { controller.setEnabled($0) }))
                .toggleStyle(.switch)
                .disabled(isBusy || (!isOn && !controller.canEnable))   // canEnable is false while a refresh probes
            if !isOn && !isBusy && !controller.canEnable && !controller.isRefreshing { hint }
            qualityPicker
            if let stats = controller.stats { statsBlock(stats) }
            Divider()
            headphonePicker
            HStack {
                Button("Обновить список") { Task { await controller.refreshHeadphones() } }
                    .disabled(isBusy || isOn || controller.isRefreshing)
                Spacer()
                Button("Выход") { controller.quit() }   // never disabled: a second press stops any wait
            }
        }
        .padding(14)
        .frame(width: 320)
        .task {
            controller.recheckDriver()
            await controller.refreshHeadphones()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(controller.selected?.name ?? "Наушники не выбраны").font(.headline)
            Text(status).font(.subheadline).foregroundStyle(statusColor)
        }
    }

    private var status: String {
        // The headphones went away by themselves: nothing is being returned, say what happened.
        if controller.headphonesLeft, case .error(let message) = controller.phase { return message }
        if controller.isReturningHeadphones || controller.phase == .stopping { return "Возвращаю наушники системе…" }
        switch controller.phase {
        case .off: return controller.selected?.isConnected == true ? "Подключены · системный звук macOS" : "Не подключены"
        case .connecting: return "Подключаю LDAC…"
        case .streaming: return "LDAC · поток идёт"
        case .stopping: return "Останавливаю…"
        case .error(let message): return message
        }
    }

    private var statusColor: Color {
        switch controller.phase {
        case .streaming: return .green
        case .error: return .red
        default: return .secondary
        }
    }

    @ViewBuilder private var hint: some View {
        if !controller.driverInstalled {
            VStack(alignment: .leading, spacing: 6) {
                Text("Установите драйвер").font(.caption).foregroundStyle(.secondary)
                Button(controller.isInstallingDriver ? "Устанавливаю…" : "Установить драйвер…") { controller.installDriver() }
                    .disabled(controller.isInstallingDriver)
                if let error = controller.driverInstallError {
                    Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if controller.selected?.ldacSampleRates == 0 {
            Text("Эти наушники не поддерживают LDAC").font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Подключите наушники с LDAC").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var qualityPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Качество", selection: $controller.quality) {
                ForEach(LDACQuality.allCases, id: \.self) { q in
                    Text("\(LDACEncoder.nominalBitrate(quality: q, sampleRate: .hz48000))").tag(q)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(isBusy)
            Text("Битрейт, kbps · меняется на лету").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func statsBlock(_ s: StreamStats) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("LDAC · \(s.sampleRate / 1000) kHz · \(s.bitrateKbps) kbps").font(.callout.monospacedDigit())
            Group {
                Text("Пакеты: \(s.packets)   Провалы: \(s.dropEvents)")
                Text("Аптайм: \(Self.uptime(s.uptime))   Буфер: \(String(format: "%.2f", s.bufferSeconds)) с")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var headphonePicker: some View {
        Picker("Наушники", selection: Binding(
            get: { controller.selected?.id },
            set: { id in controller.selected = controller.headphones.first { $0.id == id } })) {
            if controller.headphones.isEmpty { Text("Нет сопряжённых наушников").tag(String?.none) }
            ForEach(controller.headphones) { h in
                Text(Self.label(h)).tag(String?.some(h.id))
            }
        }
        .disabled(isBusy || isOn)
    }

    private static func label(_ h: Headphones) -> String {
        guard h.isConnected else { return "\(h.name) — не подключены" }
        switch h.ldacSampleRates {
        case 0?: return "\(h.name) — без LDAC"
        case nil: return h.name
        default: return "\(h.name) — LDAC"
        }
    }

    private static func uptime(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}
