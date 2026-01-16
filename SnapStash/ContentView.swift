//
//  ContentView.swift
//  SnapStash
//
//  Created by Nasser Alsobeie on 04/01/2026.
//
import SwiftUI
import AVKit

struct SnapchatData: Codable, Sendable {
    let savedMedia: [Memory]
    
    enum CodingKeys: String, CodingKey {
        case savedMedia = "Saved Media"
    }
}

struct Memory: Codable, Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    let date: String
    let mediaType: String
    let downloadLink: String
    let mediaDownloadUrl: String?
    
    init(id: UUID = UUID(), date: String, mediaType: String, downloadLink: String, mediaDownloadUrl: String? = nil) {
        self.id = id
        self.date = date
        self.mediaType = mediaType
        self.downloadLink = downloadLink
        self.mediaDownloadUrl = mediaDownloadUrl
    }
    
    enum CodingKeys: String, CodingKey {
        case id
        case date = "Date"
        case mediaType = "Media Type"
        case downloadLink = "Download Link"
        case mediaDownloadUrl = "Media Download Url"
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.date = try container.decode(String.self, forKey: .date)
        self.mediaType = try container.decode(String.self, forKey: .mediaType)
        self.downloadLink = try container.decode(String.self, forKey: .downloadLink)
        self.mediaDownloadUrl = try container.decodeIfPresent(String.self, forKey: .mediaDownloadUrl)
    }
    
    var isVideo: Bool {
        return mediaType.lowercased() == "video"
    }
    
    var dateObject: Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: date) ?? Date()
    }
    
    var year: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return formatter.string(from: dateObject)
    }
    
    var month: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM"
        return formatter.string(from: dateObject)
    }
    
    var filename: String {
        let safeDate = date.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: " ", with: "_")
        let ext = isVideo ? "mp4" : "jpg"
        return "\(safeDate).\(ext)"
    }
    
    var effectiveUrl: URL? {
        if let direct = mediaDownloadUrl, let url = URL(string: direct) {
            return url
        }
        return URL(string: downloadLink)
    }
}

struct YearSection: Identifiable, Equatable, Sendable {
    let id: String
    let months: [MonthSection]
}

struct MonthSection: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let memories: [Memory]
}

@MainActor
class ThumbnailLoader: ObservableObject {
    @Published var image: NSImage? = nil
    @Published var isLoading = false
    
    private var task: Task<Void, Never>?
    
    func load(for memory: Memory) {
        guard let url = memory.effectiveUrl, image == nil else { return }
        
        task?.cancel()
        isLoading = true
        
        task = Task {
            if memory.isVideo {
                let asset = AVURLAsset(url: url)
                let gen = AVAssetImageGenerator(asset: asset)
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 300, height: 300)
                
                do {
                    let (cgImage, _) = try await gen.image(at: .zero)
                    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    self.image = nsImage
                } catch { }
            } else {
                if let data = try? Data(contentsOf: url), let nsImage = NSImage(data: data) {
                    self.image = nsImage
                }
            }
            self.isLoading = false
        }
    }
}

@MainActor
class MacDownloadManager: ObservableObject {
    @Published var sections: [YearSection] = []
    @Published var allMemories: [Memory] = []
    
    @Published var isProcessing = false
    @Published var isDownloading = false
    @Published var progress: Double = 0.0
    @Published var statusMessage: String = "Import JSON to start"
    @Published var showSuccessAlert = false
    
    func loadJSON(url: URL) {
        isProcessing = true
        statusMessage = "Processing large file..."
        
        Task {
            do {
                let accessing = url.startAccessingSecurityScopedResource()
                let data = try Data(contentsOf: url)
                if accessing { url.stopAccessingSecurityScopedResource() }
                
                let result = try JSONDecoder().decode(SnapchatData.self, from: data)
                let rawMemories = result.savedMedia
                
                let processedSections = await MacDownloadManager.processMemories(rawMemories)
                
                self.sections = processedSections
                self.allMemories = rawMemories
                self.statusMessage = "Loaded \(rawMemories.count) memories."
                self.isProcessing = false
                
            } catch {
                self.statusMessage = "Error: \(error.localizedDescription)"
                self.isProcessing = false
            }
        }
    }
    
