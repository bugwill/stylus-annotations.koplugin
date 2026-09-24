package org.koreader.bigme;

import android.app.Activity;
import android.app.Application;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapShader;
import android.graphics.Canvas;
import android.graphics.ColorMatrix;
import android.graphics.ColorMatrixColorFilter;
import android.graphics.Matrix;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.PixelFormat;
import android.graphics.PorterDuff;
import android.graphics.Rect;
import android.graphics.Shader;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.Process;
import android.util.Log;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.view.ViewGroup;

import org.lsposed.hiddenapibypass.HiddenApiBypass;

import java.lang.reflect.InvocationHandler;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.ArrayDeque;
import java.util.Deque;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.Callable;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.FutureTask;
import java.util.concurrent.TimeUnit;

/**
 * Reflective adapter for Bigme's system handwriting service.
 *
 * Keep com.xrz classes out of the DEX type table: some Bigme firmware exposes
 * HandwrittenClient from the boot class path but direct bytecode references to
 * it fail to link from a regular application. Reflection matches the vendor
 * access pattern used by the inksdk project.
 *
 * The live-ink path mirrors Base.apk's HandwritingManager:
 * callback -> queue -> dedicated draw thread -> one Path per batch on the
 * service canvas (physical orientation) -> setNormalCommitEnable(false) ->
 * inValidate(rect, 1029). The normal surface is committed again only when
 * KOReader repaints the finished stroke (commitNormal) or after an idle
 * watchdog, so KOReader's own refreshes never race the handwriting layer.
 */
public final class BigmeInputBridge {
    private static final String TAG = "KOReaderBigmeInput";
    private static final String CLIENT_NAME = "com.xrz.HandwrittenClient";
    private static final String LISTENER_NAME = CLIENT_NAME + "$InputListener";
    private static final int MAX_QUEUED_EVENTS = 4096;
    private static final int MODE_HANDWRITE = 1029;
    private static final int ACTION_DOWN = 1;
    private static final int ACTION_MOVE = 2;
    private static final int ACTION_UP = 3;
    private static final int ACTION_LEAVE = 4;
    private static final int TOOL_PEN = 0;
    private static final int TOOL_ERASER = 1;
    /**
     * A 1029 commit shows the service canvas as-is inside the commit rect
     * (alpha is ignored: transparent shows black, white shows white). The
     * canvas therefore mirrors KOReader's screen (setScreenBuffer /
     * screenUpdated), and ink is drawn on top of that copy. Without a mirror,
     * white is the least bad "no ink" value.
     */
    private static final int INK_EMPTY_OVERLAY = 0xFFFFFFFF;
    private static final int INK_EMPTY_DECOR = 0xFFFFFFFF;
    private static final long OVERLAY_READY_TIMEOUT_MS = 3000L;
    /** Safety net: restore normal commits if KOReader never calls commitNormal. */
    private static final long NORMAL_COMMIT_WATCHDOG_MS = 400L;
    private static final Handler MAIN_HANDLER = new Handler(Looper.getMainLooper());

    private final Deque<PenEvent> events = new ArrayDeque<>();
    private final Deque<PenEvent> directInkEvents = new ArrayDeque<>();
    private final Object directInkLock = new Object();
    /** Guards the service canvas, inValidate/setNormalCommitEnable and disconnect. */
    private final Object renderLock = new Object();
    private final Set<Integer> loggedToolTypes = new HashSet<>();
    private long lastQueueWarningNs;
    private long lastDirectInkQueueWarningNs;
    private long lastDirectInkSlowWarningNs;
    private long lastEraserLogNs;
    private Object client;
    private Class<?> clientClass;
    private Class<?> listenerClass;
    private Object listener;
    private View boundView;
    /** Transparent overlay the service is bound to (Base.apk's NoteView), or null. */
    private SurfaceView overlayView;
    private volatile boolean overlaySurfaceValid;
    private volatile int inkEmpty = INK_EMPTY_DECOR;
    /** KOReader's RGBA32 framebuffer (direct buffer on its memory), or null. */
    private volatile ByteBuffer screenBuffer;
    private volatile int screenStride;
    private volatile int screenWidth;
    private volatile int screenHeight;
    /** Screen area changed by KOReader and not yet copied (guarded by directInkLock). */
    private final Rect pendingMirror = new Rect();
    private boolean pendingMirrorInverse;
    /** The canvas holds KOReader's frame, so "no ink" is simply the page. */
    private volatile boolean mirrorActive;
    private byte[] mirrorBytes;
    private final Paint mirrorPaint = new Paint();
    private final Paint mirrorInvertPaint = new Paint();
    private int width;
    private int height;
    private int phyRotation;
    private final Matrix phyMatrix = new Matrix();
    private Canvas inkCanvas;
    private Method invalidateMethod;
    private Method normalCommitMethod;
    private Paint inkPaint;
    private final Path inkPath = new Path();
    private final Rect inkDirty = new Rect();
    /** Area drawn on the service canvas since it was last cleared (view coordinates). */
    private final Rect inkDrawnBounds = new Rect();
    private volatile boolean directInkAvailable;
    private volatile boolean directInkEnabled;
    private volatile boolean directInkWorkerRunning;
    private volatile float directInkStrokeWidth = 2.0f;
    private volatile int directInkColor = 0xFF000000;
    /** Dither pattern for non-black ink (Base.apk's ColorMapper), or null. */
    private volatile Shader directInkShader;
    /** Areas where KOReader can anchor a stroke, in view coordinates; null = anywhere. */
    private volatile Rect[] writableRects;
    /** Writable rect the current stroke started in (Base.apk's InputCooker lock). */
    private Rect lockedWritableRect;
    private boolean strokeWritable;
    private Thread directInkWorker;
    private boolean inkPathActive;
    private int inkLastX;
    private int inkLastY;
    /** True while normal commits are suspended for handwriting (guarded by renderLock). */
    private boolean normalCommitSuspended;
    private long lastInkCommitMs;
    /**
     * False while KOReader's activity is paused. The Bigme service keeps
     * calling our listener for pen input in other apps (launcher, notes);
     * those events must never reach KOReader's queue.
     */
    private volatile boolean appForeground = true;
    private Activity boundActivity;
    private Application.ActivityLifecycleCallbacks lifecycleCallbacks;

    public BigmeInputBridge() {
    }

