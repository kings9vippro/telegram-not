// © 2026 Phan Anh Khoi (Yanbi) · @axzy_anhkhoi
import Foundation
import SwiftUI
import UIKit

@_silgen_name("yanbi_analyze") private func rustAnalyze(_ input: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
@_silgen_name("yanbi_free") private func rustFree(_ output: UnsafeMutablePointer<CChar>)

private let endpoint = URL(string: "https://asbestos-promote-mississippi-wizard.trycloudflare.com/sunhot/api/tx/history")!

struct Roll: Codable {
    let phien: String
    let ket_qua: String
    let xuc_xac: [Int]
}
struct RollHistory: Codable {
    var history: [Roll]
}
struct Replay: Decodable, Identifiable {
    let phien: String
    let du_doan: String
    let ket_qua: String
    let status: String
    var id: String { phien }
}
struct PatternStat: Decodable, Identifiable {
    let name: String
    let tai: Int
    let xiu: Int
    var id: String { name }
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
    let patterns: [PatternStat]
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
    @Published var sourceLive = false
    private let cacheURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("yanbi-history.json")

    init() {
        if let data = UserDefaults.standard.data(forKey: "yanbi.picks"),
           let saved = try? JSONDecoder().decode([SavedPick].self, from: data) {
            picks = saved
        }
    }
    private func bundledHistory() throws -> Data {
        guard let url = Bundle.main.url(forResource: "snapshot", withExtension: "txt") else {
            throw URLError(.fileDoesNotExist)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        let labels = ["T": "Tài", "X": "Xỉu", "B": "Bão"]
        let rolls = text.split(whereSeparator: \.isWhitespace).compactMap { token -> Roll? in
            let components = token.split(separator: ":")
            guard components.count == 2, components[1].count == 4,
                  Int(components[0]) != nil else { return nil }
            let symbols = Array(components[1])
            let dice = symbols.prefix(3).compactMap { $0.wholeNumberValue }
            guard dice.count == 3, let result = labels[String(symbols[3])] else { return nil }
            return Roll(phien: String(components[0]), ket_qua: result, xuc_xac: dice)
        }
        guard rolls.count > 100 else { throw URLError(.cannotDecodeContentData) }
        return try JSONEncoder().encode(RollHistory(history: rolls))
    }
    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            var live = true
            var data: Data
            do {
                var request = URLRequest(url: endpoint)
                request.timeoutInterval = 12
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let (historyData, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                var history = try JSONDecoder().decode(RollHistory.self, from: historyData)
                // Phiên hiện tại lấy trực tiếp từ API gốc, lịch sử dùng để học mẫu cầu.
                var latestRequest = URLRequest(url: endpoint.deletingLastPathComponent())
                latestRequest.timeoutInterval = 5
                latestRequest.cachePolicy = .reloadIgnoringLocalCacheData
                if let (latestData, latestResponse) = try? await URLSession.shared.data(for: latestRequest),
                   (latestResponse as? HTTPURLResponse)?.statusCode == 200,
                   let latest = try? JSONDecoder().decode(Roll.self, from: latestData),
                   let latestID = Int(latest.phien),
                   latestID > (history.history.compactMap { Int($0.phien) }.max() ?? 0) {
                    history.history.append(latest)
                }
                data = try JSONEncoder().encode(history)
                try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: cacheURL, options: .atomic)
            } catch {
                live = false
                if let saved = try? Data(contentsOf: cacheURL) {
                    data = saved
                } else {
                    data = try bundledHistory()
                }
            }
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
            if live && ["Tài", "Xỉu"].contains(updated.prediction) && !picks.contains(where: { $0.phien == updated.next }) {
                picks.append(SavedPick(phien: updated.next, du_doan: updated.prediction))
            }
            picks = Array(picks.suffix(100))
            UserDefaults.standard.set(try JSONEncoder().encode(picks), forKey: "yanbi.picks")
            result = updated
            sourceLive = live
            message = live ? "Đã đồng bộ API gốc · \(Date.now.formatted(date: .omitted, time: .shortened))" :
                "API gốc mất kết nối · thống kê từ dữ liệu lưu ngày 26/11/2026"
        } catch {
            sourceLive = false
            message = "API gốc đang gián đoạn · kéo xuống để thử lại"
        }
    }
}