    private static func processMemories(_ rawMemories: [Memory]) async -> [YearSection] {
        let groupedByYear = Dictionary(grouping: rawMemories, by: { $0.year })
        let sortedYears = groupedByYear.keys.sorted(by: >)
        
        var newSections: [YearSection] = []
        
        for year in sortedYears {
            let memoriesInYear = groupedByYear[year]!
            let groupedByMonth = Dictionary(grouping: memoriesInYear, by: { $0.month })
            
            let sortedMonthNames = groupedByMonth.keys.sorted { m1, m2 in
                let d1 = groupedByMonth[m1]?.first?.date ?? ""
                let d2 = groupedByMonth[m2]?.first?.date ?? ""
                return d1 > d2
            }
            
            var monthSections: [MonthSection] = []
            for month in sortedMonthNames {
                let items = groupedByMonth[month] ?? []
                monthSections.append(MonthSection(id: "\(month)-\(year)", name: month, memories: items))
            }
            
            newSections.append(YearSection(id: year, months: monthSections))
        }
        return newSections
    }
    
    func downloadSelected(memories: [Memory], to folderURL: URL) {
        guard !memories.isEmpty else { return }
        
        guard folderURL.startAccessingSecurityScopedResource() else {
            statusMessage = "Permission error: Check App Sandbox settings."
            return
        }
        
        isDownloading = true
        progress = 0.0
        
        Task {
            let total = Double(memories.count)
            var currentProgress = 0.0
            
            let maxConcurrent = 5
            var iterator = memories.makeIterator()
            
            await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<maxConcurrent {
                    if let next = iterator.next() {
                        group.addTask {
                            await MacDownloadManager.downloadSingle(next, to: folderURL)
                        }
                    }
                }
                
                for await result in group {
                    if result { currentProgress += 1 }
                    self.progress = currentProgress / total
                    self.statusMessage = "Saving \(Int(currentProgress)) of \(Int(total))..."
                    
                    if let next = iterator.next() {
                        group.addTask {
                            await MacDownloadManager.downloadSingle(next, to: folderURL)
                        }
                    }
                }
            }
            
            folderURL.stopAccessingSecurityScopedResource()
            self.isDownloading = false
            self.statusMessage = "Saved to \(folderURL.lastPathComponent)"
            self.showSuccessAlert = true
        }
    }
    
    private static func downloadSingle(_ memory: Memory, to folderURL: URL) async -> Bool {
        let destination = folderURL.appendingPathComponent(memory.filename)
        if FileManager.default.fileExists(atPath: destination.path) { return true }
        
        guard let url = memory.effectiveUrl else { return false }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            try data.write(to: destination)
            
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            if let dateObj = formatter.date(from: memory.date) {
                try FileManager.default.setAttributes([.creationDate: dateObj], ofItemAtPath: destination.path)
            }
            return true
        } catch {
            return false
        }
    }
}

struct ContentView: View {
    @StateObject var manager = MacDownloadManager()
    @State private var showFileImporter = false
    @State private var selection = Set<Memory>()
    @State private var previewMemory: Memory?
    @State private var isSelectionMode = false
    
    let columns = [GridItem(.adaptive(minimum: 140, maximum: 160), spacing: 10)]
    
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    if !isSelectionMode {
                        Button(action: { showFileImporter = true }) {
                            Label("Import JSON", systemImage: "square.and.arrow.down")
                        }
                        
                        if !manager.sections.isEmpty {
                            Divider().frame(height: 20)
                            Button("Select") { isSelectionMode = true }
                        }
                    } else {
                        Button("Cancel") {
                            isSelectionMode = false
                            selection.removeAll()
                        }
                        .keyboardShortcut(.cancelAction)
                        
                        Divider().frame(height: 20)
                        
                        Button("Select All") { selection = Set(manager.allMemories) }
                        Button("Deselect All") { selection.removeAll() }
                        
                        Spacer()
                        
                        Text("\(selection.count) selected").foregroundColor(.secondary)
                        
                        Button(action: saveSelected) {
                            Label("Download Selected", systemImage: "arrow.down.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(selection.isEmpty)
                    }
                    Spacer()
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                
                Divider()
                
                if manager.isProcessing {
                    VStack {
                        Spacer()
                        ProgressView()
                        Text("Processing Data...").padding(.top)
                        Spacer()
                    }
                } else if manager.sections.isEmpty {
                    VStack(spacing: 15) {
                        Spacer()
                        Image(systemName: "photo.stack").font(.system(size: 50)).foregroundColor(.gray)
                        Text("Import 'memories_history.json' to start").foregroundColor(.secondary)
                        Spacer()
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            ForEach(manager.sections) { yearSection in
                                YearGroupView(
                                    yearSection: yearSection,
                                    isSelectionMode: isSelectionMode,
                                    selection: $selection,
                                    onPreview: { memory in previewMemory = memory }
                                )
                            }
                        }
                        .padding(.bottom)
                    }
                }
                
                HStack {
                    Text(manager.statusMessage).font(.caption)
                    Spacer()
                }
                .padding(8)
                .background(Color(NSColor.windowBackgroundColor))
            }
            .disabled(manager.isDownloading)
            
