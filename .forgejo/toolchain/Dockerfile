# Build context: the sx repository root.
FROM debian:bookworm AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl xz-utils ca-certificates gnupg \
    && curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key | gpg --dearmor -o /usr/share/keyrings/llvm.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/llvm.gpg] http://apt.llvm.org/bookworm/ llvm-toolchain-bookworm-22 main" > /etc/apt/sources.list.d/llvm.list \
    && apt-get update && apt-get install -y --no-install-recommends \
    llvm-22-dev libclang-22-dev libclang-cpp22-dev \
    g++ libzstd-dev zlib1g-dev
ARG ZIG_VERSION=0.16.0
RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz \
    || curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz; \
    tar -xJf /tmp/zig.tar.xz -C /opt && mv /opt/zig-* /opt/zig && rm /tmp/zig.tar.xz
COPY . /src
WORKDIR /src
RUN /opt/zig/zig build -Doptimize=ReleaseSafe -Dllvm-prefix=/usr/lib/llvm-22 --prefix /opt/sx

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates gnupg \
    && curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key | gpg --dearmor -o /usr/share/keyrings/llvm.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/llvm.gpg] http://apt.llvm.org/bookworm/ llvm-toolchain-bookworm-22 main" > /etc/apt/sources.list.d/llvm.list \
    && apt-get update && apt-get install -y --no-install-recommends \
    libllvm22 libclang-cpp22 libclang-common-22-dev libzstd1 zlib1g libstdc++6 libatomic1 libc6-dev gcc git \
    && apt-get purge -y gnupg && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*
# `sx run` links the objects of each `#import c` unit by spawning `cc -shared`.
RUN printf 'int sx_cc_probe(void) { return 0; }\n' > /tmp/probe.c \
    && cc -shared -o /tmp/probe.so /tmp/probe.c \
    && rm /tmp/probe.c /tmp/probe.so
COPY --from=build /opt/sx /opt/sx
COPY --from=build /opt/zig /opt/zig
COPY --from=build /src/library /opt/sx/library
# Forgejo actions (checkout, upload-artifact) and the npm builds of jobs run on
# this bare binary; a job that runs npm brings its own.
COPY --from=node:26.3.0-bookworm-slim@sha256:3fe807a03a4436e7bc76b7e84e6861899cd75c9028ae99bc00581940141ae150 /usr/local/bin/node /usr/local/bin/node
ENV PATH="/opt/sx/bin:/opt/zig:${PATH}" \
    SX_STDLIB_PATH=/opt/sx/library \
    SX_ZIG=/opt/zig/zig
