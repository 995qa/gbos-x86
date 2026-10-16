#!/system/bin/sh
# gbOS86 local AI, step 2: the model server (init service gbos_llama, started at boot_completed, user shell).
# llama-server listens on 127.0.0.1:8089 only; the AICore stand-in (localai.apk) talks to it. Its log goes to logcat.
D=/postinstall/gbos/localai
M=/data/gbos-localai/model.gguf
if [ ! -f "$M" ]; then
  log -t gbos-llama "no model at $M; local AI idle"
  sleep 3600; exit 0
fi
log -t gbos-llama "starting llama-server with $M"
# -t 4: this laptop has 4 physical cores. -c 8192: gPointer's instruction prompt alone is ~3.5k tokens.
# --reasoning off: no hidden thinking, which on this CPU would cost minutes. The prompt prefix is identical on every
# request, so the server's prompt cache (on by default) makes every request after the first much faster.
exec $D/llama-server -m "$M" --host 127.0.0.1 --port 8089 -c 8192 -t 4 -np 1 --jinja --reasoning off \
  --no-webui 2>&1 | log -t gbos-llama
