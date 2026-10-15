FROM --platform=linux/amd64 debian:trixie
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends erofs-utils python3 binutils clang lld ca-certificates >/dev/null && rm -rf /var/lib/apt/lists/*
