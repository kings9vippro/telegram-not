// © 2026 Phan Anh Khoi (Yanbi) · @axzy_anhkhoi
import Foundation
import SwiftUI
import UIKit

@_silgen_name("yanbi_analyze") private func rustAnalyze(_ input: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
@_silgen_name("yanbi_free") private func rustFree(_ output: UnsafeMutablePointer<CChar>)

private let endpoint = URL(string: "https://asbestos-promote-mississippi-wizard.trycloudflare.com/sunhot/api/tx/history")!

struct Roll: Decodable {
    let phien: String
    let ket_qua: String
    let xuc_xac: [Int]
}
struct RollHistory: Decodable {
    let history: [Roll]
}
struct Replay: Decodable, Identifiable {
    let phien: String
    let du_doan: String
    let ket_qua: String
    let status: String
    var id: String { phien }
}
struct Analysis: Decodable {
    let total: Int
    let tai: Int
    let xiu: Int
    let bao: Int
    let faces: [Int]
    let sums: [Int]
    let streak: Int
    let streak_side: String
    let next: String
    let prediction: String
    let confidence: Int
    let pattern: String
    let tested: Int
    let model_accuracy: Double
    let baseline_accuracy: Double
    let recent: [Roll]
    let replay: [Replay]
}
struct SavedPick: Codable, Identifiable {
    let phien: String
    let du_doan: String
    var ket_qua: String?
    var id: String { phien }
    var status: String {
        guard let ket_qua else { return "Đang chờ" }
        if ket_qua == "Bão" { return "Bão" }
        return du_doan == ket_qua ? "Thắng" : "Thua"
    }
}

@MainActor final class Forecast: ObservableObject {
    @Published var result: Analysis?
    @Published var picks: [SavedPick] = []
    @Published var message = "Đang tải lịch sử..."
    @Published var isLoading = false

    init() {
        if let data = UserDefaults.standard.data(forKey: "yanbi.picks"),
           let saved = try? JSONDecoder().decode([SavedPick].self, from: data) {
            picks = saved
        }
    }
    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = 15
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let output = await Task.detached(priority: .userInitiated) { () -> Data? in
                var terminated = [CChar](repeating: 0, count: data.count + 1)
                data.withUnsafeBytes { bytes in
                    terminated.withUnsafeMutableBytes { destination in destination.copyBytes(from: bytes) }
                }
                return terminated.withUnsafeBufferPointer { buffer in
                    guard let input = buffer.baseAddress, let value = rustAnalyze(input) else { return nil }
                    defer { rustFree(value) }
                    return String(cString: value).data(using: .utf8)
                }
            }.value
            guard let output else { throw URLError(.cannotDecodeContentData) }
            let updated = try JSONDecoder().decode(Analysis.self, from: output)
            let history = try JSONDecoder().decode(RollHistory.self, from: data)
            let results = Dictionary(history.history.map { ($0.phien, $0.ket_qua) }, uniquingKeysWith: { first, _ in first })
            for index in picks.indices {
                if let actual = results[picks[index].phien] { picks[index].ket_qua = actual }
            }
            if ["Tài", "Xỉu"].contains(updated.prediction) && !picks.contains(where: { $0.phien == updated.next }) {
                picks.append(SavedPick(phien: updated.next, du_doan: updated.prediction))
            }
            picks = Array(picks.suffix(100))
            UserDefaults.standard.set(try JSONEncoder().encode(picks), forKey: "yanbi.picks")
            result = updated
            message = "Cập nhật \(Date.now.formatted(date: .omitted, time: .shortened))"
        } catch {
            message = "Không tải được dữ liệu · kéo xuống để thử lại"
        }
    }
}

