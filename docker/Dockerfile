# syntax=docker/dockerfile:1
#
# Legacy SAS runtime for the ts-sas-legacy-analytics estate.
#
# Stage 1 builds OpenSAS (Apache-2.0 SAS 9.4 interpreter, Zig) from a pinned
# tag plus the compatibility patch in docker/opensas/. Stage 2 is the "SAS
# server": the estate at /opt/sas/custom, the library tree at /data/sas, and a
# `sas` command that accepts the flags the batch jobs already use.
#
#   docker compose -f docker/compose.yml build          (context = repo root)
#   docker compose -f docker/compose.yml run --rm sas    (runs the banking pipeline)

ARG ZIG_VERSION=0.16.0
ARG ZIG_SHA256=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
ARG OPENSAS_REPO=https://github.com/kirha-ai/opensas.git
ARG OPENSAS_REF=v0.6.5

# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS opensas-build
ARG ZIG_VERSION
ARG ZIG_SHA256
ARG OPENSAS_REPO
ARG OPENSAS_REF

RUN apt-get update -q \
 && apt-get install -y -q --no-install-recommends ca-certificates curl git xz-utils \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz \
 && echo "${ZIG_SHA256}  /tmp/zig.tar.xz" | sha256sum -c - \
 && mkdir -p /opt/zig && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
 && rm /tmp/zig.tar.xz

WORKDIR /src
RUN git clone --depth 1 --branch "${OPENSAS_REF}" "${OPENSAS_REPO}" opensas
COPY docker/opensas/0001-banking-estate-compat.patch /tmp/
RUN cd opensas \
 && git -c user.name=build -c user.email=build@localhost am --3way /tmp/0001-banking-estate-compat.patch \
 && /opt/zig/zig build -Doptimize=ReleaseFast

# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS sas
ARG ESTATE_COMMIT=unknown

LABEL org.opencontainers.image.title="ts-sas-legacy-analytics legacy runtime" \
      org.opencontainers.image.description="OpenSAS-based stand-in for the SAS 9.4 batch server that runs the banking estate" \
      org.opencontainers.image.licenses="Unlicense (estate) / Apache-2.0 (OpenSAS)"

RUN apt-get update -q \
 && apt-get install -y -q --no-install-recommends ca-certificates bash coreutils \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd -g 1000 sas && useradd -m -u 1000 -g sas -s /bin/bash sas

COPY --from=opensas-build /src/opensas/zig-out/bin/sas /usr/local/libexec/opensas/sas
COPY --from=opensas-build /src/opensas/LICENSE /usr/local/libexec/opensas/LICENSE
COPY --chmod=755 docker/bin/sas docker/bin/run-banking docker/bin/sas-entrypoint.sh /usr/local/bin/

# The estate, laid out the way the production jobs address it. macros/ is the
# autocall library the programs %include by absolute path: the production
# Macro/ directory with the four container stand-ins from docker/shims/ on top
# (see docker/README.md, "Shims").
ENV SAS_REPO_ROOT=/opt/sas/custom \
    SAS_DATA_ROOT=/data/sas \
    SASAUTOS=/opt/sas/custom/macros
COPY --chown=sas:sas . /opt/sas/custom
RUN echo "${ESTATE_COMMIT}" > /opt/sas/custom/.estate-commit \
 && mkdir -p /opt/sas/custom/macros \
 && cp /opt/sas/custom/Macro/*.sas /opt/sas/custom/macros/ \
 && cp /opt/sas/custom/docker/shims/*.sas /opt/sas/custom/macros/ \
 && ln -sfn /opt/sas/custom/Programs /opt/sas/custom/programs \
 && mkdir -p /data/sas && chown -R sas:sas /opt/sas/custom /data/sas

USER sas
WORKDIR /opt/sas/custom
VOLUME ["/data/sas"]
ENTRYPOINT ["/usr/local/bin/sas-entrypoint.sh"]
CMD ["run-banking"]
