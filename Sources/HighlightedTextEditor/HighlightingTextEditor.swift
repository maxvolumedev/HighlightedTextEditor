//
//  HighlightingTextEditor.swift
//
//
//  Created by Kyle Nazario on 8/31/20.
//

import SwiftUI

#if os(macOS)
import AppKit

public typealias SystemFontAlias = NSFont
public typealias SystemColorAlias = NSColor
public typealias SymbolicTraits = NSFontDescriptor.SymbolicTraits
public typealias SystemTextView = NSTextView
public typealias SystemScrollView = NSScrollView

let defaultEditorFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
let defaultEditorTextColor = NSColor.labelColor

#else
import UIKit

public typealias SystemFontAlias = UIFont
public typealias SystemColorAlias = UIColor
public typealias SymbolicTraits = UIFontDescriptor.SymbolicTraits
public typealias SystemTextView = UITextView
public typealias SystemScrollView = UIScrollView

let defaultEditorFont = UIFont.preferredFont(forTextStyle: .body)
let defaultEditorTextColor = UIColor.label

#endif

public struct TextFormattingRule {
    public typealias AttributedKeyCallback = (String, Range<String.Index>) -> Any

    let key: NSAttributedString.Key?
    let calculateValue: AttributedKeyCallback?
    let fontTraits: SymbolicTraits

    // ------------------- convenience ------------------------

    public init(key: NSAttributedString.Key, value: Any) {
        self.init(key: key, calculateValue: { _, _ in value }, fontTraits: [])
    }

    public init(key: NSAttributedString.Key, calculateValue: @escaping AttributedKeyCallback) {
        self.init(key: key, calculateValue: calculateValue, fontTraits: [])
    }

    public init(fontTraits: SymbolicTraits) {
        self.init(key: nil, fontTraits: fontTraits)
    }

    // ------------------ most powerful initializer ------------------

    init(
        key: NSAttributedString.Key? = nil,
        calculateValue: AttributedKeyCallback? = nil,
        fontTraits: SymbolicTraits = []
    ) {
        self.key = key
        self.calculateValue = calculateValue
        self.fontTraits = fontTraits
    }
}

public struct HighlightRule {
    let pattern: NSRegularExpression

    let formattingRules: [TextFormattingRule]

    // ------------------- convenience ------------------------

    public init(pattern: NSRegularExpression, formattingRule: TextFormattingRule) {
        self.init(pattern: pattern, formattingRules: [formattingRule])
    }

    // ------------------ most powerful initializer ------------------

    public init(pattern: NSRegularExpression, formattingRules: [TextFormattingRule]) {
        self.pattern = pattern
        self.formattingRules = formattingRules
    }
}

internal protocol HighlightingTextEditor {
    var text: String { get set }
    var highlightRules: [HighlightRule] { get }
}

public typealias OnSelectionChangeCallback = ([NSRange]) -> Void
public typealias IntrospectCallback = (_ editor: HighlightedTextEditor.Internals) -> Void
public typealias EmptyCallback = () -> Void
public typealias OnCommitCallback = EmptyCallback
public typealias OnEditingChangedCallback = EmptyCallback
public typealias OnTextChangeCallback = (_ editorContent: String) -> Void
public typealias OnPasteCallback = (_ pasteboard: NSPasteboard) -> String?
public typealias ImageProviderCallback = (_ filename: String) -> SystemImageAlias?

#if os(macOS)
public typealias SystemImageAlias = NSImage
#else
public typealias SystemImageAlias = UIImage
#endif

extension HighlightingTextEditor {
    var placeholderFont: SystemColorAlias { SystemColorAlias() }

    static func getHighlightedText(
        text: String,
        highlightRules: [HighlightRule],
        imageProvider: ImageProviderCallback? = nil,
        maxImageWidth: CGFloat? = nil
    ) -> NSMutableAttributedString {
        // First, process markdown images if provider is available
        var processedText = text
        var imageAttachments: [(range: NSRange, attachment: NSTextAttachment)] = []

        if let imageProvider = imageProvider {
            // Regex to match markdown image syntax: ![alt](filename)
            let imagePattern = try! NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#, options: [])
            let matches = imagePattern.matches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count))

