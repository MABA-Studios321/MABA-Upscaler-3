package com.maba.upscalertest;

import android.opengl.GLES30;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * The "MABA Core" test scene: a plasma reactor orb inside a slowly turning geodesic cage of thin
 * beams with glowing joints, orbited by faceted crystal shards and fed by an energy beam from a
 * stepped pedestal. Around it: a halo of emissive blades, a circle of detailed lamp pillars and
 * a polished grid floor. Procedural; no external assets.
 *
 * Built to stress an upscaler: sub-pixel beams and light strips, many small emissive points,
 * hard faceted silhouettes, panel seams, dark areas and moving specular glints.
 *
 * Vertex layout: pos(3) normal(3) uv(2) mat(1) = 9 floats. Materials (see scene3d.frag.glsl):
 *   0 plasma orb      1 halo blades     2 floor           3 cage beams (uv.x along, uv.y phase)
 *   4 structure metal 5 crystal shards  6 cyan emissive   7 pillar shaft (uv.x facet, uv.y height)
 *   8 warm energy beam
 * Pillar positions / heights are mirrored in the fragment shader (nearestPillar) for lighting.
 */
public final class Scene3D {
    static final float FLOOR_Y = -1.55f;
    static final float CORE_Y = 0.25f;
    static final float ORB_R = 0.5f;
    static final float CAGE_R = 1.05f;
    static final float HALO_R = 2.55f;
    static final float PILLAR_R = 6.2f;
    static final int PILLARS = 10;
    private static final int SHARDS = 7;

    private static final class Mesh {
        int vbo, vao, count;
    }

    private final Mesh orb = new Mesh(), cage = new Mesh(), shard = new Mesh(), lamp = new Mesh(),
        spokes = new Mesh(), structure = new Mesh(), floor = new Mesh();

    public void init() {
        resetCache();
        upload(orb, sphere(ORB_R, 48, 24, 0));
        upload(cage, buildCage(CAGE_R, 0.011f, 0.032f));
        upload(shard, buildShard());
        Buf l = new Buf();
        bipyramid(l, 0, 0, 0, 0.12f, 0.20f, 0.20f, 4, 0, 6);
        upload(lamp, l.done());
        upload(spokes, buildSpokes(72, HALO_R));
        upload(structure, buildStructure());
        upload(floor, buildFloor(60f));
    }

    private static void upload(Mesh mesh, float[] data) {
        FloatBuffer fb = ByteBuffer.allocateDirect(data.length * 4)
            .order(ByteOrder.nativeOrder()).asFloatBuffer();
        fb.put(data).position(0);
        int[] buf = new int[1];
        GLES30.glGenBuffers(1, buf, 0);
        GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, buf[0]);
        GLES30.glBufferData(GLES30.GL_ARRAY_BUFFER, data.length * 4, fb, GLES30.GL_STATIC_DRAW);
        mesh.vbo = buf[0];
        mesh.count = data.length / 9;

