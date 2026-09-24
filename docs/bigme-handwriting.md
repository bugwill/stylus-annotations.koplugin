# Bigme handwriting: how Base.apk does it, and how this plugin copies it

Notes for agents working on the Bigme live-ink path of `stylus-annotations.koplugin`.
Everything under "Base.apk findings" comes from decompiling the vendor reader
`bigme/base.apk` (not committed; ~120 MB). The service side
(`com.xrz.HandwrittenClient`) lives in the device firmware, not in the APK, so
its behaviour is **inferred from how Base.apk calls it** and must be confirmed
on a device.

## 1. Reproducing the decompile

```sh
S=<scratch dir>
unzip -q bigme/base.apk 'classes*.dex' -d $S/apk        # 6 dex files
curl -sL -o $S/jadx.zip https://github.com/skylot/jadx/releases/download/v1.5.1/jadx-1.5.1.zip
unzip -q $S/jadx.zip -d $S/jadx
JAVA_OPTS=-Xmx8g $S/jadx/bin/jadx -d $S/out --no-res -j 8 $S/apk/classes*.dex   # ~10 min
```

Some methods fail to decompile (e.g. `SimplePen2.draw`, `lib2.a.a(PenPoint)`);
add `--show-bad-code` to see them.

Key files (under `out/sources/com/xrz/`):

| File | What it is |
|---|---|
| `handwrittenPlus/view/HandwritingManager.java` | Owns `HandwrittenClient`; input callback, draw thread, commit logic |
| `handwrittenPlus/core/Painter.java` | Layers; `drawPoint()` draws a batch into layer + "mirror" (service canvas) |
| `handwrittenPlus/core/BasePen.java` | Default `draw()`: one `Path` per batch, returns `FlushInfo` |
| `handwrittenPlus/tools/SimplePen2.java`, `DefaultPen.java` | Pens used by the reader; mirror paint settings |
| `handwrittenPlus/core/FlushInfo.java` | Refresh-mode constants |
| `handwrittenPlus/view/a.java` | ColorMapper: dither `LinearGradient` shaders per color |
| `handwrittenPlus/view/NoteView.java` | `SurfaceView` the manager binds to |
| `handwritten/lib2/a.java` | "InputCooker": clips input to writable rects |
| `MainActivity.java` (`handwritingManagerInit`) | How the reader configures it |

## 2. Base.apk findings

### 2.1 Pipeline

```
HandwrittenClient.InputListener.onInputTouch(type,x,y,pressure,tool[,timeNs])   (binder thread)
  -> build PenPoint (isOutside = !viewLayout.contains(left+x, top+y))
  -> drop if: no layer, empty layout, busy, no window focus, not active & not DOWN
  -> ACTION_NEAR(0) ignored; ACTION_LEAVE(4): optional inValidate(N, 1201) if setReflushDirtyEnable(true) (default false)
  -> finger (tool 2) ignored while pen active
  -> InputCooker (writable-rect clipping) -> speed calc
  -> synchronized(list){ add; notify }
draw thread "b":
  wait -> clone+clear list -> synchronized(V){ FlushInfo = Painter.drawPoint(batch); inValidateContent(FlushInfo) }
inValidateContent (channel 1 = handwriting):
  map dirty rect world->screen, intersect with (0,0,viewW,viewH)
  setNormalCommitEnable(false)
  HandwrittenClient.inValidate(rect, flushMode)      // flushMode normally 1029
  a(100): HandlerThread msg 4 after 100 ms -> blend foreground layers
  b(100): msg 2 after 100 ms (not rescheduled if pending) -> onUpdateViewContent(false)
onUpdateViewContent(z): if normalCommitSupport: setNormalCommitEnable(z); NoteView.requestDraw()
requestUpdateContent(): msg 1 -> onUpdateViewContent(true)   // app content changed
```

So: ink reaches the panel only through the service canvas + `inValidate`.
The normal Android surface is updated separately, debounced ~100 ms, and normal
commits are **off** while ink is being committed.

