#!/bin/bash -e

# Directory contains the target rootfs
TARGET_ROOTFS_DIR="binary"

case "${ARCH:-$1}" in
	arm|arm32|armhf)
		ARCH=armhf
		;;
	*)
		ARCH=arm64
		;;
esac

echo -e "\033[36m Building for $ARCH \033[0m"

if [ ! $VERSION ]; then
	VERSION="release"
fi

if [ -e $TARGET_ROOTFS_DIR ]; then
	sudo rm -rf $TARGET_ROOTFS_DIR
fi

if [ ! -e ubuntu20.04-whole.tar.gz ]; then
	echo "\033[36m Run mk-base-ubuntu.sh first \033[0m"
	exit -1
fi

finish() {
	sudo umount $TARGET_ROOTFS_DIR/dev
	exit -1
}
trap finish ERR

echo -e "\033[36m Extract image \033[0m"
sudo tar -xpf ubuntu20.04-whole.tar.gz

# packages folder
sudo mkdir -p $TARGET_ROOTFS_DIR/packages
sudo cp -rpf packages/$ARCH/* $TARGET_ROOTFS_DIR/packages

# overlay folder
sudo cp -rpf overlay/* $TARGET_ROOTFS_DIR/

# overlay-firmware folder
sudo cp -rpf overlay-firmware/* $TARGET_ROOTFS_DIR/

# overlay-debug folder
# adb, video, camera  test file
if [ "$VERSION" == "debug" ]; then
	sudo cp -rf overlay-debug/* $TARGET_ROOTFS_DIR/
fi
## hack the serial
sudo cp -f overlay/usr/lib/systemd/system/serial-getty@.service $TARGET_ROOTFS_DIR/lib/systemd/system/serial-getty@.service

# adb
if [[ "$ARCH" == "armhf" && "$VERSION" == "debug" ]]; then
	sudo cp -f overlay-debug/usr/local/share/adb/adbd-32 $TARGET_ROOTFS_DIR/usr/bin/adbd
elif [[ "$ARCH" == "arm64" && "$VERSION" == "debug" ]]; then
	sudo cp -f overlay-debug/usr/local/share/adb/adbd-64 $TARGET_ROOTFS_DIR/usr/bin/adbd
fi

# bt/wifi firmware
sudo mkdir -p $TARGET_ROOTFS_DIR/system/lib/modules/
sudo mkdir -p $TARGET_ROOTFS_DIR/vendor/etc
sudo find ../kernel/drivers/net/wireless/rockchip_wlan/*  -name "*.ko" | \
    xargs -n1 -i sudo cp {} $TARGET_ROOTFS_DIR/system/lib/modules/

echo -e "\033[36m Change root.....................\033[0m"
if [ "$ARCH" == "armhf" ]; then
	sudo cp /usr/bin/qemu-arm-static $TARGET_ROOTFS_DIR/usr/bin/
elif [ "$ARCH" == "arm64"  ]; then
	sudo cp /usr/bin/qemu-aarch64-static $TARGET_ROOTFS_DIR/usr/bin/
fi

sudo cp -f /etc/resolv.conf $TARGET_ROOTFS_DIR/etc/
sudo cp -f sources.list $TARGET_ROOTFS_DIR/etc/apt/

sudo mount -o bind /dev $TARGET_ROOTFS_DIR/dev

cat << EOF | sudo chroot $TARGET_ROOTFS_DIR

apt-get update
apt-get upgrade -y

chmod o+x /usr/lib/dbus-1.0/dbus-daemon-launch-helper
chmod +x /etc/rc.local

export APT_INSTALL="apt-get install -fy --allow-downgrades"

#---------------Pre-packages --------------
\${APT_INSTALL} bsdmainutils parole
apt remove -fy firefox totem

#---------------Rga--------------
\${APT_INSTALL} /packages/rga/*.deb

echo -e "\033[36m Setup Video.................... \033[0m"
\${APT_INSTALL} gstreamer1.0-plugins-bad gstreamer1.0-plugins-base gstreamer1.0-tools gstreamer1.0-alsa \
gstreamer1.0-plugins-base-apps qtmultimedia5-examples

\${APT_INSTALL} /packages/mpp/*
\${APT_INSTALL} /packages/gst-rkmpp/*.deb
#\${APT_INSTALL} /packages/gstreamer/*.deb
#\${APT_INSTALL} /packages/gst-plugins-base1.0/*.deb
#\${APT_INSTALL} /packages/gst-plugins-bad1.0/*.deb
#\${APT_INSTALL} /packages/gst-plugins-good1.0/*.deb

#---------Camera---------
echo -e "\033[36m Install camera.................... \033[0m"
\${APT_INSTALL} cheese v4l-utils
#\${APT_INSTALL} /packages/rkisp/*.deb
\${APT_INSTALL} /packages/rkaiq/*.deb
\${APT_INSTALL} /packages/libv4l/*.deb

#---------Xserver---------
echo -e "\033[36m Install Xserver.................... \033[0m"
#\${APT_INSTALL} /packages/xserver/*.deb
dpkg -i /packages/xserver/*.deb
apt install -f -y

#apt-mark hold xserver-common xserver-xorg-core xserver-xorg-legacy
apt-mark hold xserver-xorg-core

#---------update chromium-----
\${APT_INSTALL} libjsoncpp-dev libminizip1
\${APT_INSTALL} /packages/chromium/*.deb

#------------------libdrm------------
echo -e "\033[36m Install libdrm.................... \033[0m"
\${APT_INSTALL} /packages/libdrm/*.deb

#------------------libdrm-cursor------------
echo -e "\033[36m Install libdrm-cursor.................... \033[0m"
\${APT_INSTALL} /packages/libdrm-cursor/*.deb

# Only preload libdrm-cursor for X
sed -i "/libdrm-cursor.so/d" /etc/ld.so.preload
sed -i "1aexport LD_PRELOAD=libdrm-cursor.so.1" /usr/bin/X

#------------------blueman------------
echo -e "\033[36m Install blueman.................... \033[0m"
\${APT_INSTALL} /packages/blueman/*.deb

#------------------rkwifibt------------
echo -e "\033[36m Install rkwifibt.................... \033[0m"
\${APT_INSTALL} /packages/rkwifibt/*.deb
ln -s /system/etc/firmware /vendor/etc/

if [ "$VERSION" == "debug" ]; then
#------------------glmark2------------
echo -e "\033[36m Install glmark2.................... \033[0m"
\${APT_INSTALL} glmark2-es2
fi

#------------------rknpu2------------
echo -e "\033[36m Install rknpu2.................... \033[0m"
tar xvf /packages/rknpu2/*.tar -C /

#------------------rktoolkit------------
echo -e "\033[36m Install rktoolkit.................... \033[0m"
\${APT_INSTALL} /packages/rktoolkit/*.deb

#------------------apt-utils------------
apt-get install -y apt-utils
apt-get install -y dialog

#------------------ffmpeg------------
\${APT_INSTALL} /packages/ffmpeg/*.deb

#------------------mpv------------
\${APT_INSTALL} smplayer
\${APT_INSTALL} /packages/mpv/*.deb
mv /etc/mpv/mpv-rk.conf /etc/mpv/mpv.conf
cp /packages/libmali/libmali-*-x11*.deb /
cp -rf /packages/rkaiq/*.deb /
# reduce 500M size for rootfs
rm -rf /usr/lib/firmware

# HACK to disable the kernel logo on bootup
sed -i "/exit 0/i \ echo 3 > /sys/class/graphics/fb0/blank" /etc/rc.local

#------remove unused packages------------
apt remove --purge -fy linux-firmware*

#---------------Clean--------------
if [ -e "/usr/lib/arm-linux-gnueabihf/dri" ]; then
	cd /usr/lib/arm-linux-gnueabihf/dri/
	cp kms_swrast_dri.so swrast_dri.so rockchip_dri.so /
	rm /usr/lib/arm-linux-gnueabihf/dri/*.so
	mv /*.so /usr/lib/arm-linux-gnueabihf/dri/
elif [ -e "/usr/lib/aarch64-linux-gnu/dri" ]; then
	cd /usr/lib/aarch64-linux-gnu/dri/
	cp kms_swrast_dri.so swrast_dri.so rockchip_dri.so /
	rm /usr/lib/aarch64-linux-gnu/dri/*.so
	mv /*.so /usr/lib/aarch64-linux-gnu/dri/
	rm /etc/profile.d/qt.sh
fi
cd -

# mark package to hold
apt list --installed | grep -v oldstable | cut -d/ -f1 | xargs apt-mark hold
#---------------Custom Script--------------
systemctl mask systemd-networkd-wait-online.service
systemctl mask NetworkManager-wait-online.service
rm /lib/systemd/system/wpa_supplicant@.service

EOF

sudo umount $TARGET_ROOTFS_DIR/dev
