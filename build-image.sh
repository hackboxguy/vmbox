#!/bin/sh
#
sudo ./build.sh --mode=base --output=/tmp/alpine-build --version=1.0.1

sudo ./scripts/build-app-partition.sh \
  --packages=packages.txt \
  --output=/tmp/alpine-build/app \
  --rootfs=/tmp/alpine-build/rootfs

sudo ./scripts/03-create-image.sh \
  --rootfs=/tmp/alpine-build/rootfs \
  --output=/tmp/alpine-build \
  --ospart=600M \
  --datapart=200M \
  --apppart=300M \
  --appdir=/tmp/alpine-build/app/app

sudo chown -R $(id -u):$(id -g) /tmp/alpine-build

./scripts/04-convert-to-vbox.sh \
  --input=/tmp/alpine-build/alpine-vbox.raw \
  --vmname=alpine-demo \
  --appdir=/tmp/alpine-build/app/app \
  --force \
  --memory=1024 \
  --usb=2 --usbstorageid=8564,0781,1307

VBoxManage startvm "alpine-demo" --type headless
