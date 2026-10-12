TARGET := iphone:clang:latest:15.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = EeveeImmersive
EeveeImmersive_FILES = Tweak.m
EeveeImmersive_CFLAGS = -fobjc-arc
EeveeImmersive_FRAMEWORKS = UIKit QuartzCore CoreImage CoreGraphics

include $(THEOS_MAKE_PATH)/library.mk
