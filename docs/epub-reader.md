# EPUB / KEPUB reader boundary

Papria does not copy BookOrbit's web UI and does not attempt to decrypt DRM.
The reader source routes Android EPUB/KEPUB through Readium Kotlin and iOS
EPUB/KEPUB through the official Readium Swift Toolkit. They preserve the same
BookOrbit progress fields. Android Debug/Release packaging and the iOS App-only
build pass in this checkout; device and XCTest runtime behavior remains external
platform evidence.

## Supported navigation

- EPUB 3 `manifest` navigation documents (`properties="nav"`)
- EPUB 2 NCX documents (`spine@toc` or an
  `application/x-dtbncx+xml` manifest item)
- Relative links and XHTML `id`/`name` fragments
- Nested NCX depth, which is shown as indentation in the native table of
  contents

KEPUB files use the EPUB ZIP/container/spine format and therefore enter the
same path. Kobo-specific styling and annotations that require a browser DOM
are intentionally reduced to bounded text; they are not silently interpreted
as BookOrbit progress fields.

## Reflow-safe locator

The Readium integration is designed to persist a point EPUB CFI in BookOrbit's
existing `cfi` field. Its CFI-to-progress bridge must preserve a full
`epubcfi(...)` value when Readium supplies a partial content CFI and falls back
to percentage only when a foreign locator cannot be mapped. This behavior is
present in source but still needs cross-engine and device verification.

The current reader writes and restores Readium-compatible `epubcfi(...)`
locations. A non-Readium string such as `chapter:3/page:2/offset:1840` is
rejected and is never interpreted, migrated, sent to BookOrbit, or treated as
a compatibility alias. When a valid CFI is unavailable, the documented page
number field is used only as the generic local fallback.

## Deliberate boundary

Readium is the intended production navigator on both platforms, but complex
CSS pagination, embedded scripts, MathML, SVG layout, iframe content,
font-face loading, Kobo-specific `kobo:` rendering, range CFI, and spatial CFI
all require platform/device coverage before they can be advertised as
supported. The iOS bridge retains the existing BookOrbit progress payload;
the Android bridge has the same goal once its dependency resolution and Kotlin
compilation succeed.
