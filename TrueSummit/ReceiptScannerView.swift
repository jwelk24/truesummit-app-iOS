import SwiftUI
import SwiftData
import PhotosUI
import FoundationModels

/// "Scan Receipt" flow: pick a photo, run OCR + on-device AI to extract a
/// `ReceiptDraft`, let the user review/edit, then save as a transaction with
/// per-line-item splits.
struct ReceiptScannerView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query private var accounts: [AccountModel]
    @Query(sort: \CategoryModel.sort) private var categories: [CategoryModel]

    @State private var photoSelection: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var draft: ReceiptScanner.ReceiptDraft?
    @State private var phase: Phase = .pickPhoto
    @State private var errorMessage: String?

    @State private var accountID: UUID?
    @State private var transactionDate: Date = .now
    @State private var lineItemDrafts: [LineItemDraft] = []
    @State private var merchant: String = ""
    @State private var total: Decimal = 0

    enum Phase {
        case pickPhoto, scanning, review
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Scan Receipt")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    if phase == .review {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") { save() }
                                .disabled(!canSave)
                        }
                    }
                }
                .alert("Scan Error", isPresented: errorBinding, presenting: errorMessage) { _ in
                    Button("OK") { errorMessage = nil; phase = .pickPhoto }
                } message: { Text($0) }
        }
        .onChange(of: photoSelection) { _, item in
            Task { await handleSelection(item) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .pickPhoto:
            pickPhotoView
        case .scanning:
            scanningView
        case .review:
            reviewView
        }
    }

    // MARK: Pick photo

    private var pickPhotoView: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "doc.text.viewfinder")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Photograph a receipt and TrueSummit will extract the merchant, line items, and totals on-device.")
                .multilineTextAlignment(.center)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            PhotosPicker(selection: $photoSelection, matching: .images, photoLibrary: .shared()) {
                Label("Choose Receipt Photo", systemImage: "photo.on.rectangle")
            }
            .buttonStyle(.borderedProminent)
            if !SystemLanguageModel.default.isAvailable {
                Label("Apple Intelligence is unavailable — receipt scanning needs it to structure the OCR text.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
    }

    // MARK: Scanning

    private var scanningView: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Reading the receipt…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: Review

    private var reviewView: some View {
        Form {
            Section("Header") {
                TextField("Merchant", text: $merchant)
                DatePicker("Date", selection: $transactionDate, displayedComponents: .date)
                Picker("Account", selection: $accountID) {
                    Text("Choose…").tag(UUID?.none)
                    ForEach(accounts) { acct in
                        Text(acct.name).tag(UUID?.some(acct.id))
                    }
                }
                LabeledContent("Total") {
                    Text(currencyString(total))
                        .bold()
                }
            }

            Section {
                ForEach($lineItemDrafts) { $item in
                    HStack {
                        TextField("Item", text: $item.name)
                        TextField("Amount", value: $item.amount, format: .number)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                        Picker("", selection: $item.categoryID) {
                            Text("—").tag(UUID?.none)
                            ForEach(categories) { cat in
                                Text(cat.name).tag(UUID?.some(cat.id))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 120)
                    }
                }
                .onDelete { offsets in
                    lineItemDrafts.remove(atOffsets: offsets)
                    recomputeTotal()
                }
                Button {
                    lineItemDrafts.append(LineItemDraft(name: "", amount: 0, categoryID: nil))
                } label: {
                    Label("Add line item", systemImage: "plus.circle")
                }
            } header: {
                Text("Line Items")
            } footer: {
                Text("Each line becomes a split on the saved transaction. Pick a category per line.")
            }
        }
        .onChange(of: lineItemDrafts) { _, _ in recomputeTotal() }
    }

    // MARK: Actions

    private func handleSelection(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        phase = .scanning
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw ReceiptScanner.ScanError.invalidImage
            }
            imageData = data
            let parsed = try await ReceiptScanner.scan(imageData: data)
            applyDraft(parsed)
            phase = .review
        } catch {
            errorMessage = error.localizedDescription
            phase = .pickPhoto
        }
    }

    private func applyDraft(_ parsed: ReceiptScanner.ReceiptDraft) {
        draft = parsed
        merchant = parsed.merchant
        if let parsedDate = isoDate(parsed.date) {
            transactionDate = parsedDate
        }
        lineItemDrafts = parsed.lineItems.map {
            LineItemDraft(name: $0.name, amount: Decimal($0.amount), categoryID: nil)
        }
        if parsed.tax > 0 {
            lineItemDrafts.append(LineItemDraft(name: "Tax", amount: Decimal(parsed.tax), categoryID: nil))
        }
        if parsed.tip > 0 {
            lineItemDrafts.append(LineItemDraft(name: "Tip", amount: Decimal(parsed.tip), categoryID: nil))
        }
        recomputeTotal()
        if accountID == nil {
            accountID = accounts.first { $0.type == .checking || $0.type == .creditCard }?.id ?? accounts.first?.id
        }
    }

    private func recomputeTotal() {
        total = lineItemDrafts.reduce(Decimal.zero) { $0 + $1.amount }
    }

    private var canSave: Bool {
        accountID != nil && !merchant.isEmpty && total > 0
    }

    private func save() {
        guard let accountID,
              let account = accounts.first(where: { $0.id == accountID }) else { return }

        let tx = TransactionModel(
            date: transactionDate,
            amount: -total,
            merchant: merchant,
            account: account,
            category: nil
        )
        context.insert(tx)

        for item in lineItemDrafts where item.amount > 0 {
            let category = item.categoryID.flatMap { id in categories.first { $0.id == id } }
            let split = TransactionSplitModel(
                amount: -item.amount,
                memo: item.name,
                transaction: tx,
                category: category
            )
            context.insert(split)
        }
        try? context.save()
        dismiss()
    }

    // MARK: Helpers

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func isoDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: string)
    }

    private func currencyString(_ d: Decimal) -> String {
        let n = NSDecimalNumber(decimal: d)
        let f = NumberFormatter()
        f.numberStyle = .currency
        return f.string(from: n) ?? "$0"
    }
}

private struct LineItemDraft: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var amount: Decimal
    var categoryID: UUID?
}

#Preview {
    ReceiptScannerView()
        .modelContainer(for: [
            AccountModel.self, TransactionModel.self, TransactionSplitModel.self,
            CategoryModel.self, CategoryGroupModel.self
        ], inMemory: true)
}
