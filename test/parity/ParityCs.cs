// Parity test, C# side: the same numbers as parity_c.c, computed by the Unity ports.
using System;
using System.Globalization;
using Maba3;

static class Parity
{
    static string F(float v) { return v.ToString("0.000000", CultureInfo.InvariantCulture); }
    static void Main()
    {
        var o = Console.Out;
        for (int r = MabaController.RungFloor; r <= MabaController.RungCeil; r++)
            o.Write("rung " + r + " pct " + MabaController.RungPercent(r) + " scale " + F(MabaController.RungScale(r)) + " quality " + (MabaController.RungQuality(r) ? 1 : 0) + "\n");
        for (int m = 0; m < 5; m++) o.Write("moderung " + m + " " + MabaController.ModeRung(m) + "\n");
        for (int i = 1; i <= 16; i++) o.Write("halton " + i + " " + F(MabaTemporal.Halton(i, 2)) + " " + F(MabaTemporal.Halton(i, 3)) + "\n");
        var u = new MabaController(MabaController.ModeDynamic, 60f);
        uint x = 12345u;
        for (int f = 0; f < 6000; f++)
        {
            x = unchecked(x * 1664525u + 1013904223u);
            float ms = 8.0f + (float)((x >> 16) & 0xFFFu) / 4096.0f * 20.0f + (float)((f / 500) % 3) * 6.0f;
            u.UpdateDynamic(ms);
            o.Write("dyn " + f + " " + u.Rung + "\n");
        }
    }
}