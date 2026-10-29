import android.os.SystemClock;
import android.view.InputDevice;
import android.view.InputEvent;
import android.view.MotionEvent;
import java.lang.reflect.Method;

/** Shell-only integration fixture. No app permission or installation is added. */
public final class NextendTouchInput {
    private static Object manager;
    private static Method inject;
    private static long downTime;
    private static void send(int action, float[][] points) throws Exception {
        MotionEvent.PointerProperties[] props = new MotionEvent.PointerProperties[points.length];
        MotionEvent.PointerCoords[] coords = new MotionEvent.PointerCoords[points.length];
        for (int i = 0; i < points.length; i++) {
            props[i] = new MotionEvent.PointerProperties(); props[i].id = 7 + 5 * i;
            props[i].toolType = MotionEvent.TOOL_TYPE_FINGER;
            coords[i] = new MotionEvent.PointerCoords();
            coords[i].x = points[i][0]; coords[i].y = points[i][1];
            coords[i].pressure = 1f; coords[i].size = .1f;
        }
        MotionEvent event = MotionEvent.obtain(downTime, SystemClock.uptimeMillis(), action, points.length,
            props, coords, 0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0);
        try {
            if (!(Boolean) inject.invoke(manager, event, 2)) throw new IllegalStateException("input injection rejected");
        } finally { event.recycle(); }
    }
    public static void main(String[] args) throws Exception {
        if (args.length != 3) throw new IllegalArgumentException("pattern width height");
        String pattern = args[0]; float w = Float.parseFloat(args[1]), h = Float.parseFloat(args[2]);
        if (!(pattern.equals("scroll") || pattern.equals("pinch-in") || pattern.equals("pinch-out") ||
              pattern.equals("rightclick") || pattern.equals("final-pinch") || pattern.equals("cancel")))
            throw new IllegalArgumentException("unknown pattern");
        Class<?> cls = Class.forName("android.hardware.input.InputManagerGlobal");
        manager = cls.getMethod("getInstance").invoke(null);
        inject = cls.getMethod("injectInputEvent", InputEvent.class, int.class);
        float startSpan = pattern.equals("pinch-out") ? .30f : .12f;
        float y = h * .40f;
        float[][] points = {{w * (.5f - startSpan / 2), y}, {w * (.5f + startSpan / 2), y}};
        downTime = SystemClock.uptimeMillis();
        send(MotionEvent.ACTION_DOWN, new float[][]{points[0]}); SystemClock.sleep(30);
        send(MotionEvent.ACTION_POINTER_DOWN | (1 << MotionEvent.ACTION_POINTER_INDEX_SHIFT), points);
        try {
            if (pattern.equals("final-pinch")) {
                points[0][0] = w * .30f; points[1][0] = w * .70f; SystemClock.sleep(40);
            } else if (!pattern.equals("rightclick")) {
                for (int step = 1; step <= 20; step++) {
                    float t = step / 20f;
                    if (pattern.equals("pinch-in") || pattern.equals("pinch-out")) {
                        float endSpan = pattern.equals("pinch-in") ? .38f : .10f;
                        float span = startSpan + (endSpan - startSpan) * t;
                        points[0][0] = w * (.5f - span / 2); points[1][0] = w * (.5f + span / 2);
                    } else { points[0][1] = y + h * .15f * t; points[1][1] = points[0][1]; }
                    SystemClock.sleep(25); send(MotionEvent.ACTION_MOVE, points);
                }
            } else { SystemClock.sleep(40); }
            if (pattern.equals("cancel")) send(MotionEvent.ACTION_CANCEL, points);
            else {
                send(MotionEvent.ACTION_POINTER_UP | (1 << MotionEvent.ACTION_POINTER_INDEX_SHIFT), points);
                send(MotionEvent.ACTION_UP, new float[][]{points[0]});
            }
        } catch (Exception error) {
            send(MotionEvent.ACTION_CANCEL, points); throw error;
        }
        System.out.println("injected " + pattern);
    }
}
