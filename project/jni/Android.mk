LOCAL_PATH:= $(call my-dir)

include $(CLEAR_VARS)
LOCAL_MODULE    := stub
LOCAL_LDLIBS    := -llog -landroid

# 16KB page size support for Android 15+
LOCAL_LDFLAGS += -Wl,-z,max-page-size=16384

# Enable LTO for better performance and smaller size
LOCAL_CFLAGS += -O3 -flto -fvisibility=hidden
LOCAL_CPPFLAGS += -O3 -flto -fvisibility=hidden

# Strip debug symbols in release
LOCAL_LDFLAGS += -Wl,--strip-debug

SOURCES := $(wildcard $(LOCAL_PATH)/nc/*.cpp)
LOCAL_C_INCLUDES := $(LOCAL_PATH)/nc

LOCAL_SRC_FILES := $(SOURCES:$(LOCAL_PATH)/%=%)

include $(BUILD_SHARED_LIBRARY)
