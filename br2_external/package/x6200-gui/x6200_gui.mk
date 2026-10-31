################################################################################
#
#  X6200 GUI application
#
################################################################################

X6200_GUI_VERSION = v0.1.0
X6200_GUI_SITE = https://github.com/gdyuldin/x6200_gui
X6200_GUI_SITE_METHOD = git
X6200_GUI_GIT_SUBMODULES = YES
X6200_GUI_LICENSE = GPLv2

X6200_GUI_INSTALL_STAGING = YES

X6200_GUI_DEPENDENCIES = libpng libdrm aether-x6200-control ft8lib speexdsp liquid-dsp

$(eval $(cmake-package))
