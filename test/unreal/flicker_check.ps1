# Compares consecutive displayed frames of flicker_capture.py (still_NNN_kind.png / move_NNN_kind.png).
# For each phase prints the PSNR between every frame and the next one, split by real->generated and generated->real, and the mean brightness.
# A still camera should give ~99 dB (identical frames); constant motion should give similar dB for both transitions.
param([Parameter(Mandatory = $true)][string]$Shots, [int]$Crop = 8)
if (-not ('MabaFl' -as [type])) {
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System; using System.Drawing; using System.Drawing.Imaging; using System.Runtime.InteropServices;
public static class MabaFl {
  static byte[] Load(string p, out int w, out int h) {
    using (var bmp = new Bitmap(p)) {
      w = bmp.Width; h = bmp.Height;
      var d = bmp.LockBits(new Rectangle(0,0,w,h), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
      var buf = new byte[d.Stride * h]; Marshal.Copy(d.Scan0, buf, 0, buf.Length); bmp.UnlockBits(d); return buf;
    }
  }
  public static double Psnr(string a, string b, int crop) {
    int w1, h1, w2, h2; var A = Load(a, out w1, out h1); var B = Load(b, out w2, out h2);
    if (w1 != w2 || h1 != h2) return -1;
    int stride = ((w1 * 3 + 3) / 4) * 4; double sum = 0; long n = 0;
    for (int y = crop; y < h1 - crop; y++) for (int x = crop * 3; x < (w1 - crop) * 3; x++) { double d = A[y*stride+x] - B[y*stride+x]; sum += d*d; n++; }
    double mse = sum / n; return mse < 1e-9 ? 99.0 : 10.0 * Math.Log10(255.0*255.0/mse);
  }
  public static double Mean(string a) {
    int w, h; var A = Load(a, out w, out h); int stride = ((w * 3 + 3) / 4) * 4; double s = 0; long n = 0;
    for (int y = 0; y < h; y++) for (int x = 0; x < w * 3; x++) { s += A[y*stride+x]; n++; }
    return s / n;
  }
}
"@
}
$result = @()
foreach ($phase in 'still', 'move') {
    $files = @(Get-ChildItem $Shots -Filter "${phase}_*.png" | Sort-Object Name)
    if ($files.Count -lt 4) { Write-Host "${phase}: only $($files.Count) frames"; continue }
    $toGen = @(); $toReal = @(); $lum = @()
    for ($i = 0; $i -lt $files.Count; $i++) {
        $lum += [MabaFl]::Mean($files[$i].FullName)
        if ($i -ge 1 -and $i -lt $files.Count) {
            $p = [MabaFl]::Psnr($files[$i - 1].FullName, $files[$i].FullName, $Crop)
            if ($files[$i].BaseName -match '_gen$') { $toGen += $p } else { $toReal += $p }
        }
    }
    $kinds = ($files | ForEach-Object { if ($_.BaseName -match '_gen$') { 'G' } else { 'R' } }) -join ''
    $lumRange = ($lum | Measure-Object -Maximum -Minimum)
    $o = [pscustomobject]@{
        Phase = $phase; Frames = $files.Count; Pattern = $kinds
        ToGenerated_dB = [Math]::Round(($toGen | Measure-Object -Average).Average, 2)
        ToReal_dB = [Math]::Round(($toReal | Measure-Object -Average).Average, 2)
        MinStep_dB = [Math]::Round((($toGen + $toReal) | Measure-Object -Minimum).Minimum, 2)
        LumaSpread = [Math]::Round($lumRange.Maximum - $lumRange.Minimum, 3)
    }
    $result += $o
}
$result | Format-List | Out-String | Write-Host
$result