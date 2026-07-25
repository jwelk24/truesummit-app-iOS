import Foundation
import Vision
import FoundationModels
import CoreGraphics
import ImageIO

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Turns a photo of a receipt into a structured `ReceiptDraft` using on-device
/// Vision text recognition and Apple's `FoundationModels` framework. Nothing
/// leaves the device.
struct ReceiptScanner {

    // MARK: Structured output

    @Generable(description: "A parsed receipt with line items and totals.")
    struct ReceiptDraft: Equatable {
        @Guide(description: "Name of the merchant printed on the receipt.")
        var merchant: String

        @Guide(description: "Date the receipt was issued, formatted YYYY-MM-DD. If unknown, use today's date.")
        var date: String

        @Guide(description: "Each purchased line item with a short description and its total price.", .maximumCount(40))
        var lineItems: [LineItem]

        @Guide(description: "Subtotal before tax and tip, if present. 0 if not visible.")
        var subtotal: Double

        @Guide(description: "Tax amount, 0 if not visible.")
        var tax: Double

        @Guide(description: "Tip amount, 0 if not visible.")
        var tip: Double

        @Guide(description: "Grand total charged.")
        var total: Double

        @Guide(description: "Three-letter currency code (e.g. USD).")
        var currencyCode: String
    }

    @Generable(description: "A single purchased item on a receipt.")
    struct LineItem: Equatable {
        @Guide(description: "Short description of the item.")
        var name: String

        @Guide(description: "Total charged for this line item (quantity × unit price).")
        var amount: Double
    }

    // MARK: Pipeline

    enum ScanError: LocalizedError {
        case invalidImage
        case noTextFound
        case aiUnavailable

        var errorDescription: String? {
            switch self {
            case .invalidImage: return "Could not read the selected image."
            case .noTextFound: return "Couldn't find any text on this receipt — try a clearer photo."
            case .aiUnavailable: return "Apple Intelligence isn't available on this device, so the receipt can't be parsed automatically."
            }
        }
    }

    /// Full pipeline: image data → OCR → AI-structured draft.
    static func scan(imageData: Data) async throws -> ReceiptDraft {
        guard let cgImage = makeCGImage(from: imageData) else {
            throw ScanError.invalidImage
        }
        let text = try await extractText(from: cgImage)
        guard !text.isEmpty else { throw ScanError.noTextFound }
        guard SystemLanguageModel.default.isAvailable else { throw ScanError.aiUnavailable }
        return try await parse(rawText: text)
    }

    // MARK: OCR

    static func extractText(from cgImage: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: AI structuring

    static func parse(rawText: String) async throws -> ReceiptDraft {
        let instructions = """
        You convert a noisy block of OCR'd receipt text into a structured object. \
        Only include line items that look like actual purchased products or services — \
        ignore phone numbers, store addresses, loyalty messages, and footer text. \
        Use the totals printed on the receipt; do not invent or recompute numbers. \
        If a field isn't on the receipt, use 0 or today's date as appropriate.
        """
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: rawText, generating: ReceiptDraft.self)
        return response.content
    }

    // MARK: Image helpers

    static func makeCGImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
