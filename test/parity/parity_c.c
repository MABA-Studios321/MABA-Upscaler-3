/* Parity test, C side: prints what the C headers compute so the C# ports (Unity) can be compared line by line. */
#include <stdio.h>
#include "../../src/maba_upscaler.h"
#include "../../src/maba_temporal.h"

int main(void)
{
    int r;
    for (r = MABA_RUNG_FLOOR; r <= MABA_RUNG_CEIL; r++)
        printf("rung %d pct %d scale %.6f quality %d\n", r, MabaRungPercent(r), MabaRungScale(r), MabaRungQuality(r));
    {
        int m;
        for (m = 0; m < 5; m++) printf("moderung %d %d\n", m, MabaModeRung((MabaMode)m));
    }
    {
        int i;
        for (i = 1; i <= 16; i++) printf("halton %d %.6f %.6f\n", i, MabaHalton(i, 2), MabaHalton(i, 3));
    }
    {
        MabaUpscaler u;
        unsigned int x = 12345u;
        int f;
        MabaInit(&u, MABA_MODE_DYNAMIC, 60.0f);
        for (f = 0; f < 6000; f++)
        {
            float ms;
            x = x * 1664525u + 1013904223u;
            ms = 8.0f + (float)((x >> 16) & 0xFFFu) / 4096.0f * 20.0f + (float)((f / 500) % 3) * 6.0f;
            MabaUpdateDynamic(&u, ms);
            printf("dyn %d %d\n", f, u.rung);
        }
    }
    return 0;
}