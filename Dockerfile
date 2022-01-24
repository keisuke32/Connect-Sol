#syntax=docker/dockerfile:1.2@sha256:e2a8561e419ab1ba6b2fe6cbdf49fd92b95912df1cf7d313c3e2230a333fdbcc
FROM docker.io/library/rust:1.49@sha256:a50165ea96983c21832578afb1c8c028674c965bc1ed43b607871b1f362e06a5

RUN apt-get update && \
    apt-get install -y \
    clang \
    libssl-dev \
    libudev-dev \
    llvm \
    pkg-config \
    zlib1g-dev \
    && \
    rm -rf /var/lib/apt/lists/* && \
    rustup component add rustfmt && \
    rustup default nightly-2021-08-01

RUN sh -c "$(curl -sSfL https://release.solana.com/v1.7.8/install)"

ENV PATH="/root/.local/share/solana/install/active_release/bin:$PATH"

# Solana does a questionable download at the beginning of a *first* build-bpf call. Trigger and layer-cache it explicitly.
RUN cargo init --lib /tmp/decoy-crate && \
    cd /tmp/decoy-crate && cargo build-bpf && \
    rm -rf /tmp/decoy-crate

# Cache Pyth sources
# This comes soon after mainnet-v2.1
ENV PYTH_SRC_REV=31e3188bbf52ec1a25f71e4ab969378b27415b0a
ENV PYTH_DIR=/usr/src/pyth/pyth-client

WORKDIR $PYTH_DIR
ADD https://github.com/pyth-network/pyth-client/archive/$PYTH_SRC_REV.tar.gz .

# GitHub appends revision to dir in archive
RUN tar -xvf *.tar.gz && rm -rf *.tar.gz && mv pyth-client-$PYTH_SRC_REV pyth-client

# Add bridge contract sources
WORKDIR /usr/src/bridge

ADD . .

RUN mkdir -p /opt/solana/deps

ENV EMITTER_ADDRESS="11111111111111111111111111111115"

# Build Wormhole Solana progrms
RUN --mount=type=cache,target=bridge/target \
    --mount=type=cache,target=modules/token_bridge/target \
    --mount=type=cache,target=target \
    --mount=type=cache,target=bin,from=rust,source=bin \
    cargo build-bpf --manifest-path "bridge/program/Cargo.toml" && \
    cargo build-bpf --manifest-path "bridge/cpi_poster/Cargo.toml" && \
    cargo build-bpf --manifest-path "modules/token_bridge/program/Cargo.toml" && \
    cp bridge/target/deploy/bridge.so /opt/solana/deps/bridge.so && \
    cp bridge/target/deploy/cpi_poster.so /opt/solana/deps/cpi_poster.so && \
    cp modules/token_bridge/target/deploy/token_bridge.so /opt/solana/deps/token_bridge.so && \
    cp modules/token_bridge/token-metadata/spl_token_metadata.so /opt/solana/deps/spl_token_metadata.so

# Build the Pyth Solana program
WORKDIR $PYTH_DIR/pyth-client/program
RUN make SOLANA=~/.local/share/solana/install/active_release/bin OUT_DIR=../target && \
    cp ../target/oracle.so /opt/solana/deps/pyth_oracle.so

ENV RUST_LOG="solana_runtime::system_instruction_processor=trace,solana_runtime::message_processor=trace,solana_bpf_loader=debug,solana_rbpf=debug"
ENV RUST_BACKTRACE=1