            if manager.isDownloading {
                Color.black.opacity(0.5)
                VStack(spacing: 20) {
                    ProgressView().scaleEffect(1.5)
                    Text("Saving Memories...").font(.title2).bold()
                    Text(manager.statusMessage)
                    ProgressView(value: manager.progress).frame(width: 200)
                }
                .padding(40)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(NSColor.windowBackgroundColor)))
                .shadow(radius: 20)
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): manager.loadJSON(url: url)
            case .failure(let error): manager.statusMessage = "Error: \(error.localizedDescription)"
            }
        }
        .sheet(item: $previewMemory) { memory in
            PreviewView(memory: memory).frame(width: 800, height: 600)
        }
        .alert(isPresented: $manager.showSuccessAlert) {
            Alert(title: Text("Success"), message: Text("All files saved successfully."), dismissButton: .default(Text("OK")))
        }
    }
    
    func saveSelected() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save Files Here"
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                manager.downloadSelected(memories: Array(selection), to: url)
            }
        }
    }
}

struct YearGroupView: View {
    let yearSection: YearSection
    let isSelectionMode: Bool
    @Binding var selection: Set<Memory>
    let onPreview: (Memory) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(yearSection.id)
                .font(.title2)
                .bold()
                .padding(.leading)
                .padding(.top)
            
            ForEach(yearSection.months) { monthSection in
                MonthGroupView(
                    monthSection: monthSection,
                    isSelectionMode: isSelectionMode,
                    selection: $selection,
                    onPreview: onPreview
                )
            }
        }
    }
}

struct MonthGroupView: View {
    let monthSection: MonthSection
    let isSelectionMode: Bool
    @Binding var selection: Set<Memory>
    let onPreview: (Memory) -> Void
    
    let columns = [GridItem(.adaptive(minimum: 140, maximum: 160), spacing: 10)]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(monthSection.name)
                .font(.headline)
                .foregroundColor(.secondary)
                .padding(.leading)
            
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(monthSection.memories) { memory in
                    MemoryGridItem(
                        memory: memory,
                        isSelected: selection.contains(memory),
                        showCheckbox: isSelectionMode
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isSelectionMode {
                            if selection.contains(memory) {
                                selection.remove(memory)
                            } else {
                                selection.insert(memory)
                            }
                        } else {
                            onPreview(memory)
                        }
                    }
                }
            }
            .padding(.horizontal)
        }
    }
}

struct MemoryGridItem: View {
    let memory: Memory
    let isSelected: Bool
    let showCheckbox: Bool
    @StateObject private var thumbLoader = ThumbnailLoader()
    
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image = thumbLoader.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Color(NSColor.controlBackgroundColor)
                        if thumbLoader.isLoading {
                            ProgressView().scaleEffect(0.5)
                        } else {
                            Image(systemName: memory.isVideo ? "video" : "photo")
                                .foregroundColor(.gray)
                        }
                    }
                }
            }
            .frame(width: 140, height: 140)
            .clipped()
            
            if memory.isVideo {
                Image(systemName: "play.circle.fill")
                    .foregroundColor(.white)
                    .shadow(radius: 2)
                    .padding(5)
                    .alignmentGuide(.bottom) { d in d[.bottom] + (showCheckbox ? 25 : 0) }
            }
            
            if showCheckbox {
                ZStack {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.blue)
                            .font(.title2)
                            .background(Circle().fill(Color.white))
                    } else {
                        Image(systemName: "circle")
                            .foregroundColor(.white)
                            .font(.title2)
                            .shadow(radius: 2)
                    }
                }
                .padding(5)
            }
        }
        .frame(width: 140, height: 140)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected && showCheckbox ? Color.blue : Color.gray.opacity(0.3), lineWidth: isSelected ? 3 : 1)
        )
        .onAppear {
            thumbLoader.load(for: memory)
        }
    }
}

struct PreviewView: View {
    let memory: Memory
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(memory.date).font(.headline)
                Spacer()
                Button("Close") { presentationMode.wrappedValue.dismiss() }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            ZStack {
                Color.black
                if let url = memory.effectiveUrl {
                    if memory.isVideo {
                        MacPlayerView(url: url)
                    } else {
                        AsyncImage(url: url) { image in
                            image.resizable().aspectRatio(contentMode: .fit)
                        } placeholder: {
                            ProgressView()
                        }
                    }
                } else {
                    Text("Invalid Media URL").foregroundColor(.white)
                }
            }
        }
    }
}

struct MacPlayerView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .floating
        playerView.player = AVPlayer(url: url)
        playerView.player?.play()
        return playerView
    }
    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}
