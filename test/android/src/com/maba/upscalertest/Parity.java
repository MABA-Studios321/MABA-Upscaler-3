package com.maba.upscalertest;

/**
 * Host-side parity runner: feeds the same deterministic trace as test_controller.c (trace mode)
 * through the Java controller and prints the identical format, so the outputs can be diffed.
 *
 * Build/run (JDK 11+):
 *   javac -d out src/com/maba/upscalertest/DynController.java src/com/maba/upscalertest/MabaController.java src/com/maba/upscalertest/Parity.java
 *   java -cp out com.maba.upscalertest.Parity > trace_java.txt
 *   diff trace_c.txt trace_java.txt
 */
public final class Parity {
    private static long lcgState = 12345L;

    private static float nextFrameMs(float base, int span) {
        lcgState = lcgState * 6364136223846793005L + 1442695040888963407L;
        int r = (int) (lcgState >>> 33);
        return base + (r % span);
    }

    /** Frame times are base .. base + span - 1 ms; every 500th frame is a 2 s loading hitch. */
    private static void frames(MabaController u, StringBuilder sb, int from, int to, float base, int span) {
        for (int i = from; i < to; i++) {
            float ms = (i % 500 == 499) ? 2000f : nextFrameMs(base, span);
            int rung = u.beginFrame(ms);
            int w = Math.max(2, Math.round(1541 * MabaController.rungScale(rung)));
            int h = Math.max(2, Math.round(720 * MabaController.rungScale(rung)));
            sb.append(i).append(' ').append(rung).append(' ').append(w).append(' ').append(h).append('\n');
        }
    }

    public static void main(String[] args) {
        MabaController u = new MabaController(MabaController.MODE_DYNAMIC, 60f);
        StringBuilder sb = new StringBuilder(1 << 20);
        frames(u, sb, 0, 20000, 8f, 25);         // the whole ladder, 8..32 ms: mostly over budget
        u.setScaleRange(0.50f, 0.77f);           // then the classic range, mid-run
        frames(u, sb, 20000, 25000, 8f, 25);
        u.setScaleRange(0.35f, 1.00f);           // then the whole ladder again, in three load phases:
        frames(u, sb, 25000, 30000, 3f, 17);     //   spare time (3..19 ms): climbs and jumps
        frames(u, sb, 30000, 36000, 14f, 21);    //   load rises (14..34 ms): probes fail, steps down
        frames(u, sb, 36000, 45000, 3f, 17);     //   spare time again: climbs under the back-off
        // bursts: 400 light frames (a jump) then 400 heavy ones, inside the jump's proof window,
        // so failed jumps return to where they started
        for (int k = 0; k < 25; k++)
            frames(u, sb, 45000 + k * 400, 45000 + (k + 1) * 400,
                   (k % 2 == 0) ? 3f : 20f, (k % 2 == 0) ? 17 : 20);
        sb.append("final ").append(u.rung).append(' ').append(u.overFrames).append(' ')
          .append(u.goodFrames).append(' ').append(u.upWait).append(' ')
          .append(u.probing ? 1 : 0).append(' ').append(u.probeFrom).append('\n');
        System.out.print(sb);
    }
}