        // One vertex array per mesh: the layout (pos, normal, uv, material; 36-byte stride) is set
        // once here, so a draw only binds the array instead of re-specifying four attributes.
        int[] va = new int[1];
        GLES30.glGenVertexArrays(1, va, 0);
        GLES30.glBindVertexArray(va[0]);
        GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, buf[0]);
        GLES30.glEnableVertexAttribArray(0);
        GLES30.glVertexAttribPointer(0, 3, GLES30.GL_FLOAT, false, 36, 0);
        GLES30.glEnableVertexAttribArray(1);
        GLES30.glVertexAttribPointer(1, 3, GLES30.GL_FLOAT, false, 36, 12);
        GLES30.glEnableVertexAttribArray(2);
        GLES30.glVertexAttribPointer(2, 2, GLES30.GL_FLOAT, false, 36, 24);
        GLES30.glEnableVertexAttribArray(3);
        GLES30.glVertexAttribPointer(3, 1, GLES30.GL_FLOAT, false, 36, 32);
        GLES30.glBindVertexArray(0);
        mesh.vao = va[0];
    }

    /** Height of pillar i's octagonal shaft. Mirrored in scene3d.frag.glsl. */
    static float pillarShaft(int i) {
        return 1.9f + 0.5f * (i % 3);
    }

    /** Resting height of pillar i's floating lamp crystal. Mirrored in scene3d.frag.glsl. */
    static float lampY(int i) {
        return FLOOR_Y + 0.85f + pillarShaft(i);
    }

    static float pillarAngle(int i) {
        return (float) (Math.PI * 2 * (i + 0.5) / PILLARS);
    }

    /** Growable vertex buffer. */
    private static final class Buf {
        float[] a = new float[9 * 4096];
        int n;

        void v(double x, double y, double z, double nx, double ny, double nz,
               double u, double w, float mat) {
            if (n + 9 > a.length) a = Arrays.copyOf(a, a.length * 2);
            a[n++] = (float) x; a[n++] = (float) y; a[n++] = (float) z;
            a[n++] = (float) nx; a[n++] = (float) ny; a[n++] = (float) nz;
            a[n++] = (float) u; a[n++] = (float) w; a[n++] = mat;
        }

        float[] done() { return Arrays.copyOf(a, n); }
    }

    // ------------------------------------------------------------------------------------
    // Primitive builders
    // ------------------------------------------------------------------------------------

    /** UV sphere with smooth normals, centred on the origin. */
    private static float[] sphere(float r, int segU, int segV, float mat) {
        Buf b = new Buf();
        for (int i = 0; i < segU; i++) {
            for (int j = 0; j < segV; j++) {
                int[][] q = {{i, j}, {i + 1, j}, {i, j + 1}, {i + 1, j}, {i + 1, j + 1}, {i, j + 1}};
                for (int[] c : q) {
                    double u = 2 * Math.PI * c[0] / segU, v = Math.PI * c[1] / segV;
                    double nx = Math.sin(v) * Math.cos(u), ny = Math.cos(v), nz = Math.sin(v) * Math.sin(u);
                    b.v(r * nx, r * ny, r * nz, nx, ny, nz, (double) c[0] / segU, (double) c[1] / segV, mat);
                }
            }
        }
        return b.done();
    }

    /**
     * Faceted vertical prism / frustum around (cx, cz) from y0 to y1, radius r0 at the bottom
     * and r1 at the top (either may be 0 for a point). Flat per-facet normals. uv.x runs
     * around the facets (facet f covers [f, f+1] / sides); uv.y is vFixed, or the height
     * fraction when vFixed < 0. Optional flat caps.
     */
    private static void prism(Buf b, double cx, double cz, double y0, double y1, double r0, double r1,
                              int sides, double ang0, float mat, double vFixed,
                              boolean capTop, boolean capBottom) {
        double dy = y1 - y0;
        double dr = (r1 - r0) * Math.cos(Math.PI / sides);
        for (int f = 0; f < sides; f++) {
            double a0 = ang0 + 2 * Math.PI * f / sides, a1 = ang0 + 2 * Math.PI * (f + 1) / sides;
            double am = (a0 + a1) * 0.5;
            double nx = Math.cos(am) * dy, ny = -dr, nz = Math.sin(am) * dy;
            double nl = Math.sqrt(nx * nx + ny * ny + nz * nz);
            nx /= nl; ny /= nl; nz /= nl;
            double u0 = (double) f / sides, u1 = (double) (f + 1) / sides;
            double vb = vFixed >= 0 ? vFixed : 0, vt = vFixed >= 0 ? vFixed : 1;
            double[] b0 = {cx + r0 * Math.cos(a0), y0, cz + r0 * Math.sin(a0)};
            double[] b1 = {cx + r0 * Math.cos(a1), y0, cz + r0 * Math.sin(a1)};
            double[] t0 = {cx + r1 * Math.cos(a0), y1, cz + r1 * Math.sin(a0)};
            double[] t1 = {cx + r1 * Math.cos(a1), y1, cz + r1 * Math.sin(a1)};
            if (r0 > 0) {
                b.v(b0[0], b0[1], b0[2], nx, ny, nz, u0, vb, mat);
                b.v(b1[0], b1[1], b1[2], nx, ny, nz, u1, vb, mat);
                b.v(t1[0], t1[1], t1[2], nx, ny, nz, u1, vt, mat);
            }
            if (r1 > 0) {
                b.v(b0[0], b0[1], b0[2], nx, ny, nz, u0, vb, mat);
                b.v(t1[0], t1[1], t1[2], nx, ny, nz, u1, vt, mat);
                b.v(t0[0], t0[1], t0[2], nx, ny, nz, u0, vt, mat);
            }
            if (capTop && r1 > 0) {
                double vc = vFixed >= 0 ? vFixed : 1;
                b.v(cx, y1, cz, 0, 1, 0, 0.5, vc, mat);
                b.v(t0[0], t0[1], t0[2], 0, 1, 0, 0.5, vc, mat);
                b.v(t1[0], t1[1], t1[2], 0, 1, 0, 0.5, vc, mat);
            }
            if (capBottom && r0 > 0) {
                double vc = vFixed >= 0 ? vFixed : 0;
                b.v(cx, y0, cz, 0, -1, 0, 0.5, vc, mat);
                b.v(b1[0], b1[1], b1[2], 0, -1, 0, 0.5, vc, mat);
                b.v(b0[0], b0[1], b0[2], 0, -1, 0, 0.5, vc, mat);
            }
        }
    }

    /** Double pyramid (crystal / gem) centred at (cx, cy, cz). */
    private static void bipyramid(Buf b, double cx, double cy, double cz, double r,
                                  double hTop, double hBot, int sides, double ang0, float mat) {
        prism(b, cx, cz, cy - hBot, cy, 0, r, sides, ang0, mat, -1, false, false);
        prism(b, cx, cz, cy, cy + hTop, r, 0, sides, ang0, mat, -1, false, false);
    }

    /** Smooth vertical cylinder from y0 to y1 with a top cap. Side uv.y = height fraction. */
    private static void cylinder(Buf b, float r, float y0, float y1, int seg, float mat) {
        for (int i = 0; i < seg; i++) {
            double a0 = 2 * Math.PI * i / seg, a1 = 2 * Math.PI * (i + 1) / seg;
            double c0 = Math.cos(a0), s0 = Math.sin(a0), c1 = Math.cos(a1), s1 = Math.sin(a1);
            double u0 = (double) i / seg, u1 = (double) (i + 1) / seg;
            b.v(r * c0, y0, r * s0, c0, 0, s0, u0, 0, mat);
            b.v(r * c1, y0, r * s1, c1, 0, s1, u1, 0, mat);
            b.v(r * c1, y1, r * s1, c1, 0, s1, u1, 1, mat);
            b.v(r * c0, y0, r * s0, c0, 0, s0, u0, 0, mat);
            b.v(r * c1, y1, r * s1, c1, 0, s1, u1, 1, mat);
            b.v(r * c0, y1, r * s0, c0, 0, s0, u0, 1, mat);
            b.v(0, y1, 0, 0, 1, 0, u0, 0.5, mat);
            b.v(r * c0, y1, r * s0, 0, 1, 0, u0, 0.5, mat);
            b.v(r * c1, y1, r * s1, 0, 1, 0, u1, 0.5, mat);
        }
    }

    /** Box centred at (cx,cy,cz) with half sizes, rotated by ang about Y (local x -> (cos,0,sin)). */
    private static void box(Buf b, double cx, double cy, double cz, double hx, double hy, double hz,
                            double ang, float mat) {
        double c = Math.cos(ang), s = Math.sin(ang);
        double[][] lc = new double[8][3];
        for (int k = 0; k < 8; k++) {
            lc[k][0] = (k & 1) == 0 ? -hx : hx;
            lc[k][1] = (k & 4) == 0 ? -hy : hy;
            lc[k][2] = (k & 2) == 0 ? -hz : hz;
        }
        int[][] faces = {{0, 2, 3, 1}, {4, 5, 7, 6}, {0, 1, 5, 4}, {2, 6, 7, 3}, {0, 4, 6, 2}, {1, 3, 7, 5}};
        double[][] normals = {{0, -1, 0}, {0, 1, 0}, {0, 0, -1}, {0, 0, 1}, {-1, 0, 0}, {1, 0, 0}};
        for (int f = 0; f < 6; f++) {
            double[] n = normals[f];
            double nx = n[0] * c - n[2] * s, nz = n[0] * s + n[2] * c;
            int[] q = faces[f];
            for (int idx : new int[]{q[0], q[1], q[2], q[0], q[2], q[3]}) {
                double[] p = lc[idx];
                b.v(cx + p[0] * c - p[2] * s, cy + p[1], cz + p[0] * s + p[2] * c,
                    nx, n[1], nz, f / 6.0, (p[1] + hy) / (2 * hy), mat);
            }
        }
    }

    /** Square-section beam from A to B. uv.x = 0 at A .. 1 at B; uv.y = phase (for pulses). */
    private static void beam(Buf b, double[] A, double[] B, double h, float mat, double phase) {
        double dx = B[0] - A[0], dy = B[1] - A[1], dz = B[2] - A[2];
        double len = Math.sqrt(dx * dx + dy * dy + dz * dz);
        dx /= len; dy /= len; dz /= len;
        double rx = 0, ry = 1, rz = 0;
        if (Math.abs(dy) > 0.9) { rx = 1; ry = 0; }
        double ux = dy * rz - dz * ry, uy = dz * rx - dx * rz, uz = dx * ry - dy * rx;
        double ul = Math.sqrt(ux * ux + uy * uy + uz * uz);
        ux /= ul; uy /= ul; uz /= ul;
        double vx = dy * uz - dz * uy, vy = dz * ux - dx * uz, vz = dx * uy - dy * ux;
        double rr = h * Math.sqrt(2);
        for (int f = 0; f < 4; f++) {
            double a0 = Math.PI / 4 + f * Math.PI / 2, a1 = a0 + Math.PI / 2, am = a0 + Math.PI / 4;
            double o0x = (ux * Math.cos(a0) + vx * Math.sin(a0)) * rr;
            double o0y = (uy * Math.cos(a0) + vy * Math.sin(a0)) * rr;
            double o0z = (uz * Math.cos(a0) + vz * Math.sin(a0)) * rr;
            double o1x = (ux * Math.cos(a1) + vx * Math.sin(a1)) * rr;
            double o1y = (uy * Math.cos(a1) + vy * Math.sin(a1)) * rr;
            double o1z = (uz * Math.cos(a1) + vz * Math.sin(a1)) * rr;
            double nx = ux * Math.cos(am) + vx * Math.sin(am);
            double ny = uy * Math.cos(am) + vy * Math.sin(am);
            double nz = uz * Math.cos(am) + vz * Math.sin(am);
            b.v(A[0] + o0x, A[1] + o0y, A[2] + o0z, nx, ny, nz, 0, phase, mat);
            b.v(A[0] + o1x, A[1] + o1y, A[2] + o1z, nx, ny, nz, 0, phase, mat);
            b.v(B[0] + o1x, B[1] + o1y, B[2] + o1z, nx, ny, nz, 1, phase, mat);
            b.v(A[0] + o0x, A[1] + o0y, A[2] + o0z, nx, ny, nz, 0, phase, mat);
            b.v(B[0] + o1x, B[1] + o1y, B[2] + o1z, nx, ny, nz, 1, phase, mat);
            b.v(B[0] + o0x, B[1] + o0y, B[2] + o0z, nx, ny, nz, 1, phase, mat);
        }
    }

    // ------------------------------------------------------------------------------------
    // Scene parts
    // ------------------------------------------------------------------------------------

    private static double[] unit(double x, double y, double z) {
        double l = Math.sqrt(x * x + y * y + z * z);
        return new double[]{x / l, y / l, z / l};
    }

    private static double dist2(double[] a, double[] b) {
        double x = a[0] - b[0], y = a[1] - b[1], z = a[2] - b[2];
        return x * x + y * y + z * z;
    }

    /** Index of the normalized midpoint of verts a and b, created once per edge. */
    private static int midpoint(List<double[]> verts, Map<Long, Integer> cache, int a, int b) {
        long key = (long) Math.min(a, b) * 100000L + Math.max(a, b);
        Integer hit = cache.get(key);
        if (hit != null) return hit;
        double[] p = verts.get(a), q = verts.get(b);
        verts.add(unit(p[0] + q[0], p[1] + q[1], p[2] + q[2]));
        cache.put(key, verts.size() - 1);
        return verts.size() - 1;
    }

    /** Frequency-2 geodesic sphere: 120 beams and a glowing node at each of the 42 joints. */
    private static float[] buildCage(float radius, float beamHalf, float nodeR) {
        double phi = (1 + Math.sqrt(5)) / 2;
        double[][] ico = {{-1, phi, 0}, {1, phi, 0}, {-1, -phi, 0}, {1, -phi, 0},
            {0, -1, phi}, {0, 1, phi}, {0, -1, -phi}, {0, 1, -phi},
            {phi, 0, -1}, {phi, 0, 1}, {-phi, 0, -1}, {-phi, 0, 1}};
        List<double[]> verts = new ArrayList<>();
        for (double[] v : ico) verts.add(unit(v[0], v[1], v[2]));

        // Icosahedron faces: vertex triples that are pairwise adjacent.
        double edge2 = dist2(verts.get(0), verts.get(1));
        List<int[]> faces = new ArrayList<>();
        for (int i = 0; i < 12; i++)
            for (int j = i + 1; j < 12; j++)
                for (int k = j + 1; k < 12; k++)
                    if (Math.abs(dist2(verts.get(i), verts.get(j)) - edge2) < 1e-6
                        && Math.abs(dist2(verts.get(j), verts.get(k)) - edge2) < 1e-6
                        && Math.abs(dist2(verts.get(i), verts.get(k)) - edge2) < 1e-6)
                        faces.add(new int[]{i, j, k});

        // One subdivision step.
        Map<Long, Integer> cache = new HashMap<>();
        Set<Long> edges = new LinkedHashSet<>();
        for (int[] f : faces) {
            int ab = midpoint(verts, cache, f[0], f[1]);
            int bc = midpoint(verts, cache, f[1], f[2]);
            int ca = midpoint(verts, cache, f[2], f[0]);
            int[][] sub = {{f[0], ab, ca}, {ab, f[1], bc}, {ca, bc, f[2]}, {ab, bc, ca}};
            for (int[] t : sub)
                for (int e = 0; e < 3; e++) {
                    int a = t[e], c = t[(e + 1) % 3];
                    edges.add((long) Math.min(a, c) * 100000L + Math.max(a, c));
                }
        }

        Buf b = new Buf();
        int n = 0;
        for (long key : edges) {
            double[] p = verts.get((int) (key / 100000L)), q = verts.get((int) (key % 100000L));
            double[] A = {p[0] * radius, p[1] * radius, p[2] * radius};
            double[] B = {q[0] * radius, q[1] * radius, q[2] * radius};
            beam(b, A, B, beamHalf, 3, (n++ * 0.618034) % 1.0);
        }
        for (double[] v : verts) {
            bipyramid(b, v[0] * radius, v[1] * radius, v[2] * radius, nodeR, nodeR * 1.3, nodeR * 1.3, 4, 0, 6);
        }
        return b.done();
    }

    /** Hexagonal crystal: short faceted body with pointed tips, centred on the origin. */
    private static float[] buildShard() {
        Buf b = new Buf();
        prism(b, 0, 0, -0.07, 0.07, 0.085, 0.085, 6, 0, 5, -1, false, false);
        prism(b, 0, 0, 0.07, 0.34, 0.085, 0, 6, 0, 5, -1, false, false);
        prism(b, 0, 0, -0.26, -0.07, 0, 0.085, 6, 0, 5, -1, false, false);
        return b.done();
    }

    /** Halo of thin radial blades: hard thin-line aliasing stress. */
    private static float[] buildSpokes(int count, float radius) {
        Buf b = new Buf();
        for (int i = 0; i < count; i++) {
            double ang = Math.PI * 2 * i / count;
            box(b, Math.cos(ang) * radius, 0, Math.sin(ang) * radius, 0.20, 0.025, 0.008, ang, 1);
        }
        return b.done();
    }

    /** Pedestal, energy beam and the circle of detailed lamp pillars (all static). */
    private static float[] buildStructure() {
        Buf b = new Buf();
        float y = FLOOR_Y;

        // Stepped pedestal with a ring of cooling fins and the energy beam up into the core.
        cylinder(b, 1.15f, y, y + 0.16f, 96, 4);
        cylinder(b, 0.70f, y + 0.16f, y + 0.26f, 72, 4);
        for (int i = 0; i < 28; i++) {
            double a = Math.PI * 2 * i / 28;
            box(b, Math.cos(a) * 0.93, y + 0.19, Math.sin(a) * 0.93, 0.13, 0.03, 0.012, a, 4);
        }
        cylinder(b, 0.035f, y + 0.26f, 0.0f, 20, 8);

        for (int i = 0; i < PILLARS; i++) pillar(b, i);
        return b.done();
    }

    /**
     * One lamp pillar: two-step square plinth, flared foot, tapered octagonal shaft (light
     * strips, seams and bevels are shaded in the fragment shader), two metal collars, a flared
     * capital and a glowing top slab. The floating lamp crystal is drawn separately so it can
     * move.
     */
    private static void pillar(Buf b, int i) {
        double a = pillarAngle(i);
        double cx = Math.cos(a) * PILLAR_R, cz = Math.sin(a) * PILLAR_R;
        double y = FLOOR_Y;
        double oct = a - Math.PI / 8;      // octagon facet 0 faces outward, facet 4 faces the core
        double sq = a + Math.PI / 4;       // square faces aligned radially
        double shaft = pillarShaft(i);

        prism(b, cx, cz, y, y + 0.09, 0.46, 0.46, 4, sq, 4, 0.5, true, false);
        prism(b, cx, cz, y + 0.09, y + 0.17, 0.36, 0.36, 4, sq, 4, 0.5, true, false);
        prism(b, cx, cz, y + 0.17, y + 0.27, 0.25, 0.205, 8, oct, 4, 0.5, false, false);
        double s0 = y + 0.27, s1 = s0 + shaft;
        prism(b, cx, cz, s0, s1, 0.20, 0.175, 8, oct, 7, -1, false, false);
        for (double fr : new double[]{0.30, 0.64}) {
            double yc = s0 + shaft * fr;
            double rc = 0.20 + (0.175 - 0.20) * fr + 0.02;
            prism(b, cx, cz, yc, yc + 0.06, rc, rc, 8, oct, 4, 0.5, true, true);
        }
        prism(b, cx, cz, s1, s1 + 0.12, 0.175, 0.26, 8, oct, 4, 0.5, false, false);
        prism(b, cx, cz, s1 + 0.12, s1 + 0.18, 0.27, 0.27, 8, oct, 4, -1, true, true);
    }

    private static float[] buildFloor(float size) {
        Buf b = new Buf();
        double h = size / 2, y = FLOOR_Y;
        double[][] p = {{-h, y, -h}, {h, y, -h}, {-h, y, h}, {h, y, -h}, {h, y, h}, {-h, y, h}};
        for (double[] v : p) b.v(v[0], v[1], v[2], 0, 1, 0, 0, 0, 2);
        return b.done();
    }

    // ------------------------------------------------------------------------------------
    // Drawing
    // ------------------------------------------------------------------------------------

    // Every object's model matrix at a given animation time, in draw order. Frame Gen asks for
    // two times (this real frame and the previous one) so the shader can output exact
    // per-pixel motion, camera AND object.
    private static final int MODEL_COUNT = 2 + SHARDS + 1 + PILLARS + 2;
    private final Mat4[] curModels = new Mat4[MODEL_COUNT];
    private final Mat4[] prevModels = new Mat4[MODEL_COUNT];
    // Scratch matrices: the per-frame matrix work allocates nothing.
    private final Mat4 tCore = new Mat4(), tOrbit = new Mat4(), tA = new Mat4(), tB = new Mat4(), tC = new Mat4();
    private Mesh[] drawOrder;

    {
        for (int i = 0; i < MODEL_COUNT; i++) {
            curModels[i] = Mat4.identity();
            prevModels[i] = Mat4.identity();
        }
    }

    private Mesh[] order() {
        if (drawOrder == null) {
            drawOrder = new Mesh[MODEL_COUNT];
            int n = 0;
            drawOrder[n++] = orb;
            drawOrder[n++] = cage;
            for (int i = 0; i < SHARDS; i++) drawOrder[n++] = shard;
            drawOrder[n++] = spokes;
            for (int i = 0; i < PILLARS; i++) drawOrder[n++] = lamp;
            drawOrder[n++] = structure;
            drawOrder[n++] = floor;
        }
        return drawOrder;
    }

    /** Fills m (draw order) for the given time, without allocating; returns the core's height. */
    private float computeModels(float time, Mat4[] m) {
        int n = 0;
        // The core floats and breathes; everything around it moves at its own pace.
        float bob = CORE_Y + 0.10f * (float) Math.sin(time * 0.8f);
        tCore.setTranslate(0, bob, 0);

        // orb = core * rotY * rotX
        tA.setRotY(time * 0.5f); tB.setRotX(0.4f); Mat4.mulInto(tA, tB, tC);
        Mat4.mulInto(tCore, tC, m[n++]);
        // cage = core * rotY * (rotX * rotZ)
        tA.setRotX(0.55f + 0.15f * (float) Math.sin(time * 0.4f)); tB.setRotZ(time * 0.09f); Mat4.mulInto(tA, tB, tC);
        tA.setRotY(time * 0.22f); Mat4.mulInto(tA, tC, tB);
        Mat4.mulInto(tCore, tB, m[n++]);

        // Crystal shards on an inclined, slowly precessing orbit, each tumbling on its own.
        tA.setRotY(time * 0.1f); tB.setRotX(0.28f); Mat4.mulInto(tA, tB, tC);
        Mat4.mulInto(tCore, tC, tOrbit);
        for (int i = 0; i < SHARDS; i++) {
            float a = time * 0.42f + (float) (Math.PI * 2 * i / SHARDS);
            float r = 1.62f + 0.12f * (float) Math.sin(i * 2.3f);
            float h = 0.22f * (float) Math.sin(time * 0.9f + i * 1.7f);
            // orbit * T * rotY * rotZ * rotX * S, built right to left
            tA.setRotX(time * (0.6f + 0.1f * i) + i); tB.setScale(0.8f + 0.08f * (i % 4)); Mat4.mulInto(tA, tB, tC);
            tA.setRotZ(0.5f * (float) Math.sin(time * 0.7f + i)); Mat4.mulInto(tA, tC, tB);
            tA.setRotY(-a + i); Mat4.mulInto(tA, tB, tC);
            tA.setTranslate((float) Math.cos(a) * r, h, (float) Math.sin(a) * r); Mat4.mulInto(tA, tC, tB);
            Mat4.mulInto(tOrbit, tB, m[n++]);
        }

        tA.setTranslate(0, FLOOR_Y + 0.55f, 0); tB.setRotY(-time * 0.22f);
        Mat4.mulInto(tA, tB, m[n++]);

        // Floating lamp crystals above each pillar.
        for (int i = 0; i < PILLARS; i++) {
            float a = pillarAngle(i);
            float y = lampY(i) + 0.06f * (float) Math.sin(time * 1.3f + i);
            tA.setTranslate((float) Math.cos(a) * PILLAR_R, y, (float) Math.sin(a) * PILLAR_R);
            tB.setRotY(time * 0.8f + i);
            Mat4.mulInto(tA, tB, m[n++]);
        }

        m[n++].setIdentity();   // structure
        m[n].setIdentity();     // floor
        return bob;
    }

    // Uniform locations, looked up once per program instead of every frame.
    private int locProg = -1, locModel = -1, locPrevModel = -1, locCore = -1;
    private void draw(Mesh mesh, int uModel, Mat4 model, int uPrevModel, Mat4 prevModel) {
        GLES30.glUniformMatrix4fv(uModel, 1, false, model.m, 0);
        if (prevModel != null) GLES30.glUniformMatrix4fv(uPrevModel, 1, false, prevModel.m, 0);
        GLES30.glBindVertexArray(mesh.vao);
        GLES30.glDrawArrays(GLES30.GL_TRIANGLES, 0, mesh.count);
    }

    /**
     * Draw the whole scene at animation time `time`. prevTime is the animation time of the
     * previous real frame (for motion vectors); pass a negative value when the program does not
     * write motion vectors. progScene must be in use; uVP (and uPrevVP for the velocity variant)
     * are set by the caller.
     */
    public void draw(int progScene, float time, float prevTime) {
        if (progScene != locProg) {
            locProg = progScene;
            locModel = GLES30.glGetUniformLocation(progScene, "uModel");
            locPrevModel = GLES30.glGetUniformLocation(progScene, "uPrevModel");
            locCore = GLES30.glGetUniformLocation(progScene, "uCore");
        }
        float bob = computeModels(time, curModels);
        boolean motion = locPrevModel >= 0;
        if (motion) computeModels(prevTime < 0f ? time : prevTime, prevModels);
        // The orb as a sphere, for the shader's core light, soft shadow, AO and floor reflection.
        GLES30.glUniform4f(locCore, 0f, bob, 0f, ORB_R);

        Mesh[] meshes = order();
        for (int i = 0; i < MODEL_COUNT; i++) {
            draw(meshes[i], locModel, curModels[i], locPrevModel, motion ? prevModels[i] : null);
        }
    }

    public void draw(int progScene, float time) {
        draw(progScene, time, -1f);
    }

    /** A new GL context means new program ids. */
    public void resetCache() {
        locProg = -1;
    }
}