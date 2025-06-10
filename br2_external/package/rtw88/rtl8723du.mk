################################################################################
#
#  rtw88 driver
#
################################################################################

RTW88_VERSION = 461b696b51317ba4ca585a4ddb32f2e72cd4efc9
RTW88_SITE = https://github.com/lwfinger/rtw88
RTW88_SITE_METHOD = git
RTW88_LICENSE = GPL-2.0

RTW88_INSTALL_STAGING = YES

$(eval $(kernel-module))
$(eval $(generic-package))
