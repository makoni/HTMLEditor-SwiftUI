//
//  HTMLSyntaxHighlighter.swift
//  HTMLEditor-SwiftUI
//
//  Created by Sergei Armodin on 07.07.2025.
//

#if os(macOS)
import AppKit
import SwiftSoup

// MARK: - HTMLSyntaxHighlighter (syntax logic extracted)
public struct HTMLSyntaxHighlighter {
    public static func highlight(html: String, theme: HTMLEditorColorScheme) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: html)
        let fullRange = NSRange(location: 0, length: attributed.length)
        attributed.addAttribute(.font, value: theme.font, range: fullRange)
        attributed.addAttribute(.foregroundColor, value: theme.foreground, range: fullRange)

        let tagColor = theme.tag
        let attributeNameColor = theme.attributeName
        let attributeValueColor = theme.attributeValue

        // Use optimized single-pass highlighting with precompiled regex patterns
        let changes = HighlightChanges()
        
        // Single pass: find all HTML tags and brackets
        let htmlTagRegex = try! Regex(#"</?[a-zA-Z][a-zA-Z0-9]*[^>]*>"#)
        for match in html.matches(of: htmlTagRegex) {
            let matchRange = NSRange(match.range, in: html)
            let matchText = String(html[match.range])
            
            // Highlight opening/closing brackets
            if matchText.hasPrefix("<") {
                changes.addChange(NSRange(location: matchRange.location, length: 1), .foregroundColor, tagColor)
            }
            if matchText.hasSuffix(">") {
                changes.addChange(NSRange(location: matchRange.location + matchRange.length - 1, length: 1), .foregroundColor, tagColor)
            }
            
            // Extract and highlight tag name
            let tagStartIndex = matchText.hasPrefix("</") ? 2 : 1
            if let spaceIndex = matchText.firstIndex(of: " ") ?? matchText.firstIndex(of: ">") {
                let tagEndIndex = matchText.distance(from: matchText.startIndex, to: spaceIndex)
                if tagEndIndex > tagStartIndex {
                    let tagRange = NSRange(location: matchRange.location + tagStartIndex, length: tagEndIndex - tagStartIndex)
                    changes.addChange(tagRange, .foregroundColor, tagColor)
                }
            }
        }
        
        // Single pass: find all attributes
        let attributeRegex = try! Regex(#"([a-zA-Z-]+)\s*=\s*"([^"]*)"|([a-zA-Z-]+)\s*=\s*'([^']*)'"#)
        for match in html.matches(of: attributeRegex) {
            let matchRange = NSRange(match.range, in: html)
            let matchText = String(html[match.range])
            
            // Parse attribute name and value
            if let equalIndex = matchText.firstIndex(of: "=") {
                let nameLength = matchText.distance(from: matchText.startIndex, to: equalIndex)
                let nameRange = NSRange(location: matchRange.location, length: nameLength)
                changes.addChange(nameRange, .foregroundColor, attributeNameColor)
                
                // Find quoted value
                let valueStart = matchText.index(after: equalIndex)
                if let quoteChar = matchText[valueStart...].first, quoteChar == "\"" || quoteChar == "'" {
                    if let endQuoteIndex = matchText[matchText.index(after: valueStart)...].firstIndex(of: quoteChar) {
                        let valueStartOffset = matchText.distance(from: matchText.startIndex, to: valueStart)
                        let valueEndOffset = matchText.distance(from: matchText.startIndex, to: endQuoteIndex) + 1
                        let valueRange = NSRange(location: matchRange.location + valueStartOffset, length: valueEndOffset - valueStartOffset)
                        changes.addChange(valueRange, .foregroundColor, attributeValueColor)
                    }
                }
            }
        }

        // Apply all changes efficiently
        changes.applyToAttributedString(attributed)
        
        return attributed
    }
}

extension NSRange {
    func toOptional() -> NSRange? {
        return self.location != NSNotFound ? self : nil
    }
}

// Optimized highlight changes collection
final class HighlightChanges: @unchecked Sendable {
    private var changes: [(range: NSRange, attributeKey: NSAttributedString.Key, color: NSColor)] = []
    private let lock = NSLock()
    
    func addChange(_ range: NSRange, _ attributeKey: NSAttributedString.Key, _ color: NSColor) {
        lock.lock()
        changes.append((range: range, attributeKey: attributeKey, color: color))
        lock.unlock()
    }
    
    func applyToAttributedString(_ attributedString: NSMutableAttributedString) {
        lock.lock()
        let localChanges = changes
        lock.unlock()
        
        // Sort changes by location to apply them efficiently
        let sortedChanges = localChanges.sorted { $0.range.location < $1.range.location }
        
        for change in sortedChanges {
            // Bounds check to prevent crashes
            if change.range.location >= 0 && 
               change.range.location + change.range.length <= attributedString.length {
                attributedString.addAttribute(change.attributeKey, value: change.color, range: change.range)
            }
        }
    }
}

#endif