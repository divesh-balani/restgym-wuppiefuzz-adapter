# debian:trixie-slim (multi-arch index digest, resolved 2026-11-07)
FROM debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2

ARG WUPPIEFUZZ_VERSION=v1.8.0
# Copied from the release's published <asset>.tar.xz.sha256 files. Update together with the version.
ARG WUPPIEFUZZ_SHA256_X86_64=0ea6c80c7c3c9f9a8f836ba5a53572add1e403b52a493c7c79cec0b68deef991
ARG WUPPIEFUZZ_SHA256_AARCH64=281b4594ff4dc3198f25bf77a44deeecf8c1e37af66defa05302ddf3ab012461

RUN apt-get update && \
    apt-get install -qy --no-install-recommends ca-certificates curl xz-utils jq libstdc++6 && \
    rm -rf /var/lib/apt/lists/* && \
    case "$(uname -m)" in \
        x86_64)  TRIPLE=x86_64-unknown-linux-gnu;  SHA="$WUPPIEFUZZ_SHA256_X86_64" ;; \
        aarch64) TRIPLE=aarch64-unknown-linux-gnu; SHA="$WUPPIEFUZZ_SHA256_AARCH64" ;; \
        *) echo "Unsupported architecture: $(uname -m)" && exit 1 ;; \
    esac && \
    ASSET="wuppiefuzz-${TRIPLE}.tar.xz" && \
    BASE="https://github.com/TNO-S3/WuppieFuzz/releases/download/${WUPPIEFUZZ_VERSION}" && \
    cd /tmp && \
    curl -fsSL -o "$ASSET" "$BASE/$ASSET" && \
    curl -fsSL -o "$ASSET.sha256" "$BASE/$ASSET.sha256" && \
    # The published file must match the pinned hash, and the tarball must match both.
    [ "$(cut -d' ' -f1 "$ASSET.sha256")" = "$SHA" ] && \
    echo "$SHA  $ASSET" | sha256sum -c - && \
    tar -xJf "$ASSET" && \
    install -m 0755 "wuppiefuzz-${TRIPLE}/wuppiefuzz" /usr/local/bin/wuppiefuzz && \
    rm -rf /tmp/wuppiefuzz-* && \
    wuppiefuzz version

# Run as a non-root user, like the upstream WuppieFuzz image.
RUN useradd -ms /bin/bash fuzzer && mkdir -p /tool /tool-output && chown fuzzer:fuzzer /tool /tool-output

# Specifications are mounted at /specifications/ by RESTgym at runtime.
COPY --chown=fuzzer:fuzzer ./tools/wuppiefuzz/ /tool/

USER fuzzer
WORKDIR /tool
CMD ["sh", "/tool/run.sh"]