    public String start(final Context context) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            // Cannot wait for the overlay surface on the UI thread.
            return startOnMainThread(context, null);
        }
        final SurfaceView overlay = context instanceof Activity
                ? createOverlay((Activity) context) : null;
        FutureTask<String> task = new FutureTask<>(new Callable<String>() {
            @Override
            public String call() {
                return startOnMainThread(context, overlay);
            }
        });
        if (!MAIN_HANDLER.post(task)) {
            return "ERROR,could not schedule Bigme setup on Android UI thread";
        }
        try {
            return task.get(6, TimeUnit.SECONDS);
        } catch (Throwable error) {
            task.cancel(true);
            Log.e(TAG, "Timed out setting up Bigme input on UI thread", error);
            return "ERROR,Bigme UI thread setup timed out";
        }
    }

    /**
     * Add a full-screen transparent SurfaceView on top of KOReader, like
     * Base.apk's NoteView (RGBA, setZOrderOnTop(true)). Returns once its
     * surface exists, or null (the DecorView is used instead).
     */
    private SurfaceView createOverlay(final Activity activity) {
        final CountDownLatch ready = new CountDownLatch(1);
        FutureTask<SurfaceView> task = new FutureTask<>(new Callable<SurfaceView>() {
            @Override
            public SurfaceView call() {
                SurfaceView view = new SurfaceView(activity);
                view.setZOrderOnTop(true);
                view.getHolder().setFormat(PixelFormat.TRANSLUCENT);
                view.setFocusable(false);
                view.setClickable(false);
                view.getHolder().addCallback(new OverlayCallback(ready));
                activity.addContentView(view, new ViewGroup.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.MATCH_PARENT));
                return view;
            }
        });
        if (!MAIN_HANDLER.post(task)) return null;
        SurfaceView view;
        try {
            view = task.get(3, TimeUnit.SECONDS);
        } catch (Throwable error) {
            Log.w(TAG, "Could not add handwriting overlay; binding DecorView", error);
            task.cancel(true);
            return null;
        }
        try {
            if (ready.await(OVERLAY_READY_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                Log.i(TAG, "Handwriting overlay ready: " + view.getWidth() + "x"
                        + view.getHeight());
                return view;
            }
            Log.w(TAG, "Handwriting overlay surface not ready; binding DecorView");
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
        }
        removeOverlayAsync(view);
        return null;
    }

    private static void removeOverlayAsync(final View view) {
        if (view == null) return;
        MAIN_HANDLER.post(new Runnable() {
            @Override
            public void run() {
                removeOverlay(view);
            }
        });
    }

    private static void removeOverlay(View view) {
        if (view != null && view.getParent() instanceof ViewGroup) {
            ((ViewGroup) view.getParent()).removeView(view);
        }
    }

    private final class OverlayCallback implements SurfaceHolder.Callback {
        private final CountDownLatch ready;

        OverlayCallback(CountDownLatch ready) {
            this.ready = ready;
        }

        @Override
        public void surfaceCreated(SurfaceHolder holder) {
        }

        @Override
        public void surfaceChanged(SurfaceHolder holder, int format, int w, int h) {
            // Post one fully transparent frame so the overlay never hides
            // KOReader, then let the bridge connect.
            try {
                Canvas canvas = holder.lockCanvas();
                if (canvas != null) {
                    canvas.drawColor(0, PorterDuff.Mode.CLEAR);
                    holder.unlockCanvasAndPost(canvas);
                }
            } catch (Throwable error) {
                Log.w(TAG, "Could not clear handwriting overlay", error);
            }
            overlaySurfaceValid = w > 0 && h > 0;
            if (overlaySurfaceValid) ready.countDown();
        }

        @Override
        public void surfaceDestroyed(SurfaceHolder holder) {
            // App in background: skip OEM drawing until the surface returns.
            overlaySurfaceValid = false;
        }
    }

    private synchronized String startOnMainThread(Context context, SurfaceView overlay) {
        if (client != null) {
            removeOverlay(overlay);
            return "OK," + width + "," + height;
        }
        if (!(context instanceof Activity)) {
            removeOverlay(overlay);
            return "ERROR,KOReader context is not an Activity";
        }

        try {
            Activity activity = (Activity) context;
            if (overlay != null && overlay.getWidth() > 0 && overlay.getHeight() > 0) {
                overlayView = overlay;
                boundView = overlay;
                inkEmpty = INK_EMPTY_OVERLAY;
            } else {
                removeOverlay(overlay);
                overlayView = null;
                boundView = activity.getWindow().getDecorView();
                inkEmpty = INK_EMPTY_DECOR;
            }
            width = boundView.getWidth();
            height = boundView.getHeight();
            if (width <= 0 || height <= 0) {
                releaseClient();
                return "ERROR,KOReader view has no size yet";
            }
            Log.i(TAG, "Binding handwriting to " + (overlayView != null
                    ? "transparent overlay" : "KOReader DecorView")
                    + ", empty ink=0x" + Integer.toHexString(inkEmpty));

            // B1051 marks the xrz framework API as BLOCKED in Android's
            // hidden-API list. Ordinary reflection therefore cannot find its
            // public constructor/methods. Exempt only Bigme's vendor package;
            // this is process-local and does not change Android global policy.
            boolean exemptionsAdded = HiddenApiBypass.addHiddenApiExemptions("Lcom/xrz/");
            Log.i(TAG, "Bigme hidden-API exemption for com.xrz: " + exemptionsAdded);

            clientClass = Class.forName(CLIENT_NAME);
            client = clientClass.getConstructor(Context.class).newInstance(context);
            listenerClass = Class.forName(LISTENER_NAME, true, clientClass.getClassLoader());
            listener = Proxy.newProxyInstance(
                    clientClass.getClassLoader(),
                    new Class<?>[] { listenerClass },
                    new InputHandler());

            Object bindResult = call("bindView", new Class<?>[] { View.class }, boundView);
            if (bindResult instanceof Number && ((Number) bindResult).intValue() != 0) {
                releaseClient();
                return "ERROR,Bigme refused to bind KOReader view";
            }

            // Same order as HandwritingManager.e()/k()/o(): connect and
            // configure first, then fetch the canvas, then read the layout.
            Object connected = call("connect",
                    new Class<?>[] { int.class, int.class }, width, height);
            if (!(connected instanceof Boolean) || !((Boolean) connected)) {
                releaseClient();
                return "ERROR,Bigme handwriting client did not connect";
            }

            call("registerInputListener", new Class<?>[] { listenerClass }, listener);
            call("setInputEnabled", new Class<?>[] { boolean.class }, true);
            callOptional("setBlendEnabled", new Class<?>[] { boolean.class }, false);
            callOptional("setRecommitEnabled",
                    new Class<?>[] { boolean.class, int.class, int.class }, false, -1, 0);
            callOptional("setOverlayEnabled", new Class<?>[] { boolean.class }, false);
            callOptional("setAutoCleanControlEnabled", new Class<?>[] { boolean.class }, true);
            // Bound to the overlay, keep the service's bindView() default
            // (normal commit off) for good, like Base.apk keeps its NoteView
            // in handwriting mode between strokes: switching per stroke made
            // the first commit of every stroke take ~125 ms, so fast strokes
            // piled up into one large, flashing commit rect. KOReader's own
            // window is a separate layer and refreshes normally regardless.
            if (overlayView == null) {
                callOptional("setNormalCommitEnable", new Class<?>[] { boolean.class }, true);
            }

            initializeDirectInk();
            registerLifecycle(activity);

            Object version = callOptional("getVersion", new Class<?>[0]);
            Log.i(TAG, "Bigme input connected; view=" + width + "x" + height
                    + ", phyRotation=" + phyRotation
                    + ", service=" + version + ", direct ink=" + directInkAvailable);
            return "OK," + width + "," + height;
        } catch (Throwable error) {
            Throwable cause = unwrap(error);
            Log.e(TAG, "Could not start Bigme input bridge", cause);
            releaseClient();
            return "ERROR," + cause.getClass().getSimpleName() + ": " + cause.getMessage();
        }
    }

    private Object call(String name, Class<?>[] parameterTypes, Object... arguments)
            throws Exception {
        if (client == null || clientClass == null) {
            throw new IllegalStateException("Bigme client is not initialized");
        }
        Method method = clientClass.getMethod(name, parameterTypes);
        try {
            return method.invoke(client, arguments);
        } catch (InvocationTargetException error) {
            Throwable cause = error.getCause();
            if (cause instanceof Exception) throw (Exception) cause;
            if (cause instanceof Error) throw (Error) cause;
            throw error;
        }
    }

    private Object callOptional(String name, Class<?>[] parameterTypes, Object... arguments) {
        try {
            return call(name, parameterTypes, arguments);
        } catch (Throwable error) {
            Log.d(TAG, "Optional Bigme method unavailable: " + name + " ("
                    + error.getClass().getSimpleName() + ")");
            return null;
        }
    }

    /**
     * Read the view/physical layout the way HandwritingManager.o()/r()/p()
     * does. Input and inValidate use view coordinates; the service canvas is
     * in panel orientation, so drawing goes through the rotation matrix.
     */
    private boolean updateLayout() {
        // connect() already ran updateRotation(), which sets the physical
        // screen rect that updateLayout() validates against.
        callOptional("updateRotation", new Class<?>[0]);
        Object updated = callOptional("updateLayout", new Class<?>[0]);
        boolean layoutValid = Boolean.TRUE.equals(updated);
        Object viewLayout = callOptional("getViewLayout", new Class<?>[0]);
        if (viewLayout instanceof Rect && !((Rect) viewLayout).isEmpty()) {
            width = ((Rect) viewLayout).width();
            height = ((Rect) viewLayout).height();
        }
        Object rotation = callOptional("getPhyRotation", new Class<?>[0]);
        phyRotation = rotation instanceof Number ? ((Number) rotation).intValue() : 0;

        int rotate;
        float dx = 0.0f;
        float dy = 0.0f;
        switch (phyRotation) {
            case 90:
                rotate = 90;
                dy = -height;
                break;
            case 180:
                rotate = 180;
                dx = -width;
                dy = -height;
                break;
            case 270:
                rotate = -90;
                dx = -width;
                break;
            default:
                if (phyRotation != 0) Log.w(TAG, "Unexpected Bigme rotation " + phyRotation);
                rotate = 0;
                break;
        }
        synchronized (renderLock) {
            phyMatrix.reset();
            phyMatrix.setRotate(rotate);
            phyMatrix.preTranslate(dx, dy);
        }
        Log.i(TAG, "Bigme layout: updateLayout=" + updated + ", view=" + viewLayout
                + ", phyView=" + callOptional("getPhyViewLayout", new Class<?>[0])
                + ", phyRotation=" + phyRotation + ", size=" + width + "x" + height);
        return layoutValid;
    }

    private void initializeDirectInk() {
        directInkAvailable = false;
        try {
            // HandwritingManager fetches the canvas right after connect and
            // reads the layout afterwards; the layout is needed either way
            // because it defines the coordinate space reported to KOReader.
            Object canvas = callOptional("getCanvas", new Class<?>[0]);
            boolean layoutValid = updateLayout();
            if (canvas == null) return;
            if (!layoutValid) {
                // HandwrittenClient.inValidate() maps rects through the
                // physical layout; with an invalid layout they can fall
                // outside the panel. Never commit ink in that state.
                Log.w(TAG, "Bigme layout invalid; OEM Canvas renderer disabled");
                return;
            }
            invalidateMethod = clientClass.getMethod("inValidate", Rect.class, int.class);
            normalCommitMethod = clientClass.getMethod("setNormalCommitEnable", boolean.class);
            if (!(canvas instanceof Canvas)) {
                Log.w(TAG, "Bigme getCanvas did not return an Android Canvas");
                return;
            }
            // Base.apk's handwrite paint: no anti-aliasing (the 1029 waveform
            // is effectively bilevel), dithered, round joins.
            Paint paint = new Paint();
            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeCap(Paint.Cap.ROUND);
            paint.setStrokeJoin(Paint.Join.ROUND);
            paint.setAntiAlias(false);
            paint.setDither(true);
            synchronized (renderLock) {
                inkCanvas = (Canvas) canvas;
                inkCanvas.drawColor(inkEmpty, PorterDuff.Mode.SRC);
                inkDrawnBounds.setEmpty();
                inkPaint = paint;
                inkDirty.setEmpty();
                inkPath.reset();
                inkPathActive = false;
                normalCommitSuspended = false;
            }
            directInkAvailable = true;
            startDirectInkWorker();
            Log.i(TAG, "Bigme OEM Canvas renderer is available; canvas="
                    + inkCanvas.getWidth() + "x" + inkCanvas.getHeight());
        } catch (Throwable error) {
            Log.w(TAG, "Bigme OEM Canvas renderer unavailable; keeping KOReader renderer",
                    unwrap(error));
            synchronized (renderLock) {
                inkCanvas = null;
                inkPaint = null;
            }
            invalidateMethod = null;
            normalCommitMethod = null;
        }
    }

    /** Set plugin-approved preview state, line width, and ARGB color. */
    public boolean setDirectInkStyle(String config) {
        if (!directInkAvailable || config == null) return false;
        try {
            String[] fields = config.split(",");
            if (fields.length != 3) return false;
            boolean enabled = "1".equals(fields[0]);
            float strokeWidth = Math.max(1.0f, Float.parseFloat(fields[1]));
            int color = (int) Long.parseLong(fields[2], 16);
            directInkStrokeWidth = strokeWidth;
            if (color != directInkColor || directInkShader == null && !isNearBlack(color)) {
                directInkShader = createDitherShader(color, mirrorActive ? 0 : inkEmpty);
            }
            directInkColor = color;
            boolean wasEnabled = directInkEnabled;
            directInkEnabled = enabled && directInkAvailable;
            Log.i(TAG, "Direct ink style: " + config + " -> enabled=" + directInkEnabled
                    + ", shader=" + (directInkShader != null));
            if (wasEnabled && !directInkEnabled) {
                enqueueDirectInkRelease();
                // Menus and dialogs must reach the panel immediately.
                forceCommitNormal();
            }
            return true;
        } catch (Throwable error) {
            Log.w(TAG, "Invalid direct ink configuration", error);
            return false;
        }
    }

    /**
     * Set the screen areas where KOReader can store a stroke, as
     * "left,top,right,bottom;..." in view coordinates. Empty = whole view.
     * Like Base.apk's writable rects, ink is only previewed inside the rect a
     * stroke started in, so the preview never shows ink KOReader will drop.
     */
    public boolean setWritableRects(String spec) {
        try {
            if (spec == null || spec.isEmpty()) {
                if (writableRects != null) Log.i(TAG, "Writable rects: whole view");
                writableRects = null;
                return true;
            }
            String[] items = spec.split(";");
            Rect[] rects = new Rect[items.length];
            for (int i = 0; i < items.length; i++) {
                String[] f = items[i].split(",");
                if (f.length != 4) return false;
                rects[i] = new Rect(Integer.parseInt(f[0]), Integer.parseInt(f[1]),
                        Integer.parseInt(f[2]), Integer.parseInt(f[3]));
            }
            writableRects = rects;
            Log.i(TAG, "Writable rects: " + spec);
            return true;
        } catch (Throwable error) {
            Log.w(TAG, "Invalid writable rects: " + spec, error);
            return false;
        }
    }

    /**
     * Give the bridge KOReader's framebuffer: a direct buffer on its RGBA32
     * memory, plus "stride,width,height" (stride in bytes). Coordinates must
     * match the bound view. The whole screen is mirrored once.
     */
    public boolean setScreenBuffer(ByteBuffer buffer, String geometry) {
        try {
            String[] f = geometry.split(",");
            int stride = Integer.parseInt(f[0]);
            int w = Integer.parseInt(f[1]);
            int h = Integer.parseInt(f[2]);
            boolean inverse = f.length > 3 && "1".equals(f[3]);
            if (buffer == null || !buffer.isDirect() || w != width || h != height
                    || stride < w * 4 || buffer.capacity() < (long) stride * h) {
                Log.w(TAG, "Screen mirror unavailable: " + geometry + " for view "
                        + width + "x" + height);
                return false;
            }
            screenStride = stride;
            screenWidth = w;
            screenHeight = h;
            screenBuffer = buffer;
            ColorMatrix invert = new ColorMatrix(new float[] {
                    -1, 0, 0, 0, 255, 0, -1, 0, 0, 255, 0, 0, -1, 0, 255, 0, 0, 0, 1, 0 });
            mirrorPaint.setXfermode(new android.graphics.PorterDuffXfermode(PorterDuff.Mode.SRC));
            mirrorInvertPaint.setXfermode(
                    new android.graphics.PorterDuffXfermode(PorterDuff.Mode.SRC));
            mirrorInvertPaint.setColorFilter(new ColorMatrixColorFilter(invert));
            mirrorActive = true;
            // Dither gaps must now be transparent (page shows through).
            directInkShader = createDitherShader(directInkColor, 0);
            requestMirror(0, 0, w, h, inverse);
            Log.i(TAG, "Screen mirror enabled: " + geometry);
            return true;
        } catch (Throwable error) {
            Log.w(TAG, "Could not enable screen mirror", error);
            return false;
        }
    }

    /** KOReader refreshed "x,y,w,h,inverse" of its screen; mirror it soon. */
    public void screenUpdated(String spec) {
        if (!mirrorActive || spec == null) return;
        try {
            String[] f = spec.split(",");
            requestMirror(Integer.parseInt(f[0]), Integer.parseInt(f[1]),
                    Integer.parseInt(f[2]), Integer.parseInt(f[3]),
                    f.length > 4 && "1".equals(f[4]));
        } catch (Throwable error) {
            Log.w(TAG, "Invalid screen update: " + spec, error);
        }
    }

    private void requestMirror(int x, int y, int w, int h, boolean inverse) {
        synchronized (directInkLock) {
            int left = Math.max(0, x);
            int top = Math.max(0, y);
            int right = Math.min(screenWidth, x + w);
            int bottom = Math.min(screenHeight, y + h);
            if (right <= left || bottom <= top) return;
            if (pendingMirror.isEmpty()) pendingMirror.set(left, top, right, bottom);
            else pendingMirror.union(left, top, right, bottom);
            pendingMirrorInverse = inverse;
            directInkLock.notifyAll();
        }
    }

    /** Copy a region of KOReader's frame onto the service canvas (renderLock held). */
    private void mirrorScreenLocked(Rect region, boolean inverse) {
        ByteBuffer source = screenBuffer;
        if (source == null || inkCanvas == null || region.isEmpty()) return;
        long startNs = System.nanoTime();
        int w = region.width();
        int h = region.height();
        int rowBytes = w * 4;
        int total = rowBytes * h;
        if (mirrorBytes == null || mirrorBytes.length < total) mirrorBytes = new byte[total];
        ByteBuffer rows = source.duplicate();
        int stride = screenStride;
        for (int row = 0; row < h; row++) {
            rows.position((region.top + row) * stride + region.left * 4);
            rows.get(mirrorBytes, row * rowBytes, rowBytes);
        }
        // KOReader's RGBA32 byte order matches ARGB_8888's in-memory layout.
        Bitmap bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
        bitmap.copyPixelsFromBuffer(ByteBuffer.wrap(mirrorBytes, 0, total));
        bitmap.setHasAlpha(false);
        inkCanvas.save();
        inkCanvas.setMatrix(phyMatrix);
        inkCanvas.drawBitmap(bitmap, region.left, region.top,
                inverse ? mirrorInvertPaint : mirrorPaint);
        inkCanvas.restore();
        bitmap.recycle();
        long ms = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startNs);
        if (ms > 30) Log.i(TAG, "Screen mirror " + region + " took " + ms + "ms");
    }

    private static boolean isNearBlack(int argb) {
        return luminance(argb) < 0.2f;
    }

    private static float luminance(int argb) {
        int r = (argb >> 16) & 0xFF;
        int g = (argb >> 8) & 0xFF;
        int b = argb & 0xFF;
        return (0.299f * r + 0.587f * g + 0.114f * b) / 255.0f;
    }

    /**
     * The handwriting waveform is bilevel, so Base.apk shows pen colors as
     * black/white patterns. Approximate the gray KOReader will render with a
     * 4x4 ordered dither; the other cells are white, i.e. "no ink".
     */
    private static Shader createDitherShader(int argb, int empty) {
        if (isNearBlack(argb)) return null;
        int[] bayer = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };
        int black = Math.round((1.0f - luminance(argb)) * 16.0f);
        black = Math.max(4, Math.min(16, black));
        if (black >= 15) return null;
        int[] pixels = new int[16];
        for (int i = 0; i < 16; i++) {
            pixels[i] = bayer[i] < black ? 0xFF000000 : empty;
        }
        Bitmap pattern = Bitmap.createBitmap(pixels, 4, 4, Bitmap.Config.ARGB_8888);
        return new BitmapShader(pattern, Shader.TileMode.REPEAT, Shader.TileMode.REPEAT);
    }

    private Rect findWritableRect(int x, int y) {
        Rect[] rects = writableRects;
        if (rects == null) return null;
        for (Rect rect : rects) {
            if (rect.contains(x, y)) return rect;
        }
        return null;
    }

    /**
     * Re-enable normal surface commits. KOReader calls this right before it
     * posts the repaint that contains the finished strokes, matching
     * HandwritingManager.onUpdateViewContent(true).
     */
    public boolean commitNormal() {
        synchronized (renderLock) {
            // The worker sees the pen before Lua does: a stroke may already be
            // in progress. Keep its ink; Lua retries after that stroke.
            if (inkPathActive) return false;
            restoreNormalCommitLocked();
            return true;
        }
    }

    /** Restore normal commits unconditionally (preview disabled, menus). */
    private void forceCommitNormal() {
        synchronized (renderLock) {
            inkPathActive = false;
            restoreNormalCommitLocked();
        }
    }

    private void restoreNormalCommitLocked() {
        if (!normalCommitSuspended) return;
        normalCommitSuspended = false;
        Log.i(TAG, "Ink end");
        if (client == null || normalCommitMethod == null) return;
        if (overlayView == null) {
            try {
                normalCommitMethod.invoke(client, true);
            } catch (Throwable error) {
                Log.w(TAG, "Could not restore Bigme normal commit", unwrap(error));
            }
        }
        clearInkLocked();
    }

    /**
     * Reset preview ink on the service canvas to white ("no ink") once
     * KOReader's own frame has taken over. Base.apk rewrites the canvas from its layers (PorterDuff
     * SRC) for the same reason: otherwise old ink (erased strokes, earlier
     * colors) reappears whenever a later handwriting commit overlaps it.
     */
    private void clearInkLocked() {
        if (mirrorActive) {
            // KOReader's repaint of this area arrives via screenUpdated().
            inkDrawnBounds.setEmpty();
            return;
        }
        if (inkCanvas == null || inkDrawnBounds.isEmpty()) return;
        try {
            inkCanvas.save();
            inkCanvas.setMatrix(phyMatrix);
            inkCanvas.clipRect(inkDrawnBounds);
            inkCanvas.drawColor(inkEmpty, PorterDuff.Mode.SRC);
            inkCanvas.restore();
        } catch (Throwable error) {
            Log.w(TAG, "Could not clear Bigme ink canvas", error);
        }
        inkDrawnBounds.setEmpty();
    }

    private void startDirectInkWorker() {
        if (!directInkAvailable) return;
        synchronized (directInkLock) {
            if (directInkWorkerRunning) return;
            directInkWorkerRunning = true;
            directInkWorker = new Thread(new Runnable() {
                @Override
                public void run() {
                    runDirectInkWorker();
                }
            }, "Bigme-ink-renderer");
            directInkWorker.start();
            Log.i(TAG, "Base-style direct ink worker started");
        }
    }

    private void stopDirectInkWorker() {
        Thread worker;
        synchronized (directInkLock) {
            directInkEnabled = false;
            directInkWorkerRunning = false;
            directInkEvents.clear();
            directInkLock.notifyAll();
            worker = directInkWorker;
            directInkWorker = null;
        }
        if (worker != null && worker != Thread.currentThread()) {
            worker.interrupt();
            try {
                worker.join(500L);
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
            }
            if (worker.isAlive()) {
                // Safe anyway: the worker re-checks inkCanvas under renderLock,
                // and releaseClient clears it under the same lock.
                Log.w(TAG, "Bigme ink renderer did not stop within 500ms");
            }
        }
    }

    private void enqueueDirectInkRelease() {
        synchronized (directInkLock) {
            if (!directInkWorkerRunning) return;
            directInkEvents.addLast(new PenEvent(ACTION_UP, 0, 0, 0, TOOL_PEN, 0L,
                    System.nanoTime()));
            directInkLock.notifyAll();
        }
    }

    private void enqueueDirectInkEvent(PenEvent event) {
        synchronized (directInkLock) {
            if (!directInkWorkerRunning) return;
            if (directInkEvents.size() >= MAX_QUEUED_EVENTS) {
                directInkEvents.removeFirst();
                long nowNs = System.nanoTime();
                if (nowNs - lastDirectInkQueueWarningNs > TimeUnit.SECONDS.toNanos(2)) {
                    lastDirectInkQueueWarningNs = nowNs;
                    Log.w(TAG, "Bigme direct ink queue full; dropped oldest point");
                }
            }
            directInkEvents.addLast(event);
            directInkLock.notifyAll();
        }
    }

    /**
     * Mirror Base.apk's callback -> Java queue -> worker -> dirty-rect commit
     * path. The worker never waits for KOReader's periodic Lua input poll.
     */
    private void runDirectInkWorker() {
        try {
            // Ink preview is latency-sensitive UI work. Give the dedicated
            // worker Android's display-thread priority, as Base's renderer
            // keeps drawing off the UI/Lua event loop.
            Process.setThreadPriority(Process.THREAD_PRIORITY_DISPLAY);
        } catch (Throwable error) {
            Log.w(TAG, "Could not raise Bigme ink worker priority", error);
        }
        Rect mirror = null;
        boolean mirrorInverse = false;
        while (true) {
            ArrayList<PenEvent> batch = new ArrayList<>();
            synchronized (directInkLock) {
                while (directInkWorkerRunning && directInkEvents.isEmpty()
                        && (pendingMirror.isEmpty() || isStrokeActive())) {
                    long waitMs = normalCommitWatchdogDelayMs();
                    if (waitMs == 0L) break;
                    try {
                        if (waitMs > 0L) directInkLock.wait(waitMs);
                        else directInkLock.wait();
                    } catch (InterruptedException error) {
                        return;
                    }
                }
                if (!directInkWorkerRunning) return;
                while (!directInkEvents.isEmpty() && batch.size() < 512) {
                    batch.add(directInkEvents.removeFirst());
                }
                if (!pendingMirror.isEmpty() && !isStrokeActive()) {
                    mirror = new Rect(pendingMirror);
                    mirrorInverse = pendingMirrorInverse;
                    pendingMirror.setEmpty();
                }
            }
            if (mirror != null) {
                // Before any new ink: the page under it must be current.
                synchronized (renderLock) {
                    try {
                        mirrorScreenLocked(mirror, mirrorInverse);
                    } catch (Throwable error) {
                        mirrorActive = false;
                        Log.e(TAG, "Screen mirror failed; disabled", error);
                    }
                }
                mirror = null;
                if (batch.isEmpty()) continue;
            }
            if (batch.isEmpty()) {
                // Pen idle and KOReader never repainted: do not leave the
                // normal surface frozen.
                synchronized (renderLock) {
                    if (normalCommitSuspended && !inkPathActive) {
                        Log.i(TAG, "Normal commit watchdog fired");
                        restoreNormalCommitLocked();
                    }
                }
                continue;
            }
            drawDirectInkBatch(batch);
        }
    }

    private boolean isStrokeActive() {
        synchronized (renderLock) {
            return inkPathActive;
        }
    }

    /** -1: wait indefinitely; 0: watchdog due now; >0: wait this long. */
    private long normalCommitWatchdogDelayMs() {
        synchronized (renderLock) {
            if (!normalCommitSuspended || inkPathActive) return -1L;
            long remaining = lastInkCommitMs + NORMAL_COMMIT_WATCHDOG_MS
                    - android.os.SystemClock.uptimeMillis();
            return remaining > 0L ? remaining : 0L;
        }
    }

    private void drawDirectInkBatch(ArrayList<PenEvent> batch) {
        long renderStartNs = System.nanoTime();
        long maxQueueAgeNs = 0L;
        synchronized (renderLock) {
            if (!directInkAvailable || client == null || inkCanvas == null || inkPaint == null) {
                return;
            }
            if (overlayView != null && !overlaySurfaceValid) return;
            try {
                float strokeWidth = Math.max(1.0f, directInkStrokeWidth);
                inkPaint.setStrokeWidth(strokeWidth);
                inkPaint.setColor(0xFF000000);
                inkPaint.setShader(directInkShader);
                int pad = Math.max(1, (int) Math.ceil(strokeWidth / 2.0f) + 1);
                inkPath.reset();
                if (inkPathActive) inkPath.moveTo(inkLastX, inkLastY);
                boolean pathHasSegments = false;
                for (PenEvent event : batch) {
                    maxQueueAgeNs = Math.max(maxQueueAgeNs,
                            renderStartNs - event.queuedAtNs);
                    if (event.toolType == TOOL_ERASER && event.eventType == ACTION_DOWN) {
                        inkPathActive = false;
                        // The eraser repaints through KOReader immediately.
                        restoreNormalCommitLocked();
                        continue;
                    }
                    if (event.toolType != TOOL_PEN) continue;
                    if (event.eventType == ACTION_UP || event.eventType == ACTION_LEAVE) {
                        inkPathActive = false;
                        continue;
                    }
                    if (!directInkEnabled) continue;
                    if (event.eventType != ACTION_DOWN && event.eventType != ACTION_MOVE) {
                        continue;
                    }
                    if (event.eventType == ACTION_DOWN) {
                        Rect[] rects = writableRects;
                        lockedWritableRect = findWritableRect(event.x, event.y);
                        strokeWritable = rects == null || lockedWritableRect != null;
                        inkPathActive = false;
                        Log.i(TAG, "Worker down " + event.x + "," + event.y
                                + ": writable=" + strokeWritable + ", rect=" + lockedWritableRect
                                + ", suspended=" + normalCommitSuspended);
                    }
                    if (!strokeWritable || (lockedWritableRect != null
                            && !lockedWritableRect.contains(event.x, event.y))) {
                        // KOReader drops these points; do not preview them.
                        inkPathActive = false;
                        strokeWritable = false;
                        continue;
                    }
                    if (event.eventType == ACTION_DOWN || !inkPathActive) {
                        // A zero-length round-capped segment renders a dot.
                        inkPath.moveTo(event.x, event.y);
                        inkPath.lineTo(event.x, event.y);
                        pathHasSegments = true;
                        addInkDirty(event.x - pad, event.y - pad,
                                event.x + pad + 1, event.y + pad + 1);
                    } else {
                        inkPath.lineTo(event.x, event.y);
                        pathHasSegments = true;
                        addInkDirty(Math.min(inkLastX, event.x) - pad,
                                Math.min(inkLastY, event.y) - pad,
                                Math.max(inkLastX, event.x) + pad + 1,
                                Math.max(inkLastY, event.y) + pad + 1);
                    }
                    inkPathActive = true;
                    inkLastX = event.x;
                    inkLastY = event.y;
                }
                if (pathHasSegments) {
                    inkCanvas.save();
                    inkCanvas.setMatrix(phyMatrix);
                    inkCanvas.drawPath(inkPath, inkPaint);
                    inkCanvas.restore();
                }
                inkPath.reset();
                flushInkDirtyLocked();
            } catch (Throwable error) {
                directInkEnabled = false;
                directInkAvailable = false;
                inkPathActive = false;
                restoreNormalCommitLocked();
                Log.e(TAG, "Bigme OEM Canvas draw failed; KOReader will use its renderer",
                        unwrap(error));
                return;
            }
        }
        long nowNs = System.nanoTime();
        long renderNs = nowNs - renderStartNs;
        if ((maxQueueAgeNs > TimeUnit.MILLISECONDS.toNanos(40)
                || renderNs > TimeUnit.MILLISECONDS.toNanos(20))
                && nowNs - lastDirectInkSlowWarningNs > TimeUnit.SECONDS.toNanos(2)) {
            lastDirectInkSlowWarningNs = nowNs;
            Log.w(TAG, "Direct ink worker delay="
                    + TimeUnit.NANOSECONDS.toMillis(maxQueueAgeNs)
                    + "ms, render/inValidate="
                    + TimeUnit.NANOSECONDS.toMillis(renderNs)
                    + "ms, batch=" + batch.size());
        }
    }

    private void addInkDirty(int left, int top, int right, int bottom) {
        left = Math.max(0, left);
        top = Math.max(0, top);
        right = Math.min(width, right);
        bottom = Math.min(height, bottom);
        if (right <= left || bottom <= top) return;
        if (inkDirty.isEmpty()) inkDirty.set(left, top, right, bottom);
        else inkDirty.union(left, top, right, bottom);
    }

    private void flushInkDirtyLocked() throws Exception {
        if (inkDirty.isEmpty() || client == null || invalidateMethod == null) return;
        Rect update = new Rect(inkDirty);
        inkDirty.setEmpty();
        if (inkDrawnBounds.isEmpty()) inkDrawnBounds.set(update);
        else inkDrawnBounds.union(update);
        if (!normalCommitSuspended && normalCommitMethod != null) {
            // HandwritingManager.inValidateContent(): suspend normal commits
            // before every handwriting-channel commit. With the overlay they
            // stay off permanently (see startOnMainThread).
            Log.i(TAG, "Ink start, first rect=" + update);
            if (overlayView == null) normalCommitMethod.invoke(client, false);
            normalCommitSuspended = true;
        }
        invalidateMethod.invoke(client, update, MODE_HANDWRITE);
        lastInkCommitMs = android.os.SystemClock.uptimeMillis();
    }

    private void registerLifecycle(final Activity activity) {
        if (lifecycleCallbacks != null) return;
        boundActivity = activity;
        appForeground = true;
        lifecycleCallbacks = new Application.ActivityLifecycleCallbacks() {
            @Override
            public void onActivityResumed(Activity a) {
                if (a == boundActivity) setForeground(true);
            }

            @Override
            public void onActivityPaused(Activity a) {
                if (a == boundActivity) setForeground(false);
            }

            @Override
            public void onActivityCreated(Activity a, Bundle state) {
            }

            @Override
            public void onActivityStarted(Activity a) {
            }

            @Override
            public void onActivityStopped(Activity a) {
            }

            @Override
            public void onActivitySaveInstanceState(Activity a, Bundle state) {
            }

            @Override
            public void onActivityDestroyed(Activity a) {
            }
        };
        activity.getApplication().registerActivityLifecycleCallbacks(lifecycleCallbacks);
    }

    private void unregisterLifecycle() {
        if (lifecycleCallbacks != null && boundActivity != null) {
            boundActivity.getApplication()
                    .unregisterActivityLifecycleCallbacks(lifecycleCallbacks);
        }
        lifecycleCallbacks = null;
        boundActivity = null;
        appForeground = true;
    }

    /**
     * Stop accepting pen input while KOReader is in the background. Pending
     * events are dropped and a synthetic LEAVE closes any stroke or eraser
     * contact Lua still holds open, so nothing drawn in another app is
     * replayed into the document on resume.
     */
    private synchronized void setForeground(boolean foreground) {
        if (appForeground == foreground) return;
        appForeground = foreground;
        Log.i(TAG, "KOReader " + (foreground ? "resumed" : "paused")
                + "; pen input " + (foreground ? "enabled" : "disabled"));
        if (!foreground) {
            events.clear();
            synchronized (directInkLock) {
                directInkEvents.clear();
            }
            if (client != null) {
                events.addLast(new PenEvent(ACTION_LEAVE, 0, 0, 0, TOOL_PEN, 0L,
                        System.nanoTime()));
            }
            forceCommitNormal();
        }
        if (client != null) {
            callOptional("setInputEnabled", new Class<?>[] { boolean.class }, foreground);
        }
    }

    public boolean isDirectInkAvailable() {
        return directInkAvailable;
    }

    private static Throwable unwrap(Throwable error) {
        Throwable current = error;
        while (current instanceof InvocationTargetException
                && ((InvocationTargetException) current).getCause() != null) {
            current = ((InvocationTargetException) current).getCause();
        }
        return current;
    }

    private synchronized void enqueue(
            int eventType, int x, int y, int pressure, int toolType, long eventTimeNs) {
        if (client == null || !appForeground) return;
        if (eventType == 1 && loggedToolTypes.add(toolType)) {
            Log.i(TAG, "Bigme pen tool detected: toolType=" + toolType
                    + " (vendor documents PEN=0, RUBBER=1, FINGER=2)");
        }
        long queuedAtNs = System.nanoTime();
        PenEvent queuedEvent = new PenEvent(eventType, x, y, pressure, toolType,
                eventTimeNs, queuedAtNs);
        if (toolType == TOOL_PEN && directInkEnabled) {
            enqueueDirectInkEvent(queuedEvent);
        } else if (toolType == TOOL_ERASER && eventType == ACTION_DOWN) {
            // Ends any open preview path and restores normal commits so the
            // eraser's KOReader repaint is visible.
            enqueueDirectInkEvent(queuedEvent);
        }
        if (events.size() >= MAX_QUEUED_EVENTS) {
            events.removeFirst();
        }
        events.addLast(queuedEvent);
    }

    private final class InputHandler implements InvocationHandler {
        @Override
        public Object invoke(Object proxy, Method method, Object[] args) {
            if ("onInputTouch".equals(method.getName()) && args != null && args.length >= 5) {
                int eventType = asInt(args[0]);
                int x = asInt(args[1]);
                int y = asInt(args[2]);
                int pressure = asInt(args[3]);
                int toolType = asInt(args[4]);
                long eventTimeNs = args.length >= 6 ? asLong(args[5]) : 0L;
                enqueue(eventType, x, y, pressure, toolType, eventTimeNs);
                return 0;
            }
            if ("toString".equals(method.getName())) return "KOReaderBigmeInputListener";
            if ("hashCode".equals(method.getName())) return System.identityHashCode(proxy);
            if ("equals".equals(method.getName())) {
                return args != null && args.length > 0 && args[0] == proxy;
            }
            return null;
        }
    }

    private static int asInt(Object value) {
        return value instanceof Number ? ((Number) value).intValue() : 0;
    }

    private static long asLong(Object value) {
        return value instanceof Number ? ((Number) value).longValue() : 0L;
    }

    private static final class PenEvent {
        final int eventType;
        final int x;
        final int y;
        final int pressure;
        final int toolType;
        final long eventTimeNs;
        final long queuedAtNs;

        PenEvent(int eventType, int x, int y, int pressure, int toolType,
                long eventTimeNs, long queuedAtNs) {
            this.eventType = eventType;
            this.x = x;
            this.y = y;
            this.pressure = pressure;
            this.toolType = toolType;
            this.eventTimeNs = eventTimeNs;
            this.queuedAtNs = queuedAtNs;
        }

        String encode() {
            return eventType + "," + x + "," + y + "," + pressure + ","
                    + toolType + "," + eventTimeNs;
        }
    }

    /** Return a batch of events separated by semicolons. */
    public synchronized String drain() {
        if (events.isEmpty()) return "";
        StringBuilder batch = new StringBuilder();
        int count = 0;
        long nowNs = System.nanoTime();
        long maxQueueAgeNs = 0;
        int eraserEvents = 0;
        boolean eraserDown = false;
        String firstEraser = null;
        String lastEraser = null;
        while (!events.isEmpty() && count++ < 512) {
            if (batch.length() > 0) batch.append(';');
            PenEvent event = events.removeFirst();
            batch.append(event.encode());
            maxQueueAgeNs = Math.max(maxQueueAgeNs, nowNs - event.queuedAtNs);
            if (event.toolType == 1) {
                eraserEvents++;
                if (event.eventType == 1) eraserDown = true;
                String location = event.eventType + "@" + event.x + "," + event.y;
                if (firstEraser == null) firstEraser = location;
                lastEraser = location;
            }
        }
        if (maxQueueAgeNs > TimeUnit.MILLISECONDS.toNanos(60)
                && nowNs - lastQueueWarningNs > TimeUnit.SECONDS.toNanos(2)) {
            lastQueueWarningNs = nowNs;
            Log.w(TAG, "Input queue delay=" + TimeUnit.NANOSECONDS.toMillis(maxQueueAgeNs)
                    + "ms, batch=" + count);
        }
        if (eraserEvents > 0 && (eraserDown
                || nowNs - lastEraserLogNs > TimeUnit.SECONDS.toNanos(1))) {
            lastEraserLogNs = nowNs;
            Log.i(TAG, "Eraser batch events=" + eraserEvents + " first=" + firstEraser
                    + " last=" + lastEraser);
        }
        return batch.toString();
    }

    public void close() {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            closeOnMainThread();
            return;
        }
        FutureTask<Void> task = new FutureTask<>(new Callable<Void>() {
            @Override
            public Void call() {
                closeOnMainThread();
                return null;
            }
        });
        if (!MAIN_HANDLER.post(task)) {
            Log.w(TAG, "Could not schedule Bigme cleanup on Android UI thread");
            return;
        }
        try {
            task.get(3, TimeUnit.SECONDS);
        } catch (Throwable error) {
            task.cancel(true);
            Log.w(TAG, "Timed out cleaning up Bigme input on UI thread", error);
        }
    }

    private synchronized void closeOnMainThread() {
        unregisterLifecycle();
        events.clear();
        loggedToolTypes.clear();
        releaseClient();
        Log.i(TAG, "Bigme input disconnected");
    }

    private void releaseClient() {
        stopDirectInkWorker();
        Object current;
        Class<?> currentClass;
        Class<?> currentListenerClass;
        Object currentListener;
        synchronized (renderLock) {
            // Never leave KOReader's surface frozen, and drop the service
            // canvas before disconnecting so a late worker cannot touch it.
            restoreNormalCommitLocked();
            directInkAvailable = false;
            inkCanvas = null;
            inkPaint = null;
            inkDirty.setEmpty();
            inkPath.reset();
            inkPathActive = false;
            invalidateMethod = null;
            normalCommitMethod = null;
            mirrorActive = false;
            screenBuffer = null;
            current = client;
            currentClass = clientClass;
            currentListenerClass = listenerClass;
            currentListener = listener;
            client = null;
            clientClass = null;
            listenerClass = null;
            listener = null;
            if (current != null && currentClass != null) {
                invokeQuietly(currentClass, current, "setInputEnabled",
                        new Class<?>[] { boolean.class }, false);
                if (currentListenerClass != null && currentListener != null) {
                    invokeQuietly(currentClass, current, "unRegisterInputListener",
                            new Class<?>[] { currentListenerClass }, currentListener);
                }
                invokeQuietly(currentClass, current, "disconnect", new Class<?>[0]);
                invokeQuietly(currentClass, current, "unBindView", new Class<?>[0]);
            }
        }
        boundView = null;
        View overlay = overlayView;
        overlayView = null;
        overlaySurfaceValid = false;
        if (Looper.myLooper() == Looper.getMainLooper()) removeOverlay(overlay);
        else removeOverlayAsync(overlay);
    }

    private static void invokeQuietly(
            Class<?> type, Object target, String name, Class<?>[] parameterTypes,
            Object... arguments) {
        try {
            type.getMethod(name, parameterTypes).invoke(target, arguments);
        } catch (Throwable ignored) {
        }
    }
}
