#!/system/bin/sh
# Run by init right after apexd has activated all APEXes (and before zygote): bind the SHA-NI-free libcrypto
# over every APEX copy that is byte-identical to the Conscrypt one. Mounts go into init's (default) namespace.
ORIG=dc4f73623434eaaaa7cf4628571b5a990cd9a14f1c1cd42a4c4f57a06dac394f
P=/postinstall/gbos/patched/conscrypt.libcrypto.so
[ -f $P ] || { log -t gbos "apex_patch: $P missing"; exit 0; }
for d in /apex/*; do
  case $d in *@*) continue;; esac
  f=$d/lib64/libcrypto.so
  [ -f $f ] || continue
  if [ "$(sha256sum $f | cut -d' ' -f1)" = "$ORIG" ]; then
    mount -o bind $P $f && log -t gbos "apex_patch: patched $f" || log -t gbos "apex_patch: bind FAILED $f"
  fi
done
