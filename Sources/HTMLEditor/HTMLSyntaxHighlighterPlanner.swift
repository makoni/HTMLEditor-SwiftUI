#if os(macOS)
import AppKit
import Foundation

enum HTMLHighlightScannerState: Hashable, Sendable {
    case text
    case afterTagOpen
    case tagName
    case insideTag
    case attributeName
    case afterAttributeName
    case beforeAttributeValue
    case quotedAttributeValue(unichar)
    case unquotedAttributeValue
}

struct HTMLHighlightChunkResult: Sendable {
    let endState: HTMLHighlightScannerState
    let spans: [HTMLSyntaxHighlighter.HighlightSpan]
}

actor HTMLHighlightPlanner {
    private enum ChunkDependencyKind: Sendable {
        case contextDependent
        case contextIndependent
    }

    private struct CachedPlanEntry: Sendable {
        let key: PlannerCacheKey
        let plan: HTMLSyntaxHighlighter.HighlightPlan
    }

    private struct CachedChunkEntry: Sendable {
        let key: PlannerChunkCacheKey
        let result: HTMLHighlightChunkResult
        let dependencyKind: ChunkDependencyKind
    }

    private struct PlannerCacheKey: Hashable, Sendable {
        let documentID: UUID
        let textLength: Int
        let range: NSRange
        let docVersion: Int
    }

    private struct PlannerChunkCacheKey: Hashable, Sendable {
        let documentID: UUID
        let textLength: Int
        let range: NSRange
        let fingerprint: Int
        let inputState: HTMLHighlightScannerState
    }

    private var cachedPlans: [CachedPlanEntry] = []
    private var cachedChunks: [CachedChunkEntry] = []

    func fullPlan(for html: String, documentID: UUID) -> HTMLSyntaxHighlighter.HighlightPlan {
        let fullRange = NSRange(location: 0, length: (html as NSString).length)
        return cachedPlan(for: html, range: fullRange, documentID: documentID) {
            buildPlan(for: html, coveredRange: fullRange, documentID: documentID)
        }
    }

    func rangePlan(for text: String, requestedRange: NSRange, documentID: UUID) -> HTMLSyntaxHighlighter.HighlightPlan {
        let normalizedRange = HTMLHighlightPlanBuilder.normalizedRange(for: text, requestedRange: requestedRange)
        guard normalizedRange.location != NSNotFound, normalizedRange.length > 0 else {
            return HTMLSyntaxHighlighter.HighlightPlan(coveredRange: NSRange(location: 0, length: 0), spans: [])
        }

        return cachedPlan(for: text, range: normalizedRange, documentID: documentID) {
            buildPlan(for: text, coveredRange: normalizedRange, documentID: documentID)
        }
    }

    func invalidate(
        documentID: UUID,
        editRange: NSRange,
        replacementUTF16Length: Int,
        newTextLength: Int
    ) {
        let planInvalidationStart = max(0, editRange.location - 256)
        let chunkInvalidationStart = HTMLHighlightPlanBuilder.chunkStart(for: planInvalidationStart)
        let planInvalidationEnd = max(planInvalidationStart, editRange.location + max(editRange.length, replacementUTF16Length) + 256)
        let chunkInvalidationEnd = HTMLHighlightPlanBuilder.chunkEnd(forExclusiveLocation: planInvalidationEnd)
        let lengthDelta = replacementUTF16Length - editRange.length

        if abs(lengthDelta) > HTMLHighlightPlanBuilder.plannerChunkSize * 8 {
            clear(documentID: documentID)
            return
        }

        if lengthDelta == 0 {
            let planInvalidationRange = NSRange(location: planInvalidationStart, length: max(0, planInvalidationEnd - planInvalidationStart))
            let chunkInvalidationRange = NSRange(location: chunkInvalidationStart, length: max(0, chunkInvalidationEnd - chunkInvalidationStart))

            cachedPlans.removeAll {
                $0.key.documentID == documentID &&
                NSIntersectionRange($0.key.range, planInvalidationRange).length > 0
            }

            cachedChunks.removeAll {
                $0.key.documentID == documentID &&
                NSIntersectionRange($0.key.range, chunkInvalidationRange).length > 0
            }
        } else {
            remapLengthChangingCaches(
                documentID: documentID,
                planInvalidationStart: planInvalidationStart,
                chunkInvalidationStart: chunkInvalidationStart,
                chunkInvalidationEnd: chunkInvalidationEnd,
                newTextLength: newTextLength,
                lengthDelta: lengthDelta
            )
        }

        if newTextLength <= planInvalidationStart {
            clear(documentID: documentID)
        }
    }

    func clear(documentID: UUID) {
        cachedPlans.removeAll { $0.key.documentID == documentID }
        cachedChunks.removeAll { $0.key.documentID == documentID }
    }

    func debugCounts(documentID: UUID) -> (plans: Int, chunks: Int) {
        (
            plans: cachedPlans.filter { $0.key.documentID == documentID }.count,
            chunks: cachedChunks.filter { $0.key.documentID == documentID }.count
        )
    }

    private func remapLengthChangingCaches(
        documentID: UUID,
        planInvalidationStart: Int,
        chunkInvalidationStart: Int,
        chunkInvalidationEnd: Int,
        newTextLength: Int,
        lengthDelta: Int
    ) {
        cachedPlans = cachedPlans.compactMap { entry in
            guard entry.key.documentID == documentID else { return entry }
            guard NSMaxRange(entry.key.range) <= planInvalidationStart else { return nil }

            return CachedPlanEntry(
                key: PlannerCacheKey(
                    documentID: documentID,
                    textLength: newTextLength,
                    range: entry.key.range,
                    docVersion: entry.key.docVersion
                ),
                plan: entry.plan
            )
        }

        cachedChunks = cachedChunks.compactMap { entry in
            guard entry.key.documentID == documentID else { return entry }

            if NSMaxRange(entry.key.range) <= chunkInvalidationStart {
                return CachedChunkEntry(
                    key: PlannerChunkCacheKey(
                        documentID: documentID,
                        textLength: newTextLength,
                        range: entry.key.range,
                        fingerprint: entry.key.fingerprint,
                        inputState: entry.key.inputState
                    ),
                    result: entry.result,
                    dependencyKind: entry.dependencyKind
                )
            }

            guard entry.key.range.location >= chunkInvalidationEnd,
                  let shiftedRange = shift(entry.key.range, by: lengthDelta),
                  let shiftedResult = shift(entry.result, by: lengthDelta) else {
                return nil
            }

            return CachedChunkEntry(
                key: PlannerChunkCacheKey(
                    documentID: documentID,
                    textLength: newTextLength,
                    range: shiftedRange,
                    fingerprint: entry.key.fingerprint,
                    inputState: entry.key.inputState
                ),
                result: shiftedResult,
                dependencyKind: entry.dependencyKind
            )
        }
    }

    private func shift(_ range: NSRange, by delta: Int) -> NSRange? {
        guard range.location != NSNotFound else { return nil }
        let newLocation = range.location + delta
        guard newLocation >= 0 else { return nil }
        return NSRange(location: newLocation, length: range.length)
    }

    private func shift(_ result: HTMLHighlightChunkResult, by delta: Int) -> HTMLHighlightChunkResult? {
        let shiftedSpans = result.spans.compactMap { span -> HTMLSyntaxHighlighter.HighlightSpan? in
            guard let shiftedRange = shift(span.range, by: delta) else { return nil }
            return .init(range: shiftedRange, role: span.role)
        }

        guard shiftedSpans.count == result.spans.count else { return nil }
        return HTMLHighlightChunkResult(endState: result.endState, spans: shiftedSpans)
    }

    private func initialScannerState(
        for text: String,
        alignedStart: Int,
        documentID: UUID
    ) -> HTMLHighlightScannerState {
        guard alignedStart > 0 else { return .text }

        let previousRange = NSRange(
            location: max(0, alignedStart - HTMLHighlightPlanBuilder.plannerChunkSize),
            length: min(HTMLHighlightPlanBuilder.plannerChunkSize, alignedStart)
        )

        guard previousRange.length > 0 else { return .text }

        let textLength = text.utf16.count
        let fingerprint = textFingerprint(text, range: previousRange)
        guard let cached = cachedChunks.last(where: {
            $0.key.documentID == documentID &&
            $0.key.textLength == textLength &&
            $0.key.range == previousRange &&
            $0.key.fingerprint == fingerprint
        }) else {
            return .text
        }

        return cached.result.endState
    }

    private func documentVersion(for text: NSString) -> Int {
        let len = text.length
        guard len > 0 else { return 0 }
        var h = Hasher()
        h.combine(len)
        h.combine(text.character(at: 0))
        if len > 1 { h.combine(text.character(at: len - 1)) }
        if len > 2 { h.combine(text.character(at: len / 2)) }
        return h.finalize()
    }

    private func cachedPlan(
        for text: String,
        range: NSRange,
        documentID: UUID,
        build: () -> HTMLSyntaxHighlighter.HighlightPlan
    ) -> HTMLSyntaxHighlighter.HighlightPlan {
        let nsText = text as NSString
        let docVer = documentVersion(for: nsText)
        let key = PlannerCacheKey(
            documentID: documentID,
            textLength: nsText.length,
            range: range,
            docVersion: docVer
        )

        if let exactIndex = cachedPlans.firstIndex(where: { $0.key == key }) {
            let entry = cachedPlans.remove(at: exactIndex)
            cachedPlans.append(entry)
            return entry.plan
        }

        if let coveringIndex = cachedPlans.firstIndex(where: {
            $0.key.documentID == key.documentID &&
            $0.key.textLength == key.textLength &&
            $0.key.docVersion == docVer &&
            NSLocationInRange(range.location, $0.key.range) &&
            NSMaxRange(range) <= NSMaxRange($0.key.range)
        }) {
            let entry = cachedPlans.remove(at: coveringIndex)
            cachedPlans.append(entry)
            return entry.plan
        }

        let plan = build()
        cachedPlans.append(CachedPlanEntry(key: key, plan: plan))
        if cachedPlans.count > 24 {
            cachedPlans.removeFirst(cachedPlans.count - 24)
        }
        return plan
    }

    private func buildPlan(for text: String, coveredRange: NSRange, documentID: UUID) -> HTMLSyntaxHighlighter.HighlightPlan {
        let nsText = text as NSString
        guard coveredRange.location != NSNotFound,
              coveredRange.length > 0,
              coveredRange.location >= 0,
              NSMaxRange(coveredRange) <= nsText.length else {
            return HTMLSyntaxHighlighter.HighlightPlan(coveredRange: NSRange(location: 0, length: 0), spans: [])
        }

        let alignedRange = HTMLHighlightPlanBuilder.alignedChunkWindow(for: coveredRange, textLength: nsText.length)
        var spans: [HTMLSyntaxHighlighter.HighlightSpan] = []
        spans.reserveCapacity(max(32, alignedRange.length / 16))

        var scannerState = initialScannerState(
            for: text,
            alignedStart: alignedRange.location,
            documentID: documentID
        )
        for chunkRange in HTMLHighlightPlanBuilder.chunkRanges(for: alignedRange) {
            let chunk = cachedChunk(for: text, range: chunkRange, inputState: scannerState, documentID: documentID) {
                HTMLHighlightPlanBuilder.buildChunk(in: nsText, range: chunkRange, initialState: scannerState)
            }
            spans.append(contentsOf: chunk.spans)
            scannerState = chunk.endState
        }

        return HTMLSyntaxHighlighter.HighlightPlan(
            coveredRange: coveredRange,
            spans: HTMLHighlightPlanBuilder.trimmedSpans(HTMLHighlightPlanBuilder.coalesce(spans), to: coveredRange)
        )
    }

    private func cachedChunk(
        for text: String,
        range: NSRange,
        inputState: HTMLHighlightScannerState,
        documentID: UUID,
        build: () -> HTMLHighlightChunkResult
    ) -> HTMLHighlightChunkResult {
        let key = PlannerChunkCacheKey(
            documentID: documentID,
            textLength: text.utf16.count,
            range: range,
            fingerprint: textFingerprint(text, range: range),
            inputState: inputState
        )

        if let hitIndex = cachedChunks.firstIndex(where: { $0.key == key }) {
            let entry = cachedChunks.remove(at: hitIndex)
            cachedChunks.append(entry)
            return entry.result
        }

        if let reusableIndex = cachedChunks.firstIndex(where: {
            $0.key.documentID == documentID &&
            $0.key.textLength == key.textLength &&
            $0.key.range == key.range &&
            $0.key.fingerprint == key.fingerprint &&
            $0.dependencyKind == .contextIndependent
        }) {
            let entry = cachedChunks.remove(at: reusableIndex)
            cachedChunks.append(entry)
            return entry.result
        }

        let result = build()
        cachedChunks.append(
            CachedChunkEntry(
                key: key,
                result: result,
                dependencyKind: dependencyKind(for: result, initialState: inputState)
            )
        )
        if cachedChunks.count > 192 {
            cachedChunks.removeFirst(cachedChunks.count - 192)
        }
        return result
    }

    private func dependencyKind(
        for result: HTMLHighlightChunkResult,
        initialState: HTMLHighlightScannerState
    ) -> ChunkDependencyKind {
        let startsInText = initialState == .text
        let endsInText = result.endState == .text
        let hasOnlySelfContainedSpans = !result.spans.contains { span in
            span.role == .attributeValue && span.range.length >= HTMLHighlightPlanBuilder.plannerChunkSize
        }

        return startsInText && endsInText && hasOnlySelfContainedSpans ? .contextIndependent : .contextDependent
    }

    private func textFingerprint(_ text: String, range: NSRange) -> Int {
        let nsText = text as NSString
        guard range.location != NSNotFound,
              range.length > 0,
              NSMaxRange(range) <= nsText.length else {
            return 0
        }

        var hasher = Hasher()
        hasher.combine(range.location)
        hasher.combine(range.length)
        let sampleOffsets = sampledOffsets(forLength: range.length)
        for offset in sampleOffsets {
            hasher.combine(nsText.character(at: range.location + offset))
        }
        return hasher.finalize()
    }

    private func sampledOffsets(forLength length: Int) -> [Int] {
        guard length > 0 else { return [] }
        let candidates = [0, max(0, length - 1), length / 2, length / 4, (length * 3) / 4]
        var offsets: [Int] = []
        offsets.reserveCapacity(5)
        for candidate in candidates where !offsets.contains(candidate) {
            offsets.append(candidate)
        }
        return offsets
    }
}
#endif