### 2.2 HandwrittenClient API used by Base.apk

Construction / lifecycle: `new HandwrittenClient(Context)`, `bindView(View)`,
`connect(int w,int h)` (returns boolean), `registerInputListener(listener)`,
`unRegisterInputListener`, `disconnect()`, `unBindView()`, `getCanvas()`,
`getVersion()`, static `getDebugLevel()`.

Configuration (defaults Base.apk applies in `e()` right after connect):

| Call | Base.apk value |
|---|---|
| `setInputEnabled(bool)` | true |
| `setBlendEnabled(bool)` | false |
| `setRecommitEnabled(bool,int,int)` | false, -1, 0 |
| `setOverlayEnabled(bool)` | false |
| `setAutoCleanControlEnabled(bool)` | true (set false when window loses focus) |
| `setNormalCommitEnable(bool)` | toggled per commit, see 2.1 |

Layout: `updateLayout()` (bool), `getViewLayout()` (Rect), `getPhyViewLayout()`
(Rect), `updateRotation()` (bool), `getLastViewRotation()`,
`getCurViewRotation()`, `getPhyRotation()` (int degrees).

Commit: `inValidate(Rect, int mode)`.

Call order in Base.apk: `connect` + config (`e()`) -> `getCanvas()` (`k()`) ->
later in surfaceChanged: `updateRotation()`, `updateLayout()`, read layouts (`o()`/`r()`/`p()`).

### 2.3 Refresh modes (`FlushInfo`)

| Constant | Value |
|---|---|
| EINK_HANDWRITTEN_MODE | 1029 (default for pens) |
| EINK_RUBBER_MODE | 1030 |
| EINK_HD_RECT_MODE | 1201 |
| EINK_NORMAL_RECT_MODE | 1202 |
| EINK_GC16_RECT_MODE | 1028 |
| EINK_NORMAL_MODE | 178 (channel 2 only) |

Channels: 1 = handwriting (service canvas + inValidate), 2 = system (normal surface).
Flags: 1 = need blend, 2 = flush whole.

### 2.4 Coordinates and rotation

- `onInputTouch` x/y and the `inValidate` rect are **view** coordinates.
- The service canvas is in **physical panel** orientation. Base.apk sets
  `canvas.setMatrix(d0)` (plus world->screen, identity without zoom) before
  every mirror draw. `d0` from `HandwritingManager.p()`:

| getPhyRotation | rotate | then preTranslate |
|---|---|---|
| 0 | 0 | (0, 0) |
| 90 | 90 | (0, -viewH) |
| 180 | 180 | (-viewW, -viewH) |
| 270 | -90 | (-viewW, 0) |

- On view size / rotation change Base.apk calls `restartHandwritten()`
  (disconnect + reconnect + new canvas).

### 2.5 Mirror (service canvas) paint

- `SimplePen2`: FILL style, round cap/join; mirror copy sets `antiAlias=false`, dither true.
- `DefaultPen`: antiAlias false, dither true.
- `BasePen.onUpdateHandwritePaint`: color replaced by a ColorMapper shader
  (1x1/2x2 `LinearGradient` dither patterns of black/white or, on color panels
  — `XrzEinkManager.getSystemInfo().get("screen_type") > 0` — red/green/blue/yellow…),
  otherwise forced to `0xFF000000`. The handwriting layer is effectively bilevel.
- `BasePen.draw`: one `Path` per batch (moveTo last point, lineTo each point),
  dirty rect = union of segment bounds padded by width/2; ACTION_UP adds no segment.
