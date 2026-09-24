# stylus-annotations.koplugin

<img width="300" alt="Screenshot" src="https://github.com/user-attachments/assets/b555868d-4336-4ec8-a5e5-24133aa7e567" />

Hand-drawn stylus annotations for PDF, EPUB, FB2, etc. Tested on Android; if you're lucky, it might also work on Linux-based readers. The plugin supports both paged documents (PDFs) and reflowable ones (EPUBs, FB2s), although they work differently, and in reflowable documents your strokes may shift position.

> **Requirements:** KOReader v2026.07.2-60 (2026.08.12 nightly build) or later.

## How to install

- Use a plugin manager (AppStore, Storefront, etc.) and search for "stylus-annotations".
- Or download the zip from the Releases page, unzip it, and put the entire `stylus-annotations.koplugin` folder into the `koreader/plugins` directory, so you end up with the path `koreader/plugins/stylus-annotations.koplugin` with the plugin files. It should NOT be `koreader/plugins/stylus-annotations.koplugin/stylus-annotations.koplugin`.

You'll find the "Stylus annotations" settings in the second tab of the top menu, next to "Highlights".

## Features

- **Enable drawing:** when on, the plugin captures pen strokes. When off, you can use the pen as usual, as if the plugin weren't installed.
- **Live refresh:** on by default. E-ink and Android devices use an incremental fast path; other devices use a more accurate live redraw. Turn it off if your device is too slow to render strokes while you draw. When off, the stroke appears only after you finish drawing it.
- **Width and color:** change these options for all new strokes, or modify existing ones.
- **Selection and chain selection:** tap a stroke with your finger, or long-press with your stylus, to open the stroke's options. Long-press with your finger instead to select the whole chain of connected strokes and apply the options to all of them.
- **Deleting strokes:** remove all strokes on a page or in the whole document at once, so you don't have to delete them one by one.
- **Stylus eraser:** when KOReader reports the pen as an eraser, sweep the tip over annotations to remove the strokes it crosses.
- **Strokes in the PDF:** with KOReader's `Write highlights into PDF` on, KOReader also writes the strokes into the PDF as ink annotations, so other apps can show them (see "PDF ink annotations" below).
- **Bigme B1051 input:** on Android, the plugin automatically tries to connect to Bigme's handwriting service when a book opens. On Bigme firmware that exposes the service, it reads OEM pen and reverse-tip eraser events while keeping annotation storage in KOReader. Other devices continue to use KOReader's regular stylus input path, and the Bigme connection can be toggled from the plugin menu.

For Bigme, install the complete plugin folder so the bundled `core/bigme/BigmeInputBridge.dex` is present. The plugin falls back to regular KOReader input if the Bigme service cannot be started.

The bridge DEX bundles [LSPosed HiddenApiBypass 6.1](https://github.com/LSPosed/AndroidHiddenApiBypass) under Apache-2.0 to access Bigme's blocked `com.xrz` framework API. See `core/bigme/LICENSE-hiddenapibypass.txt`.

### Bigme live ink

On Bigme, strokes are drawn while you write by Bigme's own handwriting layer, the same way Bigme's reader (Base.apk) does it, instead of by KOReader's screen refresh:

- **Handwriting layer:** the bridge binds a transparent full-screen overlay (like Base.apk's `NoteView`) to the handwriting service. A worker thread draws each batch of pen points as one path and commits it with the fast handwriting waveform (`inValidate(rect, 1029)`). The overlay stays in handwriting mode, so the first commit of a stroke is not delayed.
- **Screen mirror:** a handwriting commit shows the layer exactly as it is inside the commit rectangle (transparent shows as black). The bridge therefore keeps a copy of KOReader's screen in the layer (every KOReader refresh is copied between strokes), and the ink is drawn on top of it: no black blocks, no content disappearing around the stroke.
- **Look:** the live ink uses the stroke's width at the current page zoom and its color; colors are shown as black/white dither patterns, like Base.apk does on monochrome panels. The screen is rotated in hardware (panel mounted at 270°); the bridge maps coordinates to the panel's orientation.
- **Finishing a stroke:** KOReader repaints the finished strokes 150 ms after the pen is lifted; quick consecutive strokes are not interrupted.
- **Writable everywhere:** in continuous-scroll PDFs, strokes below the last page or across a page edge are stored relative to the page they started on.
- **Fallbacks:** if the overlay cannot be created the bridge binds KOReader's window instead; if the Bigme canvas is unavailable, KOReader's incremental preview is used. The `Live refresh` menu item switches live ink off (strokes then appear only after pen-up).

Details and the Base.apk analysis behind this are in `docs/bigme-handwriting.md`. To rebuild `BigmeInputBridge.dex`, see the build steps there.

### PDF ink annotations

With a KOReader build that includes the stylus PDF sync (see the KOReader README), strokes are also stored in the PDF as ink annotations named `KOReaderStylus:...`. The `.sdr/stylus_annotations.lua` sidecar stays the source of truth:

- **Erasing** a stroke (eraser, menu, delete page/all) also deletes its copy from the open PDF, so erased strokes disappear from the page right away and from the file on the next save.
- **Opening** a PDF imports every ink stroke the plugin does not know yet: its own copies (e.g. written on another device) and ink from other apps. Other apps' ink is then rewritten as KOReader copies, so every visible stroke can be erased. Imported strokes keep their points, width and opacity; colors map to the nearest palette color. This only happens with `Write highlights into PDF` on, so the PDF is never changed otherwise.
- Import needs the MuPDF ink getters added to the KOReader build; with older builds the plugin skips it.

## Disclaimer

Still under development. The code is AI-assisted, like, a lot, so beware of the slop.

## TODO
- Some kind of bookmarks for pages with strokes
- Stylus pressure? (Base.apk's pen varies width with pressure and speed)
