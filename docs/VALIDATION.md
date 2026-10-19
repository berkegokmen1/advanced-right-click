# Validation — 0.1.4

Validated on this Apple Silicon Mac, macOS 26.6.2 / Swift 6.2.3, targeting macOS 13.

## Automated checks

`ARC_TEST_VISION=1 ./scripts/test.sh` passed outside the restricted execution sandbox: **34 integration checks, 0 failures**, covering **all 38 catalog actions**. The shared-menu suite passed **211 menu and Finder-handoff assertions**.

Coverage includes:

- HEIC/PNG/JPEG conversion, resizing, rotation, metadata removal, upload presets, target file sizes, contact sheets, and exact-byte restoration.
- Mixed-format conversion leaves matching inputs untouched; every item must be compatible with a menu action.
- Mixed image/PDF merge, split, extract, rotate, smaller PDF compression, OCR, detected links and selectable searchable-PDF text.
- MP4, mute, video/audio trimming, GIF and M4A exports; resulting media durations and readability.
- Rename preview agreement, organization by type/month, templates and clipboard text/image creation.
- ZIP round trips, separate ZIPs, repeated derived-output names, extraction when the original source name exists, and unsafe archive rejection.
- Text/path/name/Markdown copying, binary-text rejection, reports, duplicate contents, comparison and Terminal folder requests.
- Whole-batch collision and undo protection, cancellation rollback, interrupted-install recovery, exclusive history locking and corrupt-journal reporting.
- In-place file replacement preserves Finder bookmarks and file permissions.
- Finder callback simulation drops `representedObject` while retaining the integer menu tag; requests still resolve to their original selection snapshot.
- Singular, multiple, mixed, folder, package, symbolic-link and background-selection menu eligibility and labels; all 38 action symbols resolve.

The Terminal integration test validates the requested folder. It does not prove that an interactive Terminal window launches correctly.

## Live Finder checks

Verified against the app installed in Applications using disposable generated images:

- Single PNG selection hides PNG conversion, contact sheet, separate ZIPs, comparison and binary-text copying.
- Two-image selection offers batch labels, combined PDF, contact sheet, individual ZIPs and comparison.
- Folder-background right-click targets the containing folder even with image files still selected; image commands disappear and folder commands appear.
- PNG → JPEG runs from the native submenu and removes the original only after backup. Undo restores the original bytes.
- Batch resize processes both selected images. Native right-click Undo restores their original dimensions.
- New-file template action creates the requested Markdown file; native Undo removes it.
- The resize and template panels contain only their fields and Cancel/Apply buttons. Resize was visually checked at 380px wide; rename previews are capped at four rows.
- Earlier inspection confirmed the configuration-only General, Menu and History pages and the absence of a dashboard. Dock and menu-bar icons are off by default.

Live testing reproduced and fixed Finder’s removal of menu-item `representedObject`, which previously made clicks silently fail. In-place replacement was also changed to preserve Finder file references after edits. PDF compression and repeated derived-output conflicts were fixed during the expanded integration checks.

## Build / installation

The host and embedded Finder Sync extension compile with Command Line Tools. Ad-hoc signature verification and installer creation passed. **0.1.4** is installed at `/Applications/Advanced Right Click.app`; the prior installed app was moved to Trash, preserving preferences and recovery history. The installed signature verifies, and pluginkit reports only the enabled 0.1.4 extension from Applications. Host and extension processes run from that location. Superseded 0.1.1/0.1.2/0.1.3 installers were moved to Trash. The installer is unsigned and the app is not notarized.

## Remaining system checks

- Services fallback: menu discovery was previously visible; final end-to-end action completion remains unverified.
- Optional Finder ⌘Z bridge: requires user-granted Accessibility access and remains disabled/unverified. Right-click Undo is verified.
- Live enabled/favorite preference propagation, iCloud-provider locations, login registration and opt-in menu-bar behavior.
- Terminal launch was invoked from Finder, but the automation environment prevents inspecting Terminal; live launch behavior remains unverified.
- Force-quitting during a real Finder operation; interrupted journal recovery is covered by generated-fixture tests.
- Developer ID signing, provisioning and notarization for broader distribution.

## Compact previews (0.1.4)

Native installed-app checks used generated video, audio and six-page PDF fixtures:

- Video playback and selected-segment playback work; the start/end timeline handles respond to Accessibility adjustments, with synchronized timecodes and selected duration. Direct pointer dragging could not be driven because the automation server reported no window for that gesture.
- A range of 1–3 seconds exported a video measured at exactly 2 seconds.
- GIF preview loaded with timeline frames; selecting 2–3 seconds exported the expected eight frames.
- Audio preview displayed its decoded waveform and played the selected range. A 1–2 second range exported M4A measured at exactly 1 second.
- Selecting PDF page thumbnails and using Set start / Set end selected pages 2–4. The resulting PDF contained exactly three pages, with page 2 first and page 4 last.
- The media popup was visually inspected at 380px wide (about 415px tall for video; shorter for audio), and the PDF extraction popup at 380px wide and about 463px tall. There are no duplicated headings or long explanations.
- The panel resizes to fit asynchronously loaded previews. Closing it stops playback and cancels waveform decoding. PDF rotation previews copy pages before rotating; previewing does not modify source files.
- The final GIF panel rejects invalid timecodes by disabling Apply, and re-enables it for a valid range.
- Additional range tests cover GIF's 15-second maximum, start/end crossing, sub-frame durations, timecode parsing and invalid inputs.

The live checks above exercised the preview controls through the app's URL request handler, the same handoff used by Finder. Finder routing itself remains covered by the previous native checks and menu simulation suite.