- `SimplePen2` (the reader's pen, type 124): width 2–6, pressure range 2000–4096,
  width from smoothed pressure (`pow(p/(max*0.6),1.5)`) and speed; draws each
  segment as a quad between two circles (`C0059d.a`) + circle. Has a point
  predictor `O` (`setPredictStrength`). **Not ported.**

### 2.6 How the reader app sets it up (`MainActivity.handwritingManagerInit`)

`NoteView` (a `SurfaceView`, `setZOrderOnTop(true)`) over the reader;
`setRotationLinkEnable(true)`, `setInputCallback(...)`, background info, lasso
config. Menus call `setInputEnabled(false)` while open.

## 3. What this plugin does (current implementation)

Files: `stylus-annotations.koplugin/core/bigme/BigmeInputBridge.java` (+ `.dex`),
`core/bigme.lua` (JNI glue), `main.lua` (stroke logic), `core/pen.lua`
(`PenInput:onBigmeEvent`).

- KOReader is a NativeActivity: the bridge binds the Activity **DecorView**
  (there is no NoteView). Class loading: Lua copies the DEX to the app code
  cache and loads it with `DexClassLoader`.
- `com.xrz.*` is on the hidden-API blocklist on B1051; the bridge calls
  `HiddenApiBypass.addHiddenApiExemptions("Lcom/xrz/")` and uses reflection
  only (no direct `com.xrz` type references — they fail to link).
- Input: a `Proxy` implementing `InputListener` queues events; Lua drains them
  with `drain()` (string `type,x,y,pressure,tool,timeNs;...`), polling every
  16 ms with OEM ink (8 ms without). With OEM ink every MOVE point is passed
  to Lua; without it only the last MOVE per batch is kept.
- Live ink (`USE_BIGME_OEM_CANVAS_LIVE_INK = true` in main.lua): the bridge's
  worker thread copies Base.apk:
  - one `Path` per batch, drawn with the physical-rotation matrix;
  - paint: antiAlias off, dither on, round cap/join, black (`BIGME_PREVIEW_ARGB`);
  - `setNormalCommitEnable(false)` before the first `inValidate(rect, 1029)`;
  - `commitNormal()` (called by Lua inside the `setDirty` callback, i.e. after
    KOReader painted and just before it posts) sets it back to true;
  - watchdog: restores normal commit 400 ms after the pen goes idle if Lua did not;
    eraser DOWN, disabling the preview and `close()` also restore it;
  - `renderLock` guards canvas drawing, `inValidate`, normal-commit toggles and
    disconnect; the canvas is released under it before `disconnect`.
- Stroke end (`endStroke` -> `queueBigmeFinalize`): strokes go to the store;
  a 150 ms timer (cancelled by the next `startStroke`) calls `refreshRegion`
  on the merged area. `onPageUpdate`/`onPosUpdate` finalize at once.
- Preview is disabled (`setDirectInkStyle("0,...")`) when a KOReader overlay
  is on top; checked before each drained batch.
- `onSetDimensions` restarts the bridge (rotation/resize).

## 4. Building the DEX

No build script is committed. What worked (Android SDK at `~/Android/Sdk`):

1. Get HiddenApiBypass 6.1:
   `https://repo1.maven.org/maven2/org/lsposed/hiddenapibypass/hiddenapibypass/6.1/hiddenapibypass-6.1.aar`,
   unzip `classes.jar`, unzip that into `hab/`; skip `org/lsposed/hiddenapibypass/library/`.
2. Its classes reference `stub/dalvik/system/VMRuntime` and `stub/sun/misc/Unsafe`.
   Rewrite the class-file constant pool UTF8 entries to drop the `stub/` prefix
   (a ~20-line Python constant-pool rewriter works; see THIRD_PARTY_NOTICES.txt).
3. `javac -source 8 -target 8 -cp $SDK/platforms/android-35/android.jar:hab -d classes BigmeInputBridge.java`
4. Copy the rewritten `org/lsposed/hiddenapibypass/*.class` into `classes/`.
5. `$SDK/build-tools/35.0.0/d8 --release --min-api 26 --lib $SDK/platforms/android-35/android.jar --output out <all .class files>`
6. Copy `out/classes.dex` to `core/bigme/BigmeInputBridge.dex`. Lua re-copies
   it to the code cache when the contents change.

Check: `strings -n 6 BigmeInputBridge.dex | grep -E '^L(org|stub).*;$'` should
list only `org/koreader/...` and `org/lsposed/...` types (no `stub/`).

## 5. Open questions / to verify on device

- Exact semantics of `setNormalCommitEnable` and `setAutoCleanControlEnabled`
  (inferred). If KOReader UI lags after writing, look for
  `Normal commit watchdog fired` in logcat (tag `KOReaderBigmeInput`).
- Whether the DecorView-bound canvas really uses the physical orientation
  (log line prints `phyRotation` and canvas size).
- The old OEM-canvas crash was never captured in a log; the lock/lifecycle
  changes target the likely causes (drawing after disconnect, stale layout).
- Not ported: SimplePen2 pressure/speed width, point prediction, color dither
  shaders, InputCooker writable rects, HD refresh on ACTION_LEAVE.
- `core/bigme/` currently has two identical license files
  (`LICENSE-hiddenapibypass.txt`, `LICENSE-HIDDEN-API-BYPASS.txt`).

## 6. Firmware findings (device B1051, firmware mp1V328, service v1.4.0)

`com.xrz.HandwrittenClient` is in `/system/framework/framework.jar`
(`classes5.dex`); pull it with adb and decompile with
`jadx --single-class com.xrz.HandwrittenClient`. Facts from that source:

- `bindView()` calls `setNormalCommitEnable(false)`; `unBindView()` sets it true.
- `setNormalCommitEnable(b)` =
  `XrzEinkManager.setRefreshModeByView(view, 0x40000|EINK_DEFAULT_MODE)` (true)
  or `0x40400|EINK_DEFAULT_MODE` (false). It changes the refresh mode of the
  bound window (for KOReader: the whole DecorView window).
- `connect(w,h)` calls `updateRotation()`, swaps w/h for 90/270, allocates a
  shared ion buffer (`nativePrepare(..., bpp=4)`) and an input channel.
- `updateLayout()` needs `updateRotation()` to have run (it validates against
  the physical screen rect). It returns false if the view is not inside the
  physical screen; in that state `inValidate` rects are not clipped
  correctly, so the bridge refuses OEM ink.
- `getCanvas()` already applies the client's rotation matrix (same as Base.apk's `d0`).
- `inValidate(rect, mode)` maps the view rect to physical coordinates,
  intersects with the physical view layout, unions it into a pending dirty
  rect and calls `requestCommit` only when none is pending (the service
  pulls it through `IClient.onCommit`). If a commit with a *different* mode
  is pending it sleeps in 30 ms steps (up to 3 s). Frequent calls are cheap.
