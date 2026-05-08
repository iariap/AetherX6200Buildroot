################################################################################
#
#  Aether-Radio's X6200 base control library
#
################################################################################

AETHER_X6200_CONTROL_VERSION = v0.1.1
AETHER_X6200_CONTROL_SITE = https://github.com/gdyuldin/X6200Control
AETHER_X6200_CONTROL_SITE_METHOD = git
AETHER_X6200_CONTROL_LICENSE = GPLv2

AETHER_X6200_CONTROL_INSTALL_STAGING = YES

$(eval $(cmake-package))
