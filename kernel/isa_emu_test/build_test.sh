C=/build/inputs/clang-r584948c/bin/clang-22
$C --target=x86_64-linux-gnu -O1 -static -nostdlib -ffreestanding -fno-stack-protector -fno-builtin \
  -mavx2 -mgfni -mvaes -mvpclmulqdq -mavxvnni -mavxifma -msha -maes -mpclmul -msse4.1 \
  -Wl,--build-id=none /host/kernel/isa_emu_test/t.c -o /host/kernel/isa_emu_test/t 2>&1