- Input callbacks ignore ACTION_NEAR/LEAVE and convert physical to view coordinates.
- Debug logging: `adb shell setprop persist.vendor.xrz.handritten_debuglevel 3`
  (works over adb without root). Tags: `HandwrittenClient`, `HandwrittenClient_jni`,
  `handwrittenservice`.

Device facts: `ro.surface_flinger.primary_display_orientation=ORIENTATION_270`
(panel is physically landscape 2480x1860; KOReader portrait 1860x2480, so
`phyRotation=270`), `ro.vendor.xrz.screen_type=0` (monochrome), density 300.

## 7. Debugging notes

- A system freeze shows up as `getprop sys.boot.reason` = `kernel_panic`; the
  panic record (AEE/pstore) is not readable over adb on the retail build. To
  catch what precedes a freeze, stream `adb logcat -v threadtime` to the host
  while reproducing.
- The installed app is the release package `org.koreader.launcher` (no
  `run-as`); the plugin lives in `/storage/emulated/0/koreader/plugins/` and
  can be pushed directly. KOReader must be restarted to load changes.
- KOReader's own Lua sources are in the APK at `assets/module/koreader.7z`.
- `data_app_native_crash` entries with `JNI GetObjectClass` from libluajit
  (2026-09-24 14:57–15:35) came from earlier Lua JNI bugs, not from the OEM canvas.

## 8. Lessons from device testing

