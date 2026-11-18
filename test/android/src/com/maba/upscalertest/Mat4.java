package com.maba.upscalertest;

/** Minimal column-major 4x4 matrix math (GL convention). No Android dependencies. */
public final class Mat4 {
    public final float[] m = new float[16];

    public static Mat4 identity() {
        Mat4 r = new Mat4();
        r.m[0] = r.m[5] = r.m[10] = r.m[15] = 1f;
        return r;
    }

    public static Mat4 translate(float x, float y, float z) {
        Mat4 r = identity();
        r.m[12] = x; r.m[13] = y; r.m[14] = z;
        return r;
    }

    // ---- Allocation-free setters, for per-frame work (no garbage on the render thread) ----

    public Mat4 setIdentity() {
        java.util.Arrays.fill(m, 0f);
        m[0] = m[5] = m[10] = m[15] = 1f;
        return this;
    }

    public Mat4 setTranslate(float x, float y, float z) {
        setIdentity();
        m[12] = x; m[13] = y; m[14] = z;
        return this;
    }

    public Mat4 setScale(float s) {
        setIdentity();
        m[0] = m[5] = m[10] = s;
        return this;
    }

    public Mat4 setRotX(float a) {
        setIdentity();
        float c = (float) Math.cos(a), s = (float) Math.sin(a);
        m[5] = c; m[6] = s; m[9] = -s; m[10] = c;
        return this;
    }

    public Mat4 setRotY(float a) {
        setIdentity();
        float c = (float) Math.cos(a), s = (float) Math.sin(a);
        m[0] = c; m[2] = -s; m[8] = s; m[10] = c;
        return this;
    }

    public Mat4 setRotZ(float a) {
        setIdentity();
        float c = (float) Math.cos(a), s = (float) Math.sin(a);
        m[0] = c; m[1] = s; m[4] = -s; m[5] = c;
        return this;
    }

    /** out = a * b. out must not be a or b. */
    public static void mulInto(Mat4 a, Mat4 b, Mat4 out) {
        float[] am = a.m, bm = b.m, r = out.m;
        for (int c = 0; c < 4; c++)
            for (int i = 0; i < 4; i++) {
                r[c * 4 + i] = am[i] * bm[c * 4] + am[4 + i] * bm[c * 4 + 1]
                    + am[8 + i] * bm[c * 4 + 2] + am[12 + i] * bm[c * 4 + 3];
            }
    }

    /** Uniform scale (keeps normals valid with mat3(model) in the vertex shader). */
    public static Mat4 scale(float s) {
        Mat4 r = identity();
        r.m[0] = r.m[5] = r.m[10] = s;
        return r;
    }

    public static Mat4 rotX(float a) {
        Mat4 r = identity();
        float c = (float) Math.cos(a), s = (float) Math.sin(a);
        r.m[5] = c; r.m[6] = s; r.m[9] = -s; r.m[10] = c;
        return r;
    }

    public static Mat4 rotY(float a) {
        Mat4 r = identity();
        float c = (float) Math.cos(a), s = (float) Math.sin(a);
        r.m[0] = c; r.m[2] = -s; r.m[8] = s; r.m[10] = c;
        return r;
    }

    public static Mat4 rotZ(float a) {
        Mat4 r = identity();
        float c = (float) Math.cos(a), s = (float) Math.sin(a);
        r.m[0] = c; r.m[1] = s; r.m[4] = -s; r.m[5] = c;
        return r;
    }

    public static Mat4 perspective(float fovYRad, float aspect, float near, float far) {
        Mat4 r = new Mat4();
        float f = 1f / (float) Math.tan(fovYRad * 0.5);
        r.m[0] = f / aspect;
        r.m[5] = f;
        r.m[10] = (far + near) / (near - far);
        r.m[11] = -1f;
        r.m[14] = 2f * far * near / (near - far);
        return r;
    }

    public static Mat4 lookAt(float ex, float ey, float ez, float cx, float cy, float cz) {
        float zx = ex - cx, zy = ey - cy, zz = ez - cz;
        float zl = (float) Math.sqrt(zx * zx + zy * zy + zz * zz);
        zx /= zl; zy /= zl; zz /= zl;
        // up = (0,1,0); x = normalize(cross(up, z))
        float xx = zz, xy = 0f, xz = -zx;
        float xl = (float) Math.sqrt(xx * xx + xz * xz);
        if (xl < 1e-6f) { xx = 1f; xz = 0f; xl = 1f; }
        xx /= xl; xz /= xl;
        // y = cross(z, x)
        float yx = zy * xz - zz * xy, yy = zz * xx - zx * xz, yz = zx * xy - zy * xx;
        Mat4 r = identity();
        r.m[0] = xx; r.m[4] = xy; r.m[8] = xz;
        r.m[1] = yx; r.m[5] = yy; r.m[9] = yz;
        r.m[2] = zx; r.m[6] = zy; r.m[10] = zz;
        r.m[12] = -(xx * ex + xy * ey + xz * ez);
        r.m[13] = -(yx * ex + yy * ey + yz * ez);
        r.m[14] = -(zx * ex + zy * ey + zz * ez);
        return r;
    }

