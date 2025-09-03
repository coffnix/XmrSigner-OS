#!/usr/bin/env bash
set -euo pipefail

echo "[1/7] Preparando árvore…"
cd ~
rm -rf ~/waveshare_fbcp
# se já tiver o .7z baixado, usa; senão, descomente o wget
# wget https://files.waveshare.com/upload/f/f9/Waveshare_fbcp.7z
7z x Waveshare_fbcp.7z -o./waveshare_fbcp >/dev/null

cd ~/waveshare_fbcp

echo "[2/7] (Opcional) Limpando flags ARM32 em CMake, se existirem…"
# Remove -marm, -mhard-float, -mfloat-abi=*, -mabi=aapcs-linux, -mtls-dialect=*
# (roda em todos CMakeLists e .cmake; se não existir, não faz nada)
find . -type f \( -name "CMakeLists.txt" -o -name "*.cmake" -o -name "toolchain*.cmake" \) -print0 \
| xargs -0 sed -ri 's/(^|[[:space:]])-marm([[:space:]]|$)/ /g;
                    s/(^|[[:space:]])-mhard-float([[:space:]]|$)/ /g;
                    s/(^|[[:space:]])-mfloat-abi=[^[:space:]]+([[:space:]]|$)/ /g;
                    s/(^|[[:space:]])-mabi=aapcs-linux([[:space:]]|$)/ /g;
                    s/(^|[[:space:]])-mtls-dialect=[^[:space:]]+([[:space:]]|$)/ /g' || true

echo "[3/7] Fix canônico do timer: tick.h 32+32 e TU de definições…"
# tick.h: dois ponteiros 32-bit e leitura estável CLO/CHI
cat > src/display/tick.h <<'EOF'
#pragma once
#include <stdint.h>

extern volatile uint32_t *systemTimerRegister;    // CLO @ +0x04
extern volatile uint32_t *systemTimerRegisterHi;  // CHI @ +0x08

static inline uint64_t tick(void)
{
    uint32_t hi1, lo, hi2;
    do {
        hi1 = *systemTimerRegisterHi;
        lo  = *systemTimerRegister;
        hi2 = *systemTimerRegisterHi;
    } while (hi1 != hi2);
    return ((uint64_t)hi1 << 32) | lo;
}
EOF

# TU com as definições globais (uma única vez no projeto)
cat > src/display/tick_vars.cpp <<'EOF'
#include <stdint.h>
volatile uint32_t *systemTimerRegister = 0;
volatile uint32_t *systemTimerRegisterHi = 0;
EOF

echo "[4/7] Garantindo headers e mapeamento corretos…"
# spi.h: headers POSIX (userland) p/ syscall/usleep/futex
# (insere no topo, mas só uma vez)
awk 'NR==1{
  if ($0 !~ /KERNEL_MODULE/){
    print "#pragma once";
    print "#ifndef KERNEL_MODULE";
    print "#include <unistd.h>";
    print "#include <sys/syscall.h>";
    print "#include <linux/futex.h>";
    print "#endif";
    next
  }
}
{ print }' src/display/spi.h > src/display/.spi.h.new && mv src/display/.spi.h.new src/display/spi.h

# spi.cpp: remove qualquer definição antiga de systemTimerRegister/Hi
sed -ri '/\bvolatile[[:space:]]+uint(32|64)_t[[:space:]]*\*[[:space:]]*systemTimerRegister(Hi)?[[:space:]]*=[[:space:]]*0[[:space:]]*;/d' src/display/spi.cpp

# spi.cpp: garante que o mapeamento use 32-bit p/ CLO/CHI
# - CLO: +0x04
perl -0777 -i -pe 's/systemTimerRegister\s*=\s*\(volatile\s+uint64_t\*\)/systemTimerRegister = (volatile uint32_t*)/g' src/display/spi.cpp
# - injeta CHI logo após CLO se não existir ainda
awk '
  /systemTimerRegister[[:space:]]*=.*\+ BCM2835_TIMER_BASE \+ 0x04/ && !seen {
    print;
    print "  systemTimerRegisterHi  = (volatile uint32_t*)((uintptr_t)bcm2835 + BCM2835_TIMER_BASE + 0x08);";
    seen=1; next
  }
  { print }
' src/display/spi.cpp > src/display/.spi.cpp.new && mv src/display/.spi.cpp.new src/display/spi.cpp

echo "[5/7] Headers POSIX no keyboard.cpp (read/close/open)…"
# adiciona <unistd.h> e <fcntl.h> no topo se faltarem
grep -q '^#include <unistd.h>' src/display/keyboard.cpp || sed -i '1i #include <unistd.h>' src/display/keyboard.cpp
grep -q '^#include <fcntl.h>'  src/display/keyboard.cpp || sed -i '1i #include <fcntl.h>'  src/display/keyboard.cpp

echo "[6/7] Verificação de sanidade (não pode restar 64-bit nos símbolos do timer)…"
! grep -RInE 'systemTimerRegister(Hi)?[^;\n]*uint64_t' src || { echo "Ainda há referência 64-bit ao timer. Abortando."; exit 1; }

echo "[7/7] Build…"
rm -rf build
mkdir build
cd build

CFLAGS="$(pkg-config --cflags bcm_host)"
CXXFLAGS="$(pkg-config --cflags bcm_host)"
LDFLAGS="$(pkg-config --libs bcm_host) -lvchostif"

cmake .. \
  -DCMAKE_BUILD_TYPE=Debug \
  -DSPI_BUS_CLOCK_DIVISOR=20 \
  -DWAVESHARE_1INCH3_LCD_HAT=ON \
  -DBACKLIGHT_CONTROL=ON \
  -DSTATISTICS=0 \
  -DUSE_DMA_TRANSFERS=OFF \
  -DCMAKE_C_FLAGS="$CFLAGS" \
  -DCMAKE_CXX_FLAGS="$CXXFLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS"

make -j"$(nproc)"

echo "OK. Binário em: ~/waveshare_fbcp/build/fbcp"
