# Compares the Frame Generation captures of the Unreal test: a generated frame vs a true (Frame Generation off) render of the same
# camera pose, and vs repeating the previous real frame. Usage: powershell -File psnr_fg.ps1 -Shots <folder>
param([Parameter(Mandatory = $true)][string]$Shots, [int]$Crop = 8)
if (-not ('MabaPsnr' -as [type])) {
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System; using System.Drawing; using System.Drawing.Imaging; using System.Runtime.InteropServices;
public static class MabaPsnr {
  static byte[] Load(string p, out int w, out int h) {
    using (var bmp = new Bitmap(p)) {
      w = bmp.Width; h = bmp.Height;
      var d = bmp.LockBits(new Rectangle(0,0,w,h), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
      var buf = new byte[d.Stride * h]; Marshal.Copy(d.Scan0, buf, 0, buf.Length); bmp.UnlockBits(d); return buf;
    }
  }
  public static double Compute(string a, string b, int crop) {
    int w1, h1, w2, h2; var A = Load(a, out w1, out h1); var B = Load(b, out w2, out h2);
    if (w1 != w2 || h1 != h2) return -1;
    int stride = ((w1 * 3 + 3) / 4) * 4; double sum = 0; long n = 0;
    for (int y = crop; y < h1 - crop; y++) for (int x = crop * 3; x < (w1 - crop) * 3; x++) { double d = A[y*stride+x] - B[y*stride+x]; sum += d*d; n++; }
    double mse = sum / n; return mse < 1e-9 ? 99.0 : 10.0 * Math.Log10(255.0*255.0/mse);
  }
}
"@
}
$gens = Get-ChildItem $Shots -Filter 'gen_*.png' | ForEach-Object { [int]($_.BaseName -replace 'gen_','') } | Sort-Object
$rows = @()
foreach ($k in $gens) {
    $truth = Join-Path $Shots "truth_$k.png"; $prev = Join-Path $Shots "real_$($k-1).png"; $gen = Join-Path $Shots "gen_$k.png"
    if ((Test-Path $truth) -and (Test-Path $prev)) {
        $rows += [pscustomobject]@{ tick = $k
            gen_vs_truth = [Math]::Round([MabaPsnr]::Compute($gen, $truth, $Crop), 2)
            repeat_vs_truth = [Math]::Round([MabaPsnr]::Compute($prev, $truth, $Crop), 2) }
    }
}
$rows | Format-Table -AutoSize | Out-String | Write-Host
if ($rows.Count) {
    $gen = ($rows | Measure-Object gen_vs_truth -Average).Average
    $rep = ($rows | Measure-Object repeat_vs_truth -Average).Average
    Write-Host ("generated {0:N2} dB   repeating the previous real frame {1:N2} dB   ({2} frames)" -f $gen, $rep, $rows.Count)
    [pscustomobject]@{ Gen = $gen; Repeat = $rep; Count = $rows.Count }   # the last object in the output: callers read it
} else {
    Write-Host "no complete frame sets (gen / previous real / truth) found in $Shots"
}