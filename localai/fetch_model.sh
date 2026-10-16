#!/bin/sh
# Download the language model for the local AI replacement: Google's official Gemma 4 E2B instruction-tuned,
# quantisation-aware-trained 4-bit GGUF (Apache 2.0, 3.35 GB) from Hugging Face, checked against the published sha256.
# Usage: localai/fetch_model.sh [DIR]   (default usb/localai; use /Volumes/GBOS/gbos/localai for a finished stick)
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
DIR=${1:-$HERE/../usb/localai}
URL=https://huggingface.co/google/gemma-4-E2B-it-qat-q4_0-gguf/resolve/main/gemma-4-E2B_q4_0-it.gguf
SHA=fa401b55b07ee70a54c6dae3903c783a6e65064312529ea57175cb5f8dec6634
mkdir -p "$DIR"
F=$DIR/model.gguf
sum() { (sha256sum "$1" 2>/dev/null || shasum -a 256 "$1") | cut -d' ' -f1; }
if [ -f "$F" ] && [ "$(sum "$F")" = "$SHA" ]; then echo "model already present and verified: $F"; exit 0; fi
echo "downloading Gemma 4 E2B (3.35 GB) to $F"
curl -fL --progress-bar -o "$F.part" "$URL"
[ "$(sum "$F.part")" = "$SHA" ] || { echo "checksum mismatch, removing the download"; rm -f "$F.part"; exit 1; }
mv "$F.part" "$F"
echo "ok: $F"
