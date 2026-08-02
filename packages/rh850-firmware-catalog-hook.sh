#!/bin/sh
# Install only the approved private RH850 firmware catalogue into the VM rootfs.
set -eu

SOURCE_DIR=${HOOK_LOCAL_SOURCE:?HOOK_LOCAL_SOURCE is required}
FIRMWARE_DIR="$SOURCE_DIR/firmware"
DEST_DIR=/usr/share/rh850-flasher

for file in \
    "$FIRMWARE_DIR/catalog.json" \
    "$FIRMWARE_DIR/bios/983HH_Board_ROMBIOS.bin" \
    "$FIRMWARE_DIR/bios/Spartan7_9090_ROMBIOS.bin" \
    "$FIRMWARE_DIR/bios/Lattice45_9090_ROMBIOS.bin" \
    "$FIRMWARE_DIR/bios-bin/983HH_Board_ROMBIOS_packet.bin" \
    "$FIRMWARE_DIR/bios-bin/Spartan7_9090_ROMBIOS_packet.bin" \
    "$FIRMWARE_DIR/bios-bin/Lattice45_9090_ROMBIOS_packet.bin"; do
    [ -f "$file" ] || {
        echo "ERROR: required RH850 firmware input is missing: $file" >&2
        exit 1
    }
done

cd "$FIRMWARE_DIR"
sha256sum -c <<'EOF'
edfb69f3e63951ca3759e425c8f3834256f0e34af62909313d370aa9383d271a  bios/983HH_Board_ROMBIOS.bin
991884f457eae91e0d693b3234e3853814d42d4d24267eecd6c40bf9d1423a0a  bios/Spartan7_9090_ROMBIOS.bin
8e51c498a5581a6f6cb642af79f5de0c49e23978ee987fa3d6c0b5a4a384414c  bios/Lattice45_9090_ROMBIOS.bin
748c096a5765970c12c923648b952936f8bb28703dcc11188957284980a04427  bios-bin/983HH_Board_ROMBIOS_packet.bin
da3fca641f0f74acd32f777c6c2e4da40b68e0ae077921a426d87e42cb641242  bios-bin/Spartan7_9090_ROMBIOS_packet.bin
e20376fcd518a770129aed33931ce6127bb29398130bfd0a625e6da4533d19e8  bios-bin/Lattice45_9090_ROMBIOS_packet.bin
EOF

install -d -m 0755 "$DEST_DIR/bios" "$DEST_DIR/direct"
install -m 0644 "$FIRMWARE_DIR/catalog.json" "$DEST_DIR/catalog.json"
install -m 0644 "$FIRMWARE_DIR/bios/983HH_Board_ROMBIOS.bin" \
    "$DEST_DIR/bios/983HH_Board_ROMBIOS.bin"
install -m 0644 "$FIRMWARE_DIR/bios/Spartan7_9090_ROMBIOS.bin" \
    "$DEST_DIR/bios/Spartan7_9090_ROMBIOS.bin"
install -m 0644 "$FIRMWARE_DIR/bios/Lattice45_9090_ROMBIOS.bin" \
    "$DEST_DIR/bios/Lattice45_9090_ROMBIOS.bin"
install -m 0644 "$FIRMWARE_DIR/bios-bin/983HH_Board_ROMBIOS_packet.bin" \
    "$DEST_DIR/direct/983HH_Board_ROMBIOS_packet.bin"
install -m 0644 "$FIRMWARE_DIR/bios-bin/Spartan7_9090_ROMBIOS_packet.bin" \
    "$DEST_DIR/direct/Spartan7_9090_ROMBIOS_packet.bin"
install -m 0644 "$FIRMWARE_DIR/bios-bin/Lattice45_9090_ROMBIOS_packet.bin" \
    "$DEST_DIR/direct/Lattice45_9090_ROMBIOS_packet.bin"
