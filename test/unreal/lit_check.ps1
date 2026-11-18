# Scores the frames of lit_capture.py (a lit engine template map). Prints one line per check and returns an object with the numbers.
#   -Shots <folder>
# Checks (thresholds sit between the broken Frame Generation of 2026-11-17 and the fixed one):
#   brightness  every displayed frame of fg2x / fg3x within 4 of 255 of the plain MABA frames (the broken one pulsed 101 - 149 against 155)
#   still       consecutive displayed frames of fg2x / fg3x at least 38 dB apart (broken 26 dB; fixed 42 - 43 dB; plain MABA 52 dB)
#   native      plain MABA at least 33 dB against the engine's own 100% frame (measured 36.5 dB)
param([Parameter(Mandatory = $true)][string]$Shots)
if (-not ('MabaLit' -as [type])) {
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System; using System.Drawing; using System.Drawing.Imaging; using System.Runtime.InteropServices;
public static class MabaLit {
  static byte[] Load(string p, out int w, out int h) {
    using (var bmp = new Bitmap(p)) { w = bmp.Width; h = bmp.Height;
      var d = bmp.LockBits(new Rectangle(0,0,w,h), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
      var buf = new byte[d.Stride * h]; Marshal.Copy(d.Scan0, buf, 0, buf.Length); bmp.UnlockBits(d); return buf; } }
  public static double Psnr(string a, string b, int crop) {
    int w1, h1, w2, h2; var A = Load(a, out w1, out h1); var B = Load(b, out w2, out h2); if (w1 != w2 || h1 != h2) return -1;
    int stride = ((w1 * 3 + 3) / 4) * 4; double sum = 0; long n = 0;
    for (int y = crop; y < h1 - crop; y++) for (int x = crop * 3; x < (w1 - crop) * 3; x++) { double d = A[y*stride+x] - B[y*stride+x]; sum += d*d; n++; }
    double mse = sum / n; return mse < 1e-9 ? 99.0 : 10.0 * Math.Log10(255.0*255.0/mse); }
  public static double Mean(string p) { using (var b = new Bitmap(p)) { double s = 0; int n = 0; for (int y = 0; y < b.Height; y += 2) for (int x = 0; x < b.Width; x += 2) { var c = b.GetPixel(x, y); s += (c.R + c.G + c.B) / 3.0; n++; } return s / n; } } }
"@
}
function Frames($phase) { @(Get-ChildItem $Shots -Filter "${phase}_*.png" | Sort-Object Name) }
$res = [ordered]@{}
$mabaLum = (Frames 'maba' | ForEach-Object { [MabaLit]::Mean($_.FullName) } | Measure-Object -Average).Average
foreach ($ph in 'fg2x', 'fg3x') {
    $f = Frames $ph
    if ($f.Count -lt 4) { $res["${ph}_frames"] = 0; continue }
    $lum = $f | ForEach-Object { [MabaLit]::Mean($_.FullName) }
    $res["${ph}_brightness_dev"] = [Math]::Round((($lum | ForEach-Object { [Math]::Abs($_ - $mabaLum) } | Measure-Object -Maximum).Maximum), 2)
    $p = @(); for ($i = 1; $i -lt $f.Count; $i++) { $p += [MabaLit]::Psnr($f[$i - 1].FullName, $f[$i].FullName, 8) }
    $res["${ph}_still_db"] = [Math]::Round(($p | Measure-Object -Average).Average, 2)
}
$ref = (Frames 'engine' | Select-Object -Last 1).FullName
$res["maba_vs_native_db"] = [Math]::Round(((Frames 'maba' | ForEach-Object { [MabaLit]::Psnr($_.FullName, $ref, 8) } | Measure-Object -Average).Average), 2)
[pscustomobject]$res