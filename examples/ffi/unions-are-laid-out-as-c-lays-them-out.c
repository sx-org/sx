typedef union { int a; float b; } V;
typedef struct { unsigned char c; V v; } S2;

typedef union { unsigned char a[3]; short b; } W;
typedef struct { unsigned char c; W w; unsigned char d; } S3;

long long s2Size(void) { return sizeof(S2); }
long long s2Fields(const S2 *s) { return s->c * 10000 + s->v.a; }

long long wSize(void) { return sizeof(W); }

long long s3Size(void) { return sizeof(S3); }
long long s3Fields(const S3 *s) { return s->c * 100000 + s->w.b * 10 + s->d; }