- **Preview width:** stored strokes render at `width * zoom` (paged: page zoom,
  e.g. 3.97; reflow: `Screen:scaleBySize(1)`). The OEM preview must use the
  same zoom, otherwise it is much thinner than the final repaint.
- **Preview color:** send the real render color; the bridge draws non-black
  colors as a 4x4 ordered-dither `BitmapShader` (black/transparent cells),
  like Base.apk's ColorMapper does on mono panels. Solid black preview + a
  colored final stroke looks like a color change.
- **Writable areas:** in continuous-scroll PDFs (`kopt_page_scroll`),
  `ReaderView:screenToPageTransform` returns nil below the last page, and the
  old paged `addPoint` dropped points on another page, so ink there was never
  stored. A first fix (per-page writable rects sent to the bridge, stroke
  locked to its DOWN rect like Base.apk's InputCooker) was **reverted**: it hid
  the preview in exactly those areas and, when the rects went wrong, disabled
  the preview entirely (no `Ink start` in logcat, ink only after pen-up).
  Now `Paged:screenToPagePoint` maps any screen point relative to the stroke's
  page (anchoring to the last visible page below the document end), so every
  stroke is stored. `Mapping:getWritableRects` / `Bigme.setWritableRects`
  remain (nil = whole view) for mappers that really cannot store a point.
  `PenInput:onBigmeEvent` only starts strokes on ACTION_DOWN while the OEM
  preview is active.
- **Stale ink in the service canvas:** the `getCanvas()` buffer persists
  across strokes. Base.apk rewrites it from its layers (`a(rect)`, PorterDuff
  SRC); the bridge only draws, so erased strokes / earlier colors reappeared
  (as black) whenever a later 1029 commit overlapped them, until KOReader's
  next normal frame. The bridge now tracks the drawn area and resets it when
  normal commits are restored, and resets the whole canvas at startup.
- **"No ink" is white, not transparent:** the service ignores alpha.
  Clearing with `PorterDuff.Mode.CLEAR` (0x00000000) produced large black
  blocks wherever a later commit overlapped; transparent dither cells also
  showed as black. Use opaque white (`INK_EMPTY = 0xFFFFFFFF`, `Mode.SRC`):
  white leaves the panel unchanged in the handwriting waveform (Base.apk's
  ColorMapper patterns are black/white for the same reason).
- **commitNormal while the pen is down:** the worker sees a new stroke before
  Lua does. `commitNormal()` returns false while `inkPathActive`; Lua then
  re-queues that repaint (`queueBigmeFinalize`) instead of wiping the new ink.
  Disabling the preview (menus) uses an unconditional restore.
- **"Live refresh" menu item** (`stylus_annotations_live_ink`, per document)
  set to off means `live_mode = deferred`: the OEM preview is disabled
  (`Direct ink style: 0,...`), so ink only appears after pen-up. Check this
  first when "latency got much worse".
- Wireless adb changes port after the device's adbd restarts; if the old port
  is refused, scan 30000–50000 for open ports and `adb connect` again.

## 9. KOReader's PDF export of stylus strokes (erasing "saved" strokes)

The KOReader build used here (nightly, see `_meta.lua` requirement) has
`PdfDocument:syncStylusAnnotations()` (`frontend/document/pdfdocument.lua`)
and `ReaderHighlight:syncStylusAnnotationsToPdf()`. When "Write highlights
into PDF" is on, it copies this plugin's `store.strokes` into the PDF as ink
annotations named `KOReaderStylus:<page>:<index>:<hash>` on `AppPaused`,
`Suspend` and close, deleting copies of erased strokes.

After reopening, MuPDF draws those copies under the plugin's own strokes, so
erasing a saved stroke removed only the plugin's copy and it seemed to stay.

First attempt (reverted): delete all copies from the in-memory PDF on open and
after pause/resume. It made KOReader show only the sidecar strokes (so a PDF
that could not be written showed "missing" strokes) and made every
open/close cycle delete + re-add all annotations, growing the PDF each time.

Current approach: after any deletion (eraser: 0.3 s after the last erased
stroke; menu/page/all deletes: next tick) the plugin calls KOReader's own
`doc:syncStylusAnnotations(store.strokes, highlight, night_mode)` on the
in-memory PDF, which deletes exactly the copies of removed strokes (using
KOReader's naming), then repaints. The PDF file is still written by KOReader
on pause/close. The sync opens every page, so erasing in very large PDFs costs
more. The exported KOReader MuPDF API (`wrap-mupdf`, 36 symbols) cannot read
ink points, so importing PDF-only strokes into the sidecar is not possible
without parsing the PDF file.

Also seen: `main.pdf` had 272 stale `KOReaderStylus` annotations against 5
strokes in the sidecar, and MuPDF reported `trying to repair broken xref`.
Avoid `am force-stop` while KOReader may be writing the PDF.

## 10. PDF corruption from repeated incremental saves (fixed in KOReader)

Root cause of the "repaired" PDFs: MuPDF (reproduced with 1.28 via PyMuPDF,
device has 1.27.2) writes an incremental update at the file size it saw when
the document was opened. A second incremental save of the same opened
document overwrites the first update while its trailer `/Prev` still points
at the overwritten xref. Next open: `trying to repair broken xref`; after that
MuPDF refuses incremental writes (`Can't do incremental writes on a repaired
file`). The KOReader build saves PDF annotations on every trip to the
background (`ReaderHighlight:savePdfAnnotationsOnBackground`), so two
background trips per session were enough.

Fix in KOReader's `frontend/document/pdfdocument.lua`
(`PdfDocument:writeDocument`): the first save of an opened document stays
incremental; later saves, and saves after a failed incremental write, write
the whole PDF to `<file>.koreader-tmp` and `os.rename` it over the original
(MuPDF keeps reading through its open handle). Verified with PyMuPDF: 3 saves
per session and a repaired input both reopen clean with all annotations.

Plugin: `onReaderReady` now schedules `syncPdfStylusCopies()` so stale PDF
copies (from failed/broken writes) are dropped on open; when PDF and sidecar
already match, nothing changes and nothing is written.

## 11. Importing PDF ink annotations (Base.apk's generateBoxAnnot)

Base.apk (`com/xrz/core/PDFCore.java`) keeps highlights/handwriting in its own
ObjectBox DB (`BookMarksModel`), exports them tagged with `/xrzId`, renders pages
without annotations (`page.toDisplayList(true)`), imports PDF annotations into
its DB (`generateBoxAnnot`: ink list, color, border width), erases by deleting
the annotation whose `/xrzId` matches (`handwriteChange`,
`deleteAnnotationByBookmarkId`), and after every save closes and reopens the
document (`savePdf`).

Added to KOReader (you build it yourself):
- `base/wrap-mupdf.h`: `mupdf_pdf_annot_ink_list_count`,
  `..._ink_list_stroke_count`, `..._ink_list_stroke_vertex`,
  `mupdf_pdf_annot_color`, `mupdf_pdf_annot_border_width`,
  `mupdf_pdf_annot_opacity` (+ `ffi-cdecl/wrap-mupdf_cdecl.c`, `ffi/mupdf_h.lua`).
- `base/ffi/mupdf.lua`: `page:getInkAnnotations()` (points in page space, the
  space `addInkAnnotation` takes; verified to match stored strokes exactly).
- `frontend/document/pdfdocument.lua`: `PdfDocument:getInkAnnotations()`,
  `PdfDocument:deleteForeignInkAnnotations()`.

Plugin `importPdfInkAnnotations()` (on open, only with "Write highlights into
PDF" on): imports every ink stroke not already in the sidecar (key: page +
points at quarter-point precision), maps colors to the nearest palette color,
then deletes other apps' ink from the in-memory PDF; the following sync writes
them back as `KOReaderStylus` copies. Idempotent on reopen.
