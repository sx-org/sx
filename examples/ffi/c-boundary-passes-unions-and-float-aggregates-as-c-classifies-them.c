typedef float v4f __attribute__((ext_vector_type(4)));

union FI { float f; int i; };
union HU { float a; float b[2]; };
union Big { long long a[3]; double d; };
struct PA { float a[2]; };
struct P2 { float x, y; };
struct V2 { v4f a; v4f b; };

int readFI(union FI u) { return u.i; }

float sumHU(union HU u) { return u.b[0] + u.b[1]; }

union HU makeHU(float x, float y) {
    union HU u;
    u.b[0] = x;
    u.b[1] = y;
    return u;
}

long long sumBig(union Big u) { return u.a[0] + u.a[1] + u.a[2]; }

union Big makeBig(long long x) {
    union Big u;
    u.a[0] = x;
    u.a[1] = x + 1;
    u.a[2] = x + 2;
    return u;
}

float sumPA(struct PA p) { return p.a[0] + p.a[1]; }

float sumP2After7(double a, double b, double c, double d, double e, double f, double g, struct P2 p) {
    return p.x + p.y;
}

float scaleV2(struct V2 v, float k) {
    return k * (v.a.x + v.a.y + v.a.z + v.a.w + v.b.x + v.b.y + v.b.z + v.b.w);
}

int sxReadFI(union FI u);

int callSxReadFI(int i) {
    union FI u;
    u.i = i;
    return sxReadFI(u);
}
