# HTMLEditor-SwiftUI 1.1.1

Patch release based on changes since `1.1.0`.

## Highlights

- Fixed stale syntax colors that could remain on plain text after incremental edits and prewarm updates.
- Fixed the brief "no highlight -> highlight" flicker that occurred on each keystroke in smaller HTML documents.
- Unified the initial small-document render with the editor's overlay-based highlighting pipeline so startup and incremental updates use the same model.

## What's changed

### Fixed

- Cleared overlapping temporary highlight regions more aggressively so old prewarm colors cannot leak into corrected content.
- Re-queued dirty highlight coverage after edit-driven refreshes so offscreen semantic passes can recover cleanly.
- Applied an immediate local re-highlight for small-document edits to remove visible flicker while typing.

### Tests

- Added regression coverage for stale temporary overlays, dirty coverage invalidation, and immediate small-document edit repainting.
- Expanded syntax-highlighter tests around permanent base text colors versus temporary semantic overlays.

### Docs

- Updated the README hero image source.

## Commits in this release

- `d0a109b` Fix small-document highlight flicker
- `73eda06` Fix stale syntax highlights
- `4e2c0f9` Change image source in README.md

## Compare

- https://github.com/makoni/HTMLEditor-SwiftUI/compare/1.1.0...1.1.1
