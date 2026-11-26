// © 2026 Phan Anh Khoi (Yanbi) · @axzy_anhkhoi
import Foundation
import SwiftUI

@_silgen_name("yanbi_analyze") private func rustAnalyze(_ input: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
@_silgen_name("yanbi_free") private func rustFree(_ output: UnsafeMutablePointer<CChar>)

private let endpoint = URL(string: "https://asbestos-promote-mississippi-wizard.trycloudflare.com/sunhot/api/tx/history")!

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
    let tested: Int
    let model_accuracy: Double
    let baseline_accuracy: Double
}

@MainActor final class Forecast: ObservableObject {
    @Published var result: Analysis?
    @Published var message = "Đang tải lịch sử..."
    @Published var isLoading = false

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
            let output = data.withUnsafeBytes { bytes -> Data? in
                guard let pointer = bytes.baseAddress else { return nil }
                var terminated = [CChar](repeating: 0, count: data.count + 1)
                terminated.withUnsafeMutableBytes { destination in destination.copyBytes(from: bytes) }
                return terminated.withUnsafeBufferPointer { buffer in
                    guard let input = buffer.baseAddress, let value = rustAnalyze(input) else { return nil }
                    defer { rustFree(value) }
                    return String(cString: value).data(using: .utf8)
                }
            }
            guard let output else { throw URLError(.cannotDecodeContentData) }
            result = try JSONDecoder().decode(Analysis.self, from: output)
            message = "Đã cập nhật \(Date.now.formatted(date: .omitted, time: .shortened))"
        } catch {
            message = "Không thể tải dữ liệu. Kéo xuống để thử lại."
        }
    }
}

@main struct YanbiApp: App {
    @AppStorage("darkMode") private var darkMode = true
    @StateObject private var forecast = Forecast()
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 16) {
                        HStack {
                            Text("Yanbi").font(.largeTitle.bold())
                            Spacer()
                            Toggle("Nền tối", isOn: $darkMode).labelsHidden().accessibilityLabel("Chế độ tối")
                        }
                        .padding(.horizontal)
                        card {
                            Text("PHIÊN \(forecast.result?.next ?? "—")").font(.caption).foregroundStyle(.secondary)
                            Text(forecast.result?.prediction ?? "Đang tải")
                                .font(.system(size: 48, weight: .bold, design: .rounded))
                                .minimumScaleFactor(0.65).lineLimit(1)
                            Text(forecast.result?.confidence == 0 ? "Chưa có tín hiệu đủ tin cậy" : "Ước lượng \(forecast.result!.confidence)% khi ra Tài/Xỉu")
                                .foregroundStyle(.secondary)
                        }
                        card {
                            Text("Thống kê \(forecast.result?.total ?? 0) phiên").font(.headline)
                            HStack {
                                count("Tài", forecast.result?.tai)
                                count("Xỉu", forecast.result?.xiu)
                                count("Bão", forecast.result?.bao)
                            }
                            Text("Bệt hiện tại: \(forecast.result?.streak_side ?? "—") \(forecast.result?.streak ?? 0)")
                                .font(.subheadline)
                            if let r = forecast.result {
                                Text("Xúc xắc (mặt 1–6): \(r.faces.map(String.init).joined(separator: " · "))")
                                    .font(.footnote).foregroundStyle(.secondary)
                                Text("Kiểm thử \(r.tested) phiên: mô hình \(r.model_accuracy, specifier: "%.2f")% · mốc \(r.baseline_accuracy, specifier: "%.2f")%")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        Text(forecast.message).font(.footnote).foregroundStyle(.secondary)
                        Link("Owner Yanbi · Tele @axzy_anhkhoi", destination: URL(string: "https://t.me/axzy_anhkhoi")!)
                            .font(.footnote)
                    }
                    .padding()
                }
                .refreshable { await forecast.refresh() }
                .toolbar { Button("Cập nhật", systemImage: "arrow.clockwise") { Task { await forecast.refresh() } }.disabled(forecast.isLoading) }
                .task { await forecast.refresh() }
                .navigationBarTitleDisplayMode(.inline)
            }
            .preferredColorScheme(darkMode ? .dark : .light)
        }
    }
    private func count(_ title: String, _ value: Int?) -> some View {
        VStack { Text("\(value ?? 0)").font(.title3.bold()); Text(title).font(.caption) }.frame(maxWidth: .infinity)
    }
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 25))
    }
}