private struct PhotoBackground: View {
    var body: some View {
        GeometryReader { proxy in
            if let path = Bundle.main.path(forResource: "background", ofType: "jpg"),
               let photo = UIImage(contentsOfFile: path) {
                ZStack {
                    Image(uiImage: photo)
                        .resizable().scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .blur(radius: 18)
                    Image(uiImage: photo)
                        .resizable().scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
            } else {
                Color(red: 0.88, green: 0.85, blue: 0.84)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

@main struct YanbiApp: App {
    @StateObject private var forecast = Forecast()
    @Environment(\.scenePhase) private var scenePhase
    private let ink = Color(red: 0.13, green: 0.13, blue: 0.16)

    var body: some Scene {
        WindowGroup {
            ZStack {
                PhotoBackground()
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
                                    .background(.white.opacity(0.76), in: Circle())
                            }
                            .disabled(forecast.isLoading)
                            .accessibilityLabel("Cập nhật")
                        }
                        .padding(14)
                        .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 22))
                        .padding(.top, 10)
                        panel {
                            Text("DỰ ĐOÁN · PHIÊN \(forecast.result?.next ?? "—")")
                                .font(.caption.weight(.bold)).tracking(1.5)
                            Text(forecast.sourceLive ? (forecast.result?.prediction ?? "Đang tải") : "Chờ nguồn")
                                .font(.system(size: 48, weight: .heavy, design: .rounded))
                                .contentTransition(.numericText())
                            Text(forecast.sourceLive ? (forecast.result.map { "\($0.pattern) · nghiêng \($0.confidence)%" } ?? "Đang kết nối") : "Nguồn dữ liệu tạm gián đoạn")
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
                                Text("\(wins) thắng").foregroundStyle(Color(red: 0.09, green: 0.44, blue: 0.32))
                                Text("·")
                                Text("\(losses) thua").foregroundStyle(Color(red: 0.66, green: 0.20, blue: 0.30))
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
                                        .foregroundStyle(pick.status == "Thắng" ? Color(red: 0.09, green: 0.44, blue: 0.32) : pick.status == "Thua" ? Color(red: 0.66, green: 0.20, blue: 0.30) : ink)
                                }
                                .font(.subheadline)
                                Divider().overlay(.black.opacity(0.1))
                            }
                            if forecast.picks.isEmpty { Text("Chưa có dự đoán trực tiếp trên máy này").font(.subheadline) }
                        }
                        if let replay = forecast.result?.replay, !replay.isEmpty {
                            panel {
                                Text("KIỂM THỬ LỊCH SỬ").font(.caption.weight(.bold)).tracking(1)
                                Text("Mô phỏng theo thứ tự phiên, tách khỏi thắng thua trực tiếp")
                                    .font(.caption)
                                ForEach(replay.reversed().prefix(8)) { item in
                                    HStack {
                                        Text("#\(item.phien)").monospacedDigit()
                                        Spacer()
                                        Text(item.du_doan + " → " + item.ket_qua)
                                        Text(item.status)
                                            .foregroundStyle(item.status == "Thắng" ? Color(red: 0.09, green: 0.44, blue: 0.32) : Color(red: 0.66, green: 0.20, blue: 0.30))
                                    }
                                    .font(.caption)
                                }
                            }
                        }
                        panel {
                            Text("NHỊP CẦU GẦN ĐÂY").font(.caption.weight(.bold)).tracking(1)
                            Text("Bệt \(forecast.result?.streak_side ?? "—") · \(forecast.result?.streak ?? 0) phiên")
                            Text("Kiểm thử \(forecast.result?.tested ?? 0) phiên · mốc \(forecast.result?.baseline_accuracy ?? 0, specifier: "%.1f")%")
                                .font(.caption)
                            if let patterns = forecast.result?.patterns {
                                ForEach(patterns.prefix(5)) { pattern in
                                    HStack {
                                        Text(pattern.name).lineLimit(1)
                                        Spacer(minLength: 12)
                                        Text("T \(pattern.tai) · X \(pattern.xiu)")
                                            .monospacedDigit()
                                    }
                                    .font(.subheadline)
                                }
                            }
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
            .preferredColorScheme(.light)
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
        .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 19))
    }
    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 23))
            .overlay(RoundedRectangle(cornerRadius: 23).strokeBorder(.white.opacity(0.7), lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 7)
    }
}
