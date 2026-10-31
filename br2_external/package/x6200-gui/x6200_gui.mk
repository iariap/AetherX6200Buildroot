################################################################################
#
#  X6200 GUI application
#
################################################################################

X6200_GUI_VERSION = 57f671e879fc42919eaa0add46bf844680cfa2b1
X6200_GUI_SITE = https://github.com/iariap/x6200_gui.git
X6200_GUI_SITE_METHOD = git
X6200_GUI_GIT_SUBMODULES = YES
X6200_GUI_LICENSE = GPLv2

X6200_GUI_INSTALL_STAGING = YES

X6200_GUI_DEPENDENCIES = libpng libdrm aether-x6200-control ft8lib speexdsp liquid-dsp

$(eval $(cmake-package))
