#!/usr/bin/env bash
# ZoolCoder colours for the bar, its plugins and the window borders: dark in dark mode, light in light mode.
# shellcheck disable=SC2034 # the variables are used by the files that source this one
if [ "$(defaults read -g AppleInterfaceStyle 2>/dev/null)" = Dark ]; then
  BASE=0x9905060a POPUP=0xf005060a SURFACE=0xff161A22 SURFACE1=0xff2b313d ON_ACCENT=0xff05060a
  TEXT=0xfff3f5f7 SUBTEXT=0xffb9bfc8 OVERLAY=0xff9aa2ad
  ACCENT=0xff3d7bff BLUE=0xff9cc3ff GREEN=0xff5fd38a PEACH=0xfff5b44a RED=0xffff7a7e
else
  BASE=0x99f7f7f4 POPUP=0xf0f7f7f4 SURFACE=0xffe3e3dc SURFACE1=0xffcbcbc2 ON_ACCENT=0xfff7f7f4
  TEXT=0xff111318 SUBTEXT=0xff4a4f59 OVERLAY=0xff646973
  ACCENT=0xff2457e6 BLUE=0xff1a45c2 GREEN=0xff0b7f4a PEACH=0xffb35c00 RED=0xffc2262c
fi
