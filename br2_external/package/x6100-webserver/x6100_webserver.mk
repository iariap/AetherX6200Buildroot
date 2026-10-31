################################################################################
#
#  X6200 web configurator
#
#  IU1WXY's extended X6100 webserver, adapted for this firmware (see the fork's
#  README): identity, remote-control socket and Field Ops helper names.
#
################################################################################

X6100_WEBSERVER_VERSION = 2f842f28540d54153fcc49dd2573b5c8107cbb0b
X6100_WEBSERVER_SITE = https://github.com/iariap/x6200_webserver
X6100_WEBSERVER_SITE_METHOD = git
X6100_WEBSERVER_LICENSE = GPL-2.0-or-later
X6100_WEBSERVER_LICENSE_FILES = LICENSE
X6100_WEBSERVER_DEPENDENCIES = python-bottle-sqlite
X6100_WEBSERVER_SETUP_TYPE = flit

$(eval $(python-package))