            // Process matches in reverse to maintain correct ranges
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3 else { continue }

                let filenameRange = match.range(at: 2)
                guard let filenameSwiftRange = Range(filenameRange, in: text) else { continue }
                let filename = String(text[filenameSwiftRange])

                // Try to load the image
                if let image = imageProvider(filename) {
                    // Size the image appropriately
                    let sizedImage = sizeImage(image, maxWidth: maxImageWidth)

                    // Create text attachment
                    let attachment = NSTextAttachment()
                    attachment.image = sizedImage

                    // Insert attachment character before the markdown syntax
                    let insertPosition = match.range.location
                    let attachmentString = NSAttributedString(attachment: attachment)

                    // We'll insert this after creating the attributed string
                    imageAttachments.append((
                        range: NSRange(location: insertPosition, length: 0),
                        attachment: attachment
                    ))
                }
            }
        }

        let highlightedString = NSMutableAttributedString(string: processedText)
        let all = NSRange(location: 0, length: processedText.utf16.count)

        let editorFont = defaultEditorFont
        let editorTextColor = defaultEditorTextColor

        highlightedString.addAttribute(.font, value: editorFont, range: all)
        highlightedString.addAttribute(.foregroundColor, value: editorTextColor, range: all)

        highlightRules.forEach { rule in
            let matches = rule.pattern.matches(in: processedText, options: [], range: all)
            matches.forEach { match in
                rule.formattingRules.forEach { formattingRule in

                    var font = SystemFontAlias()
                    highlightedString.enumerateAttributes(in: match.range, options: []) { attributes, _, _ in
                        let fontAttribute = attributes.first { $0.key == .font }!
                        // swiftlint:disable:next force_cast
                        let previousFont = fontAttribute.value as! SystemFontAlias
                        font = previousFont.with(formattingRule.fontTraits)
                    }
                    highlightedString.addAttribute(.font, value: font, range: match.range)

                    let matchRange = Range<String.Index>(match.range, in: processedText)!
                    let matchContent = String(processedText[matchRange])
                    guard let key = formattingRule.key,
                          let calculateValue = formattingRule.calculateValue else { return }
                    highlightedString.addAttribute(
                        key,
                        value: calculateValue(matchContent, matchRange),
                        range: match.range
                    )
                }
            }
        }

        // Insert image attachments
        for (range, attachment) in imageAttachments.reversed() {
            let attachmentString = NSMutableAttributedString(attachment: attachment)
            // Add newline after image
            attachmentString.append(NSAttributedString(string: "\n"))
            highlightedString.insert(attachmentString, at: range.location)
        }

        return highlightedString
    }

    private static func sizeImage(_ image: SystemImageAlias, maxWidth: CGFloat?) -> SystemImageAlias {
        let maxWidth = maxWidth ?? 800
        let imageSize = image.size

        // If image is already smaller than max, return as-is
        if imageSize.width <= maxWidth && imageSize.height <= maxWidth {
            return image
        }

        // Calculate scaled size maintaining aspect ratio
        var newSize = imageSize
        if imageSize.width > maxWidth || imageSize.height > maxWidth {
            let widthRatio = maxWidth / imageSize.width
            let heightRatio = maxWidth / imageSize.height
            let scaleFactor = min(widthRatio, heightRatio)

            newSize = CGSize(
                width: imageSize.width * scaleFactor,
                height: imageSize.height * scaleFactor
            )
        }

        #if os(macOS)
        let resizedImage = NSImage(size: newSize)
        resizedImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize))
        resizedImage.unlockFocus()
        return resizedImage
        #else
        UIGraphicsBeginImageContextWithOptions(newSize, false, 0.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let resizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return resizedImage ?? image
        #endif
    }
}
