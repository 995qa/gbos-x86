# Build environment for the gbOS86 local AI pieces (APK + llama-server). Packages come from Debian's mirrors;
# the Android SDK/NDK are mounted from fetch_toolchain.sh, not baked in.
FROM debian:trixie-slim
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
      openjdk-21-jdk-headless zip unzip ca-certificates git cmake ninja-build python3 make \
    && rm -rf /var/lib/apt/lists/*