private struct PhotoBackground: View {
    var body: some View {
        GeometryReader { proxy in
            if let path = Bundle.main.path(forResource: "background", ofType: "jpg"),
               let photo = UIImage(contentsOfFile: path) {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            } else {
                Color(white: 0.2)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

@main struct YanbiApp: App {
    @StateObject private var forecast = Forecast()
    @Environment(\.scenePhase) private var scenePhase
    private let ink = Color.white

    var body: some Scene {
        WindowGroup {
            ZStack {
                PhotoBackground()
                Color.black.opacity(0.27).ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 15) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("YANBI").font(.system(size: 26, weight: .black, design: .rounded)).tracking(2)
                                Text("PHÂN TÍCH TÀI XỈU").font(.caption2.weight(.semibold)).tracking(1.5)
                            }
                            Spacer()
                            Button { Task { await forecast.refresh() } } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.headline.weight(.bold))
                                    .frame(width: 46, height: 46)
                                    .background(.ultraThinMaterial, in: Circle())
                            }
                            .disabled(forecast.isLoading)
                            .accessibilityLabel("Cập nhật")
                        }
                        .padding(.top, 10)
                        panel {
                            Text("DỰ ĐOÁN · PHIÊN \(forecast.result?.next ?? "—")")
                                .font(.caption.weight(.bold)).tracking(1.5)
                            Text(forecast.result?.prediction ?? "Đang tải")
                                .font(.system(size: 48, weight: .heavy, design: .rounded))
                                .contentTransition(.numericText())
                            Text(forecast.result.map { "\($0.pattern) · ước lượng \($0.confidence)%" } ?? "Đang kết nối")
                                .font(.subheadline)
                            Text("Tỷ lệ mô hình trong kiểm thử: \(forecast.result?.model_accuracy ?? 0, specifier: "%.1f")%")
                                .font(.caption)
                        }
                        HStack(spacing: 10) {
                            tile("Tài", forecast.result?.tai ?? 0)
                            tile("Xỉu", forecast.result?.xiu ?? 0)
                            tile("Bão", forecast.result?.bao ?? 0)
                        }
                        panel {
                            Text("LỊCH SỬ THẮNG THUA").font(.caption.weight(.bold)).tracking(1)
                            let wins = forecast.picks.filter { $0.status == "Thắng" }.count
                            let losses = forecast.picks.filter { $0.status == "Thua" }.count
                            HStack {
                                Text("\(wins) thắng").foregroundStyle(.green)
                                Text("·")
                                Text("\(losses) thua").foregroundStyle(.pink)
                                Spacer()
                                Text(wins + losses > 0 ? String(format: "%.1f%%", Double(wins) * 100 / Double(wins + losses)) : "—")
                            }
                            .font(.headline)
                            ForEach(forecast.picks.reversed().prefix(15)) { pick in
                                HStack {
                                    Text("#\(pick.phien)").monospacedDigit()
                                    Spacer()
                                    Text(pick.du_doan)
                                    Text(pick.status)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(pick.status == "Thắng" ? .green : pick.status == "Thua" ? .pink : .white)
                                }
                                .font(.subheadline)
                                Divider().overlay(.white.opacity(0.2))
                            }
                            if forecast.picks.isEmpty { Text("Chưa lưu phiên nào trên máy này").font(.subheadline) }
                        }
                        panel {
                            Text("NHỊP CẦU GẦN ĐÂY").font(.caption.weight(.bold)).tracking(1)
                            Text("Bệt \(forecast.result?.streak_side ?? "—") · \(forecast.result?.streak ?? 0) phiên")
                            Text("Kiểm thử \(forecast.result?.tested ?? 0) phiên · mốc \(forecast.result?.baseline_accuracy ?? 0, specifier: "%.1f")%")
                                .font(.caption)
                            if let rolls = forecast.result?.recent.suffix(20) {
                                Text(rolls.map { $0.ket_qua == "Tài" ? "T" : $0.ket_qua == "Xỉu" ? "X" : "B" }.joined(separator: "  "))
                                    .font(.system(.subheadline, design: .monospaced)).lineLimit(3)
                            }
                        }
                        Text(forecast.message).font(.caption)
                        Link("Owner Yanbi · Tele @axzy_anhkhoi", destination: URL(string: "https://t.me/axzy_anhkhoi")!)
                            .font(.caption)
                        Text("Thắng thua được ghi khi có kết quả phiên thật. Kiểm thử lịch sử chỉ dùng để đánh giá thuật toán.")
                            .font(.caption2).opacity(0.85)
                    }
                    .foregroundStyle(ink)
                    .padding(16)
                    .frame(maxWidth: 600)
                    .frame(maxWidth: .infinity)
                }
                .refreshable { await forecast.refresh() }
            }
            .preferredColorScheme(.dark)
            .task {
                await forecast.refresh()
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    if Task.isCancelled { break }
                    if scenePhase == .active { await forecast.refresh() }
                }
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active { Task { await forecast.refresh() } }
            }
        }
    }
    private func tile(_ title: String, _ count: Int) -> some View {
        VStack(alignment: .leading) {
            Text("\(count)").font(.title2.bold()).contentTransition(.numericText())
            Text(title).font(.caption.weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 19))
    }
    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 23))
            .overlay(RoundedRectangle(cornerRadius: 23).strokeBorder(.white.opacity(0.25), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 7)
    }
}
