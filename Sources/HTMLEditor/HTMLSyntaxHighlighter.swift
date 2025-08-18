//
//  HTMLSyntaxHighlighter.swift
//  HTMLEditor-SwiftUI
//
//  Created by Sergei Armodin on 07.07.2025.
//

#if os(macOS)
import AppKit

// MARK: - HTMLSyntaxHighlighter (syntax logic extracted)
public struct HTMLSyntaxHighlighter {
    private static let maxHighlightLength = 50_000 // Limit highlighting for very large content
    
    public static func highlight(html: String, theme: HTMLEditorColorScheme) -> NSAttributedString {
        // For very large content, apply basic styling only
        if html.count > maxHighlightLength {
            return createBasicAttributedString(html: html, theme: theme)
        }
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
    
    private static func createBasicAttributedString(html: String, theme: HTMLEditorColorScheme) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: html)
        let fullRange = NSRange(location: 0, length: attributed.length)
        attributed.addAttribute(.font, value: theme.font, range: fullRange)
        attributed.addAttribute(.foregroundColor, value: theme.foreground, range: fullRange)
        return attributed
    }
    
    // Incremental highlighting for specific range
    public static func highlightRange(
        in textStorage: NSTextStorage,
        range: NSRange,
        theme: HTMLEditorColorScheme,
        expandedRange: inout NSRange
    ) {
        let text = textStorage.string
        let textLength = text.count
        
        // Early return for empty text or invalid range
        if textLength == 0 || range.location == NSNotFound || range.location < 0 || range.location >= textLength {
            expandedRange = NSRange(location: 0, length: 0)
            return
        }
        
        // Expand range conservatively to include complete HTML tags
        let expandRadius = min(100, textLength / 10) // Limit expansion based on document size
        let expandedStart = max(0, range.location - expandRadius)
        let expandedEnd = min(textLength, range.location + range.length + expandRadius)
        expandedRange = NSRange(location: expandedStart, length: expandedEnd - expandedStart)
        
        // Limit maximum range size to prevent performance issues
        if expandedRange.length > 2000 {
            let center = range.location + range.length / 2
            expandedRange = NSRange(
                location: max(0, center - 1000),
                length: min(2000, textLength - max(0, center - 1000))
            )
        }
        
        // Optimize line boundary expansion only for small ranges
        if expandedRange.length < 1000 && expandedRange.length > 0 {
            let expandedString = (text as NSString)
            
            // Bounds check before calling lineRange
            let startLocation = max(0, min(expandedRange.location, textLength - 1))
            let endLocation = max(0, min(expandedRange.location + expandedRange.length - 1, textLength - 1))
            
            if startLocation < textLength && endLocation < textLength {
                let lineStart = expandedString.lineRange(for: NSRange(location: startLocation, length: 0)).location
                let lineEnd = expandedString.lineRange(for: NSRange(location: endLocation, length: 0))
                let lineEndLocation = lineEnd.location + lineEnd.length
                
                // Final bounds check
                if lineStart <= lineEndLocation && lineEndLocation <= textLength {
                    expandedRange = NSRange(location: lineStart, length: lineEndLocation - lineStart)
                }
            }
        }
        
        // Clear existing attributes in the expanded range
        textStorage.removeAttribute(.foregroundColor, range: expandedRange)
        textStorage.addAttribute(.font, value: theme.font, range: expandedRange)
        textStorage.addAttribute(.foregroundColor, value: theme.foreground, range: expandedRange)
        
        // Extract the text portion to highlight
        let expandedString = (text as NSString)
        let rangeText = expandedString.substring(with: expandedRange)
        
        // Apply syntax highlighting to the expanded range
        let changes = HighlightChanges()
        
        // Find HTML tags in the range
        let htmlTagRegex = try! Regex(#"</?[a-zA-Z][a-zA-Z0-9]*[^>]*>"#)
        for match in rangeText.matches(of: htmlTagRegex) {
            let matchRange = NSRange(match.range, in: rangeText)
            let matchText = String(rangeText[match.range])
            
            // Adjust match range to absolute position
            let absoluteRange = NSRange(
                location: expandedRange.location + matchRange.location,
                length: matchRange.length
            )
            
            // Highlight opening/closing brackets and slash
            if matchText.hasPrefix("<") {
                changes.addChange(NSRange(location: absoluteRange.location, length: 1), .foregroundColor, theme.tag)
            }
            if matchText.hasPrefix("</") {
                changes.addChange(NSRange(location: absoluteRange.location + 1, length: 1), .foregroundColor, theme.tag)
            }
            if matchText.hasSuffix(">") {
                changes.addChange(NSRange(location: absoluteRange.location + absoluteRange.length - 1, length: 1), .foregroundColor, theme.tag)
            }
            
            // Extract and highlight tag name
            let tagStartIndex = matchText.hasPrefix("</") ? 2 : 1
            if let spaceIndex = matchText.firstIndex(of: " ") ?? matchText.firstIndex(of: ">") {
                let tagEndIndex = matchText.distance(from: matchText.startIndex, to: spaceIndex)
                if tagEndIndex > tagStartIndex {
                    let tagRange = NSRange(
                        location: absoluteRange.location + tagStartIndex,
                        length: tagEndIndex - tagStartIndex
                    )
                    changes.addChange(tagRange, .foregroundColor, theme.tag)
                }
            }
        }
        
        // Find attributes in the range
        let attributeRegex = try! Regex(#"([a-zA-Z-]+)\s*=\s*"([^"]*)"|([a-zA-Z-]+)\s*=\s*'([^']*)'"#)
        for match in rangeText.matches(of: attributeRegex) {
            let matchRange = NSRange(match.range, in: rangeText)
            let matchText = String(rangeText[match.range])
            
            // Adjust match range to absolute position
            let absoluteRange = NSRange(
                location: expandedRange.location + matchRange.location,
                length: matchRange.length
            )
            
            // Parse attribute name and value using NSString for better performance
            let matchNSString = matchText as NSString
            let equalRange = matchNSString.range(of: "=")
            if equalRange.location != NSNotFound {
                let nameRange = NSRange(location: absoluteRange.location, length: equalRange.location)
                changes.addChange(nameRange, .foregroundColor, theme.attributeName)
                
                // Find quoted value using NSString ranges
                let searchStart = equalRange.location + equalRange.length
                let remainingRange = NSRange(location: searchStart, length: matchNSString.length - searchStart)
                
                let quoteRange = matchNSString.rangeOfCharacter(from: CharacterSet(charactersIn: "\"'"), options: [], range: remainingRange)
                if quoteRange.location != NSNotFound {
                    let quoteChar = matchNSString.character(at: quoteRange.location)
                    let valueStart = quoteRange.location
                    let searchRange = NSRange(location: valueStart + 1, length: matchNSString.length - valueStart - 1)
                    let endQuoteRange = matchNSString.rangeOfCharacter(from: CharacterSet(charactersIn: String(UnicodeScalar(quoteChar)!)), options: [], range: searchRange)
                    
                    if endQuoteRange.location != NSNotFound {
                        let valueRange = NSRange(
                            location: absoluteRange.location + valueStart,
                            length: endQuoteRange.location - valueStart + 1
                        )
                        changes.addChange(valueRange, .foregroundColor, theme.attributeValue)
                    }
                }
            }
        }
        
        // Apply changes to text storage
        changes.applyToTextStorage(textStorage)
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
    
    func applyToTextStorage(_ textStorage: NSTextStorage) {
        lock.lock()
        let localChanges = changes
        lock.unlock()
        
        // Sort changes by location to apply them efficiently
        let sortedChanges = localChanges.sorted { $0.range.location < $1.range.location }
        
        for change in sortedChanges {
            // Bounds check to prevent crashes
            if change.range.location >= 0 && 
               change.range.location + change.range.length <= textStorage.length {
                textStorage.addAttribute(change.attributeKey, value: change.color, range: change.range)
            }
        }
    }
}

#endif