    public static Mat4 mul(Mat4 a, Mat4 b) {
        Mat4 r = new Mat4();
        for (int c = 0; c < 4; c++)
            for (int i = 0; i < 4; i++) {
                float s = 0f;
                for (int k = 0; k < 4; k++) s += a.m[k * 4 + i] * b.m[c * 4 + k];
                r.m[c * 4 + i] = s;
            }
        return r;
    }

    /** General 4x4 inverse (cofactor method). Returns null if singular. */
    public Mat4 invert() {
        float[] a = m;
        float[] inv = new float[16];
        inv[0] = a[5]*a[10]*a[15] - a[5]*a[11]*a[14] - a[9]*a[6]*a[15] + a[9]*a[7]*a[14] + a[13]*a[6]*a[11] - a[13]*a[7]*a[10];
        inv[4] = -a[4]*a[10]*a[15] + a[4]*a[11]*a[14] + a[8]*a[6]*a[15] - a[8]*a[7]*a[14] - a[12]*a[6]*a[11] + a[12]*a[7]*a[10];
        inv[8] = a[4]*a[9]*a[15] - a[4]*a[11]*a[13] - a[8]*a[5]*a[15] + a[8]*a[7]*a[13] + a[12]*a[5]*a[11] - a[12]*a[7]*a[9];
        inv[12] = -a[4]*a[9]*a[14] + a[4]*a[10]*a[13] + a[8]*a[5]*a[14] - a[8]*a[6]*a[13] - a[12]*a[5]*a[10] + a[12]*a[6]*a[9];
        inv[1] = -a[1]*a[10]*a[15] + a[1]*a[11]*a[14] + a[9]*a[2]*a[15] - a[9]*a[3]*a[14] - a[13]*a[2]*a[11] + a[13]*a[3]*a[10];
        inv[5] = a[0]*a[10]*a[15] - a[0]*a[11]*a[14] - a[8]*a[2]*a[15] + a[8]*a[3]*a[14] + a[12]*a[2]*a[11] - a[12]*a[3]*a[10];
        inv[9] = -a[0]*a[9]*a[15] + a[0]*a[11]*a[13] + a[8]*a[1]*a[15] - a[8]*a[3]*a[13] - a[12]*a[1]*a[11] + a[12]*a[3]*a[9];
        inv[13] = a[0]*a[9]*a[14] - a[0]*a[10]*a[13] - a[8]*a[1]*a[14] + a[8]*a[2]*a[13] + a[12]*a[1]*a[10] - a[12]*a[2]*a[9];
        inv[2] = a[1]*a[6]*a[15] - a[1]*a[7]*a[14] - a[5]*a[2]*a[15] + a[5]*a[3]*a[14] + a[13]*a[2]*a[7] - a[13]*a[3]*a[6];
        inv[6] = -a[0]*a[6]*a[15] + a[0]*a[7]*a[14] + a[4]*a[2]*a[15] - a[4]*a[3]*a[14] - a[12]*a[2]*a[7] + a[12]*a[3]*a[6];
        inv[10] = a[0]*a[5]*a[15] - a[0]*a[7]*a[13] - a[4]*a[1]*a[15] + a[4]*a[3]*a[13] + a[12]*a[1]*a[7] - a[12]*a[3]*a[5];
        inv[14] = -a[0]*a[5]*a[14] + a[0]*a[6]*a[13] + a[4]*a[1]*a[14] - a[4]*a[2]*a[13] - a[12]*a[1]*a[6] + a[12]*a[2]*a[5];
        inv[3] = -a[1]*a[6]*a[11] + a[1]*a[7]*a[10] + a[5]*a[2]*a[11] - a[5]*a[3]*a[10] - a[9]*a[2]*a[7] + a[9]*a[3]*a[6];
        inv[7] = a[0]*a[6]*a[11] - a[0]*a[7]*a[10] - a[4]*a[2]*a[11] + a[4]*a[3]*a[10] + a[8]*a[2]*a[7] - a[8]*a[3]*a[6];
        inv[11] = -a[0]*a[5]*a[11] + a[0]*a[7]*a[9] + a[4]*a[1]*a[11] - a[4]*a[3]*a[9] - a[8]*a[1]*a[7] + a[8]*a[3]*a[5];
        inv[15] = a[0]*a[5]*a[10] - a[0]*a[6]*a[9] - a[4]*a[1]*a[10] + a[4]*a[2]*a[9] + a[8]*a[1]*a[6] - a[8]*a[2]*a[5];
        float det = a[0]*inv[0] + a[1]*inv[4] + a[2]*inv[8] + a[3]*inv[12];
        if (Math.abs(det) < 1e-12f) return null;
        det = 1f / det;
        Mat4 r = new Mat4();
        for (int i = 0; i < 16; i++) r.m[i] = inv[i] * det;
        return r;
    }

    /**
     * Sub-texel jitter for TAAU: shifts NDC by (jx, jy) texels at the given render size.
     * For a perspective matrix, clip.w = -z_eye, so adding d to m[8] shifts NDC.x by -d.
     */
    public void applyJitter(float jxTexels, float jyTexels, int renderW, int renderH) {
        m[8] -= 2f * jxTexels / renderW;
        m[9] -= 2f * jyTexels / renderH;
    }
}