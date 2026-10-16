# Build environment for the gbOS86 AI stand-in (the APK and its tests). Packages come from Debian's mirrors; the Android build
# tools and platform jar are mounted from fetch_toolchain.sh, not baked in.
FROM debian:trixie-slim
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
      openjdk-21-jdk-headless zip unzip ca-certificates \
    && rm -rf /var/lib/apt/lists/*
