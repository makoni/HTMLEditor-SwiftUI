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

		do {
			let doc = try SwiftSoup.parseBodyFragment(html)
			let elements = try doc.getAllElements()
			for element in elements {
				let tag = element.tagName()
				let tagPattern = String(format: tagPatternTemplate, tag)
				if let regex = try? Regex(tagPattern) {
					for match in html.matches(of: regex) {
						let matchRange = NSRange(match.range, in: html)
						let bracketLength = matchRange.length - tag.count
						if bracketLength > 0 {
							let bracketRange = NSRange(location: matchRange.location, length: bracketLength)
							attributed.addAttribute(.foregroundColor, value: theme.tag, range: bracketRange)
						}
						let tagNameRange = NSRange(location: matchRange.location + bracketLength, length: tag.count)
						attributed.addAttribute(.foregroundColor, value: theme.tag, range: tagNameRange)
						let afterTagLocation = matchRange.location + matchRange.length
						if afterTagLocation < fullRange.length {
							let afterTagRange = NSRange(location: afterTagLocation, length: fullRange.length - afterTagLocation)
							if let closeBracketRange = (html as NSString).range(of: ">", options: [], range: afterTagRange).toOptional(), closeBracketRange.length == 1 {
								attributed.addAttribute(.foregroundColor, value: theme.tag, range: closeBracketRange)
							}
						}
					}
				}
				if let attrs = element.getAttributes() {
					for attr in attrs {
						let attrName = attr.getKey()
						let attrValue = attr.getValue()
						let attrPattern = String(format: attrPatternTemplate, NSRegularExpression.escapedPattern(for: attrName), NSRegularExpression.escapedPattern(for: attrValue))
						if let regex = try? Regex(attrPattern) {
							for match in html.matches(of: regex) {
								let matchRange = NSRange(match.range, in: html)
								let attrNameRange = NSRange(location: matchRange.location, length: attrName.count)
								attributed.addAttribute(.foregroundColor, value: theme.attributeName, range: attrNameRange)
								let valueStart = matchRange.location + attrName.count + 2
								let valueLength = attrValue.count
								let attrValueRange = NSRange(location: valueStart, length: valueLength)
								attributed.addAttribute(.foregroundColor, value: theme.attributeValue, range: attrValueRange)
								attributed.addAttribute(.foregroundColor, value: theme.attributeValue, range: NSRange(location: valueStart - 1, length: 1))
								attributed.addAttribute(.foregroundColor, value: theme.attributeValue, range: NSRange(location: valueStart + valueLength, length: 1))
							}
						}
					}
				}
			}
		} catch {
			// Optionally log error
		}
		return attributed
	}
}

private extension NSRange {
	func toOptional() -> NSRange? {
		return self.location != NSNotFound ? self : nil
	}
}
#endif
