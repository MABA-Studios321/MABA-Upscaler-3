/* Host test for the Frame Gen governor and the shown-kind counters (maba_framegen.h). */
#include <stdio.h>
#include <string.h>
#include "../../src/maba_framegen.h"

static int failures;
#define CHECK(c, what) do { if (!(c)) { printf("FAIL  %s\n", what); failures++; } } while (0)

/* Run the governor against a simple device: a real frame costs R ms, a generated frame G ms, the
   panel is panelHz. Returns the final wantOn after `frames` real frames. */
static int simulate(float R, float G, float panelHz, int frames, int* onFrames)
{
    MabaFgGovernor v;
    MabaFgGovInit(&v, panelHz);
    int want = v.wantOn;
    *onFrames = 0;
    for (int i = 0; i < frames; i++)
    {
        float interval = want ? R + G : R;
        if (interval < 1000.0f / panelHz) interval = 1000.0f / panelHz;      /* the panel paces it */
        want = MabaFgGovStep(&v, interval);
        if (want) (*onFrames)++;
    }
    return want;
}

int main(void)
{
    int on;
    /* Cheap frames, panel already full without Frame Gen: it must switch itself off. */
    CHECK(simulate(10.0f, 3.0f, 60.0f, 3000, &on) == 0, "full panel -> Frame Gen off");
    /* Heavy real frame, cheap generated frame: clearly worth it. */
    CHECK(simulate(30.0f, 6.0f, 60.0f, 3000, &on) == 1, "heavy frames, cheap generated -> on");
    /* Generated frame as dear as the real one: two frames per 2R is no gain (1.0 < 1.05). */
    CHECK(simulate(25.0f, 25.0f, 60.0f, 3000, &on) == 0, "generated as dear as real -> off");
    /* Generated frame dearer than real: a loss, off. */
    CHECK(simulate(20.0f, 45.0f, 60.0f, 3000, &on) == 0, "generated dearer than real -> off");
    /* Marginal gain (5%) kept off, real gain kept on. */
    CHECK(simulate(33.0f, 17.0f, 60.0f, 3000, &on) == 1, "30 -> 40 fps shown -> on");

    /* A scene that gets heavier later: the periodic probe must turn it on. */
    {
        MabaFgGovernor v; float R = 10.0f, G = 3.0f; int want;
        MabaFgGovInit(&v, 60.0f);
        want = v.wantOn;
        for (int i = 0; i < 2000; i++)
        {
            float iv = want ? R + G : R; if (iv < 16.7f) iv = 16.7f;
            want = MabaFgGovStep(&v, iv);
        }
        CHECK(want == 0, "light scene starts off");
        R = 32.0f;
        for (int i = 0; i < 4000; i++)
        {
            float iv = want ? R + G : R; if (iv < 16.7f) iv = 16.7f;
            want = MabaFgGovStep(&v, iv);
        }
        CHECK(want == 1, "scene gets heavier -> the probe turns Frame Gen on");
    }

    /* Counters follow the kind of frame that was presented: one real, then one generated, at 8 ms each. */
    {
        MabaFrameGen g; double t = 0.0; int rolled = 0;
        MabaFgInit(&g); MabaFgSetEnabled(&g, 1);
        MabaFgPresented(&g, MABA_FG_REAL, t);               /* first frame: starts the window */
        for (int i = 0; i < 300; i++)
        {
            t += 8.0;
            MabaFgSlot slot = MabaFgNextSlot(&g);
            rolled |= MabaFgPresented(&g, slot, t);
        }
        CHECK(rolled && g.statsValid, "a window completed");
        CHECK(g.realFps > 50.0f && g.realFps < 75.0f, "real fps counts the real frames");
        CHECK(g.generatedFps > 50.0f && g.generatedFps < 75.0f, "generated fps counts the generated frames");
        CHECK(g.displayedFps > 110.0f && g.displayedFps < 130.0f, "displayed = real + generated");
    }    if (failures == 0) printf("ALL FRAMEGEN GOVERNOR TESTS PASSED\n");
    return failures != 0;
}
