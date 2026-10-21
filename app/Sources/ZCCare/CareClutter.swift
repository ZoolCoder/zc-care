import AppKit
import SwiftUI
import ZCCareCore

// MARK: My Clutter

struct ClutterView: View {
    @Bindable var care: Care

    var body: some View {
        VStack(spacing: 0) {
            CareHeader(title: "My Clutter", subtitle: care.clutter > 0 ? "\(Store.bytes(care.clutter)) in large files, duplicates, old downloads and installers"
                                                        : care.scanningFiles ? "Looking through your home folder…"
                                                        : "No large files, duplicates, old downloads or installers",
                   busy: care.scanningFiles || care.findingDuplicates, action: ("Rescan", { Task { await care.scanFiles() } }))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    CareSection("Large Files") {
                        if care.largeFiles.isEmpty {
                            empty("No file over \(Store.bytes(Care.largeFile)) outside Library.")
                        }
                        ForEach(care.largeFiles) { FileRow(care: care, file: $0) }
                    }
                    CareSection("Duplicates") {
                        if care.duplicates.isEmpty {
                            empty("No two files over \(Store.bytes(Care.duplicateFile)) hold the same bytes.",
                                  looking: care.findingDuplicates ? "Comparing files of the same size…" : nil)
                        }
                        ForEach(care.duplicates) { group in
                            VStack(alignment: .leading, spacing: 0) {
                                HStack {
                                    Text("\(group.files[0].name) · \(group.files.count) copies, \(Store.bytes(group.wasted)) wasted")
                                        .font(.callout.weight(.semibold))
                                    Spacer()
                                    Button("Keep Oldest") { Task { await care.keepOldest(group) } }.controlSize(.small)
                                        .disabled(care.store.busy != nil)
                                }
                                .padding(.horizontal, 10)
                                .padding(.top, 8)
                                ForEach(group.files) { file in
                                    FileRow(care: care, file: file, showsFolder: true, flag: file == group.keeper ? "Stays" : nil)
                                }
                            }
                        }
                    }
                    CareSection("Similar Images") {
                        if let groups = care.similar {
                            if groups.isEmpty {
                                Text("No two photos look alike.").foregroundStyle(.secondary).padding(10)
                            }
                            ForEach(groups) { group in
                                VStack(alignment: .leading, spacing: 0) {
                                    HStack {
                                        Text("\(group.best.name) · \(group.files.count) look alike, \(Store.bytes(group.wasted)) to free")
                                            .font(.callout.weight(.semibold))
                                        Spacer()
                                        Button("Trash Others") { Task { await care.trashOthers(group) } }.controlSize(.small)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.top, 8)
                                    ForEach(group.files) { file in
                                        FileRow(care: care, file: file, showsFolder: true, flag: file == group.best ? "Best" : nil)
                                    }
                                }
                            }
                        }
                        HStack {
                            Text(care.scanningImages ? "Comparing photos in Pictures, Desktop, Downloads and Documents…"
                                 : "Photos that look alike: bursts, edits and resaved copies. The one with the most pixels is kept.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if care.scanningImages { ProgressView().controlSize(.small) }
                            Button(care.similar == nil ? "Find Similar Images" : "Look Again") { Task { await care.scanImages() } }
                                .controlSize(.small)
                                .disabled(care.scanningImages)
                        }
                        .padding(10)
                    }
                    CareSection("Old Downloads") {
                        if care.oldDownloads.isEmpty {
                            empty("Nothing in Downloads older than 30 days.")
                        }
                        ForEach(care.oldDownloads) { FileRow(care: care, file: $0, dateLabel: "added") }
                    }
                    CareSection("Installers") {
                        if care.diskImages.isEmpty {
                            empty("No disk images or packages in Downloads or on the Desktop.")
                        }
                        ForEach(care.diskImages) { FileRow(care: care, file: $0, dateLabel: "added") }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 70)
            }
        }
    }

    private func empty(_ text: String, looking: String? = nil) -> some View {
        Text(care.scanningFiles ? "Looking through your home folder…" : looking ?? text)
            .foregroundStyle(.secondary).padding(10)
    }
}
