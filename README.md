# Screenshotta

A small macOS menu bar screenshot tool.

- **Capture Area** (default `⌥⇧4`): crosshair, drag a rectangle, done. Full-bleed, no frame.
- **Capture Window** (default `⌥⇧5`): hover a window and click. The window keeps its rounded corners and sits on your desktop wallpaper with a very subtle shadow, ready for demos. Traffic lights are always in color: if the window was inactive, the gray ones are repainted.
- While selecting, **Space** switches between area and window mode and **Esc** cancels.
- Every capture is copied to the clipboard and saved to `~/Pictures/Screenshots` (configurable).
- A small thumbnail slides in at the bottom right: **click** to edit, **drag** into any app, or **swipe** it away.
- **Shelf** (default `⌥⇧D`, or shake the pointer while dragging files): a small floating glass panel that holds files for a moment. Drop screenshots on it (or click the tray button on the thumbnail), then drag the whole stack into a folder, a chat or a browser upload. Click the stack to see every file: Shift- or ⌘-click to select several and drag only those; Delete removes from the shelf, ⌘C copies, double-click opens. Recent shelves come back from the menu bar.
- The editor can crop, and draw arrows, lines, rectangles, circles and freehand. Copy (`⌘C`) or close the window to write the edits back to the file and the clipboard.

## Build & install

Requires macOS 14+ and Xcode 26 (Swift 6.2).

```sh
./scripts/build.sh            # builds build/Screenshotta.app
./scripts/build.sh --install  # also copies it to /Applications and launches it
```

The build signs with your first code-signing identity (override with `SIGN_IDENTITY=...`) so the Screen Recording permission survives rebuilds.
The icon lives in `Resources/AppIcon.icns`; regenerate it with `swift scripts/make-icon.swift . && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns`.

## Permissions

- **Screen Recording**: required. macOS asks on first launch; after granting it, quit and reopen the app.
- **Accessibility**: optional. Lets a window capture raise the exact window you clicked, so its traffic lights render in color.

## Layout

- `Sources/Screenshotta/Capture`: selection overlay, ScreenCaptureKit capture, window styling, output
- `Sources/Screenshotta/Thumbnail`: the floating post-capture preview
- `Sources/Screenshotta/Editor`: crop and annotation editor
- `Sources/Screenshotta/Shelf`: floating shelves, their history and shake-to-open
- `Sources/Screenshotta/Settings`: SwiftUI settings window
- `Sources/Screenshotta/Hotkeys`: global shortcuts (Carbon hotkeys, no Accessibility needed)
