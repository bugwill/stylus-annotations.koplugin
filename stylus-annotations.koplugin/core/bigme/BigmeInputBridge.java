package org.koreader.bigme;

import android.app.Activity;
import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.View;

import org.lsposed.hiddenapibypass.HiddenApiBypass;

import java.lang.reflect.InvocationHandler;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.util.ArrayDeque;
import java.util.Deque;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.Callable;
import java.util.concurrent.FutureTask;
import java.util.concurrent.TimeUnit;

/**
 * Reflective adapter for Bigme's system handwriting service.
 *
 * Keep com.xrz classes out of the DEX type table: some Bigme firmware exposes
 * HandwrittenClient from the boot class path but direct bytecode references to
 * it fail to link from a regular application. Reflection matches the vendor
 * access pattern used by the inksdk project.
 */
public final class BigmeInputBridge {
    private static final String TAG = "KOReaderBigmeInput";
    private static final String CLIENT_NAME = "com.xrz.HandwrittenClient";
    private static final String LISTENER_NAME = CLIENT_NAME + "$InputListener";
    private static final int MAX_QUEUED_EVENTS = 4096;
    private static final Handler MAIN_HANDLER = new Handler(Looper.getMainLooper());

    private final Deque<PenEvent> events = new ArrayDeque<>();
    private final Set<Integer> loggedToolTypes = new HashSet<>();
    private long coalescedMoveCount;
    private long lastQueueWarningNs;
    private long lastEraserLogNs;
    private Object client;
    private Class<?> clientClass;
    private Class<?> listenerClass;
    private Object listener;
    private View boundView;
    private int width;
    private int height;

    public BigmeInputBridge() {
    }

    public String start(final Context context) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            return startOnMainThread(context);
        }
        FutureTask<String> task = new FutureTask<>(new Callable<String>() {
            @Override
            public String call() {
                return startOnMainThread(context);
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

    private synchronized String startOnMainThread(Context context) {
        if (client != null) {
            return "OK," + width + "," + height;
        }
        if (!(context instanceof Activity)) {
            return "ERROR,KOReader context is not an Activity";
        }

        try {
            Activity activity = (Activity) context;
            boundView = activity.getWindow().getDecorView();
            width = boundView.getWidth();
            height = boundView.getHeight();
            if (width <= 0 || height <= 0) {
                boundView = null;
                return "ERROR,KOReader view has no size yet";
            }

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

            // These options are firmware-specific; the core listener/connect
            // path remains usable if a particular firmware omits one of them.
            callOptional("setUseRawInputEvent", new Class<?>[] { boolean.class }, false);
            callOptional("setNormalCommitEnable", new Class<?>[] { boolean.class }, true);
            callOptional("updateLayout", new Class<?>[0]);

            Object connected = call("connect",
                    new Class<?>[] { int.class, int.class }, width, height);
            if (!(connected instanceof Boolean) || !((Boolean) connected)) {
                releaseClient();
                return "ERROR,Bigme handwriting client did not connect";
            }

            call("registerInputListener", new Class<?>[] { listenerClass }, listener);
            callOptional("setAutoCleanControlEnabled", new Class<?>[] { boolean.class }, false);
            callOptional("setRecommitEnabled",
                    new Class<?>[] { boolean.class, int.class, int.class }, false, 0, 0);
            callOptional("setPredictEnabled", new Class<?>[] { boolean.class }, false);
            callOptional("setOverlayEnabled", new Class<?>[] { boolean.class }, false);
            callOptional("setBlendEnabled", new Class<?>[] { boolean.class }, false);
            call("setInputEnabled", new Class<?>[] { boolean.class }, true);

            Object version = callOptional("getVersion", new Class<?>[0]);
            Log.i(TAG, "Bigme input connected; view=" + width + "x" + height
                    + ", service=" + version);
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
        if (client == null) return;
        if (eventType == 1 && loggedToolTypes.add(toolType)) {
            Log.i(TAG, "Bigme pen tool detected: toolType=" + toolType
                    + " (vendor documents PEN=0, RUBBER=1, FINGER=2)");
        }
        long queuedAtNs = System.nanoTime();
        // If KOReader's UI thread falls behind, keep the newest location for a
        // tool's pending MOVE instead of making the pen replay stale points.
        // DOWN/UP/LEAVE are always retained so pointer state remains balanced.
        if (eventType == 2 && !events.isEmpty()) {
            PenEvent last = events.peekLast();
            if (last != null && last.eventType == 2 && last.toolType == toolType) {
                events.removeLast();
                coalescedMoveCount++;
            }
        }
        if (events.size() >= MAX_QUEUED_EVENTS) {
            events.removeFirst();
        }
        events.addLast(new PenEvent(eventType, x, y, pressure, toolType,
                eventTimeNs, queuedAtNs));
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
        if (maxQueueAgeNs > TimeUnit.MILLISECONDS.toNanos(40)
                && nowNs - lastQueueWarningNs > TimeUnit.SECONDS.toNanos(2)) {
            lastQueueWarningNs = nowNs;
            Log.w(TAG, "Input queue delay=" + TimeUnit.NANOSECONDS.toMillis(maxQueueAgeNs)
                    + "ms, batch=" + count + ", coalesced moves=" + coalescedMoveCount);
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
        events.clear();
        loggedToolTypes.clear();
        releaseClient();
        Log.i(TAG, "Bigme input disconnected");
    }

    private void releaseClient() {
        Object current = client;
        Class<?> currentClass = clientClass;
        Class<?> currentListenerClass = listenerClass;
        Object currentListener = listener;
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
        boundView = null;
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
