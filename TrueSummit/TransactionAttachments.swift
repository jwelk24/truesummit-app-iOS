import SwiftUI
import SwiftData
import PhotosUI

// MARK: - Image processing

enum AttachmentImage {
    /// Downscales to a sane size and recompresses so receipts don't bloat
    /// the store (a 12MP photo becomes a few hundred KB).
    static func process(_ data: Data, maxDimension: CGFloat = 1600) -> Data? {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        let largest = max(image.size.width, image.size.height)
        guard largest > maxDimension else {
            return image.jpegData(compressionQuality: 0.7)
        }
        let scale = maxDimension / largest
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return resized.jpegData(compressionQuality: 0.7)
        #else
        return data
        #endif
    }
}

// MARK: - Editor section

/// "Receipts" section for TransactionEditor. Cancel-safe: newly picked images
/// and deletions of existing attachments are staged in bindings and only
/// applied by the editor's save().
struct AttachmentsEditorSection: View {
    let existing: [TransactionAttachmentModel]
    @Binding var pendingImages: [Data]
    @Binding var removedIDs: Set<UUID>

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var viewing: AttachmentPreview?

    private struct AttachmentPreview: Identifiable {
        let id: String
        let data: Data
        /// Existing attachment id when this previews a saved attachment.
        let existingID: UUID?
        /// Index into pendingImages when this previews a staged image.
        let pendingIndex: Int?
    }

    private var visibleExisting: [TransactionAttachmentModel] {
        existing.filter { !removedIDs.contains($0.id) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        Section {
            if !visibleExisting.isEmpty || !pendingImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(visibleExisting) { attachment in
                            thumbnail(attachment.imageData)
                                .onTapGesture {
                                    viewing = AttachmentPreview(
                                        id: attachment.id.uuidString,
                                        data: attachment.imageData,
                                        existingID: attachment.id,
                                        pendingIndex: nil
                                    )
                                }
                        }
                        ForEach(Array(pendingImages.enumerated()), id: \.offset) { index, data in
                            thumbnail(data)
                                .overlay(alignment: .topTrailing) {
                                    Image(systemName: "clock.badge")
                                        .font(.caption2)
                                        .padding(3)
                                        .background(.thinMaterial, in: Circle())
                                        .padding(2)
                                }
                                .onTapGesture {
                                    viewing = AttachmentPreview(
                                        id: "pending-\(index)",
                                        data: data,
                                        existingID: nil,
                                        pendingIndex: index
                                    )
                                }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            PhotosPicker(selection: $pickerItems, maxSelectionCount: 5, matching: .images) {
                Label("Add Receipt Photo", systemImage: "paperclip")
            }
        } header: {
            Text("Receipts")
        } footer: {
            Text("Stored only on this device — receipts never sync to the cloud.")
        }
        .summitRowBackground()
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                for item in items {
                    if let raw = try? await item.loadTransferable(type: Data.self),
                       let processed = AttachmentImage.process(raw) {
                        pendingImages.append(processed)
                    }
                }
                pickerItems = []
            }
        }
        .sheet(item: $viewing) { preview in
            AttachmentViewer(data: preview.data) {
                if let existingID = preview.existingID {
                    removedIDs.insert(existingID)
                } else if let index = preview.pendingIndex, pendingImages.indices.contains(index) {
                    pendingImages.remove(at: index)
                }
                viewing = nil
            }
        }
    }

    @ViewBuilder
    private func thumbnail(_ data: Data) -> some View {
        #if canImport(UIKit)
        if let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        #endif
    }
}

// MARK: - Full-screen viewer

private struct AttachmentViewer: View {
    let data: Data
    var onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                #if canImport(UIKit)
                if let image = UIImage(data: data) {
                    ScrollView([.horizontal, .vertical]) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .containerRelativeFrame([.horizontal, .vertical])
                    }
                } else {
                    Text("Couldn't load image.")
                        .foregroundStyle(.secondary)
                }
                #endif
            }
            .navigationTitle("Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: SharedReceipt(data: data), preview: SharePreview("Receipt"))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Transferable wrapper so ShareLink exports the JPEG bytes as an image file.
private struct SharedReceipt: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .jpeg) { receipt in
            receipt.data
        }
    }
}
