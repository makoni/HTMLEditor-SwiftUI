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
    // Regex patterns as static constants
    static let tagPatternTemplate = #"<\/?%@\b"#
    static let attrPatternTemplate = #"%@=\"%@\""#

    public static func highlight(html: String, theme: HTMLEditorColorScheme) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: html)
        let fullRange = NSRange(location: 0, length: attributed.length)
        attributed.addAttribute(.font, value: theme.font, range: fullRange)
        attributed.addAttribute(.foregroundColor, value: theme.foreground, range: fullRange)

        let tagColor = theme.tag
        let attributeNameColor = theme.attributeName
        let attributeValueColor = theme.attributeValue

        let changes = ThreadSafeArray<(range: NSRange, attributeKey: NSAttributedString.Key, color: NSColor)>()

        if let doc = try? SwiftSoup.parseBodyFragment(html), let elements = try? doc.getAllElements() {
            let elementArray = elements.array()
            DispatchQueue.concurrentPerform(iterations: elementArray.count) { index in
                let element = elementArray[index]

                // Process tag
                let tag = element.tagName()
                let tagPattern = String(format: tagPatternTemplate, tag)
                let tagRegex = try? Regex(tagPattern)

                if let regex = tagRegex {
                    for match in html.matches(of: regex) {
                        let matchRange = NSRange(match.range, in: html)
                        let bracketLength = matchRange.length - tag.count
                        if bracketLength > 0 {
                            let bracketRange = NSRange(location: matchRange.location, length: bracketLength)
                            changes.append((bracketRange, .foregroundColor, tagColor))
                        }
                        let tagNameRange = NSRange(location: matchRange.location + bracketLength, length: tag.count)
                        changes.append((tagNameRange, .foregroundColor, tagColor))
                        let afterTagLocation = matchRange.location + matchRange.length
                        if afterTagLocation < fullRange.length {
                            let afterTagRange = NSRange(location: afterTagLocation, length: fullRange.length - afterTagLocation)
                            let closeBracketRange = (html as NSString).range(of: ">", options: [], range: afterTagRange)
                            if closeBracketRange.location != NSNotFound && closeBracketRange.length == 1 {
                                changes.append((closeBracketRange, .foregroundColor, tagColor))
                            }
                        }
                    }
                }

                // Process attributes
                if let attrs = element.getAttributes() {
                    for attr in attrs {
                        let attrName = attr.getKey()
                        let attrValue = attr.getValue()
                        let attrPattern = String(format: attrPatternTemplate, NSRegularExpression.escapedPattern(for: attrName), NSRegularExpression.escapedPattern(for: attrValue))
                        let attrRegex = try? Regex(attrPattern)

                        if let regex = attrRegex {
                            for match in html.matches(of: regex) {
                                let matchRange = NSRange(match.range, in: html)
                                let attrNameRange = NSRange(location: matchRange.location, length: attrName.count)
                                changes.append((attrNameRange, .foregroundColor, attributeNameColor))
                                let valueStart = matchRange.location + attrName.count + 2
                                let valueLength = attrValue.count
                                let attrValueRange = NSRange(location: valueStart, length: valueLength)
                                changes.append((attrValueRange, .foregroundColor, attributeValueColor))
                                changes.append((NSRange(location: valueStart - 1, length: 1), .foregroundColor, attributeValueColor))
                                changes.append((NSRange(location: valueStart + valueLength, length: 1), .foregroundColor, attributeValueColor))
                            }
                        }
                    }
                }
            }

            // Apply all changes to attributed
            for change in changes.getAll() {
                attributed.addAttribute(change.attributeKey, value: change.color, range: change.range)
            }
        } else {
            print("Error during HTML parsing or processing")
        }

        return attributed
    }
}

extension NSRange {
    func toOptional() -> NSRange? {
        return self.location != NSNotFound ? self : nil
    }
}

// Thread-safe array implementation
final class ThreadSafeArray<Element: Sendable>: @unchecked Sendable {
    private var array: [Element] = []
    private let queue = DispatchQueue(label: "ThreadSafeArrayQueue", attributes: .concurrent)

    func append(_ newElement: Element) {
        queue.async(flags: .barrier) {
            self.array.append(newElement)
        }
    }

    func getAll() -> [Element] {
        queue.sync {
            return self.array
        }
    }
}

#endif
