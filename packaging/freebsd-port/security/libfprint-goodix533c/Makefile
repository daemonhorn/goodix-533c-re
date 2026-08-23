# Local FreeBSD port for the Goodix 27c6:533c native libfprint driver.
#
# This is a build variant of security/libfprint, not a new upstream
# project: it builds the same libfprint-2 SONAME from
# https://github.com/daemonhorn/libfprint (branch goodix533c-open-capture),
# a fork that adds a native FpDeviceClass driver for the Goodix 27c6:533c
# ("53xc"/GTLS family) fingerprint sensor -- upstreamed as
# https://github.com/goodix-fp-linux-dev/libfprint/pull/40, not yet merged.
#
# Modeled directly on the real security/libfprint port Makefile
# (cgit.freebsd.org/ports/plain/security/libfprint/Makefile, 1.94.10_1,
# maintainer danfe@FreeBSD.org) -- same USES/USE_GNOME/MESON_ARGS baseline,
# plus what this driver needs on top (OpenCV for SIGFM matching, an
# explicit -Ddrivers= list since goodix533c isn't in default_drivers).
#
# CONFLICTS_INSTALL with security/libfprint: this replaces the same
# libfprint-2.so.2 SONAME, so the two CANNOT coexist -- installing this
# port makes fprintd/PAM fingerprint login entirely unavailable on this
# system (security/fprintd's LIB_DEPENDS pulls in security/libfprint by
# port origin, which then file-conflicts) until this driver is either
# upstreamed (PR #40 above) or carried as a patch on security/libfprint
# itself. This is also a version downgrade of the base library while
# installed: the fork this port builds is 1.94.5; security/libfprint
# is currently 1.94.10_1 (five releases ahead, including newer driver
# PIDs of its own). This port exists to validate the driver builds and
# captures against real hardware on FreeBSD -- not for daily-driver
# fprintd/PAM use until upstreamed.

PORTNAME=	libfprint
PORTVERSION=	1.94.5.20260823
CATEGORIES=	security
PKGNAMESUFFIX=	-goodix533c

MAINTAINER=	dhorn2000@gmail.com
COMMENT=	Library for fingerprint reader devices, with Goodix 533c support
WWW=		https://github.com/daemonhorn/libfprint

LICENSE=	LGPL21+
LICENSE_FILE=	${WRKSRC}/COPYING

# libnss3.so: 'uru4000' (in the driver list below) needs it
# (driver_helper_mapping's 'nss' helper, meson.build:167/244-250) --
# happened to already be present as a transitive dependency of something
# else in the test VM, but a correct port must declare it explicitly.
LIB_DEPENDS=	libgusb.so:devel/libgusb \
		libpixman-1.so:x11/pixman \
		libopencv_core.so:graphics/opencv \
		libnss3.so:security/nss

USES=		compiler:c++17-lang gnome meson pkgconfig python:env shebangfix ssl
USE_GITHUB=	yes
GH_ACCOUNT=	daemonhorn
GH_PROJECT=	libfprint
GH_TAGNAME=	9484a83d8280552feaa80c471f218a0e98b9f82a
USE_GNOME=	glib20
USE_LDCONFIG=	yes
SHEBANG_GLOB=	*.py

CONFLICTS_INSTALL=	libfprint

# default_drivers (meson.build:102-133) minus 'elanspi' -- the only driver
# mapped to the 'udev' build helper (driver_helper_mapping, meson.build:168),
# which needs dependency('udev'); FreeBSD has no udev.pc provider. Plus
# 'goodix533c' explicitly, since it's deliberately excluded from
# default_drivers upstream (it pulls in OpenCV, meson.build:134-139) and
# there is no from-source Python extraction step available to a port
# Makefile the way packaging/build-libfprint-deb.sh has for the .deb build.
GOODIX533C_DRIVERS=	upektc_img,vfs5011,vfs7552,aes3500,aes4000,aes1610,aes1660,aes2660,aes2501,aes2550,vfs101,vfs301,vfs0050,etes603,egis0570,vcom5s,synaptics,elan,elanmoc,uru4000,upektc,upeksonly,upekts,goodixmoc,goodixtls511,nb1010,fpcmoc,goodix533c

# NOTE: no -Dinstalled-tests= here (unlike upstream security/libfprint) --
# this fork's meson_options.txt predates that upstream libfprint option;
# passing it fails configure with "Unknown option: installed-tests"
# (confirmed directly against the pinned commit's meson_options.txt).
#
# -D{c,cpp}_link_args=-L/usr/local/lib: the sigfm driver-helper branch in
# meson.build resolves OpenCV via raw cpp.find_library('opencv_core', ...)
# (not full pkg-config deps), which only searches the compiler's implicit
# default library dirs plus any explicit dirs: kwarg -- neither of which
# includes /usr/local/lib on FreeBSD's base Clang (unlike Linux, where
# /usr/lib is implicit). Confirmed directly: configure failed with
# "ld: error: unable to find library -lopencv_core" even though
# /usr/local/lib/libopencv_core.so exists, because the internal test-link
# command had no -L flag at all. This is the standard FreeBSD ports
# workaround for upstream code with this pattern.
MESON_ARGS=	-Dudev_hwdb=disabled \
		-Dudev_rules=disabled \
		-Dintrospection=false \
		-Ddoc=false \
		-Dc_link_args=-L${LOCALBASE}/lib \
		-Dcpp_link_args=-L${LOCALBASE}/lib \
		-Ddrivers=${GOODIX533C_DRIVERS}

INSTALL_TARGET=	install-strip

.include <bsd.port.mk>
