# SLURM test cluster image - builds SLURM 26.11 from local source.
# One image, multiple roles (slurmdbd | slurmctld | slurmd) selected at runtime.
#
# Build context MUST be the Slurm source root so the source tree is available
# to COPY. See docker-compose.yml (context: ../..).
FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive

# Fixed uids/gids so files shared via volumes line up across containers.
ARG SLURM_UID=981
ARG SLURM_GID=981
ARG MUNGE_UID=982
ARG MUNGE_GID=982

# ---------------------------------------------------------------------------
# Build + runtime dependencies.
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        autoconf \
        automake \
        libtool \
        pkg-config \
        gcc \
        make \
        wget \
        ca-certificates \
        libmunge-dev \
        munge \
        libmariadb-dev \
        libpam0g-dev \
        libjson-c-dev \
        libyaml-dev \
        libssl-dev \
        libdbus-1-dev \
        python3 \
        mariadb-client \
        gosu \
        iproute2 \
        procps \
        vim-tiny \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Users / groups. slurm runs the control/db daemons; munge runs munged.
# ---------------------------------------------------------------------------
RUN groupadd -g ${MUNGE_GID} munge 2>/dev/null || true \
    && id -u munge >/dev/null 2>&1 || useradd -m -c "MUNGE" -d /var/lib/munge -u ${MUNGE_UID} -g munge -s /sbin/nologin munge \
    && groupadd -g ${SLURM_GID} slurm \
    && useradd -m -c "SLURM workload manager" -d /var/lib/slurm -u ${SLURM_UID} -g slurm -s /bin/bash slurm

# ---------------------------------------------------------------------------
# Compile SLURM from the local source tree.
# `configure` is already present in the checkout, so autogen.sh is not needed;
# fall back to autoreconf if it is somehow missing.
# ---------------------------------------------------------------------------
COPY . /usr/local/src/slurm
WORKDIR /usr/local/src/slurm

RUN if [ ! -x ./configure ]; then ./autogen.sh || autoreconf -i; fi \
    && ./configure \
         --prefix=/usr/local \
         --sysconfdir=/etc/slurm \
         --enable-debug \
         --without-shared-libslurm 2>/dev/null \
       || ./configure --prefix=/usr/local --sysconfdir=/etc/slurm --enable-debug \
    && make -j"$(nproc)" \
    && make install \
    && ldconfig \
    && make -C contribs/openlava install 2>/dev/null || true

# ---------------------------------------------------------------------------
# Runtime dirs (writable by slurm). slurmd dirs are created at runtime too.
# ---------------------------------------------------------------------------
RUN mkdir -p /etc/slurm \
             /var/spool/slurm \
             /var/spool/slurmd \
             /var/spool/slurmctld \
             /var/log/slurm \
             /var/run/slurm \
    && chown -R slurm:slurm /var/spool/slurm /var/spool/slurmctld /var/log/slurm /var/run/slurm \
    && chmod 0755 /var/spool/slurmd

# ---------------------------------------------------------------------------
# Shared (test-only) munge key, baked in so every container authenticates.
# ---------------------------------------------------------------------------
COPY contribs/docker-test/munge.key /etc/munge/munge.key
RUN chown munge:munge /etc/munge/munge.key && chmod 0400 /etc/munge/munge.key \
    && chown -R munge:munge /etc/munge /var/lib/munge /var/log/munge /var/run/munge 2>/dev/null || true

# ---------------------------------------------------------------------------
# Entry point selects the role.
# ---------------------------------------------------------------------------
COPY contribs/docker-test/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /root
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
