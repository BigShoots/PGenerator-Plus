# ofxRPI4WindowHDR

### DESCRIPTION:   
This is an openFrameworks addon for the Raspberry Pi to allow rendering without X

HDR support added to take advantage of DRM linux kernel driver HDR metadata additions

Uses dual planes to allow on the fly switching between SDR overlay plane and HDR primary plane

Exposes HDR metadata and AVI infoframe structures to facilitate UI changes 

Extensive logging for debugging




### REQUIREMENTS:   
- openFrameworks 11, with patches to use float images and allow compiling on Biasilinux armv7l --> (ofx.patch)
- raspberry Pi linux 5.10, with patches to vc4, v3d, drm drivers --> (drm_vc4.patch)
- KMS Driver enabled, thru config.txt(see config.txt) 
- Newest Mesa libraries, with patches that add HDR colorspace attributes --> (mesa_hdr.patch)
- Mesa build command line: 

CFLAGS="-mcpu=cortex-a72 -mfpu=neon-fp-armv8" CXXFLAGS="-mcpu=cortex-a72 -mfpu=neon-fp-armv8"  meson --prefix /usr --libdir lib -D platforms=x11,wayland -D egl-native-platform=drm -D vulkan-drivers=broadcom,swrast -D dri-drivers=i915 -D gallium-drivers=kmsro,v3d,vc4,swrast -D buildtype=debug -D gles1=enabled -D gles2=enabled -D shared-glapi=enabled -D gbm=enabled -D gbm-backends-path=/usr/lib  -Dcpp_args="-fPIC" -Dc_args='-fPIC -O2'  build

### DEPENDENCIES

liburiparser.so.1.0.24

libxshmfence.so.1.0.0

libtinfo.so.6.2.0

libxcb-dri3.so.0.1.0

libxcb-present.so.0.0.0

libxcb-sync.so.1.0.0

libzstd.so.1.5.0

libdrm.so.2.4.0

libLLVM-9.so

mesa libraries as above 



 #### Manual Option  
Change `openFrameworks/libs/openFrameworksCompiled/project/linuxarmv7l/config.linuxarmv7l.default.mk`   

```
    ifeq ($(USE_PI_LEGACY), 1)
    	PLATFORM_DEFINES += TARGET_RASPBERRY_PI_LEGACY
        $(info using legacy build)
    else
    	# comment this for older EGL windowing. Has no effect if USE_PI_LEGACY is enabled
    	# GLFW seems to provide a more robust window on newer Raspbian releases
	#USE_GLFW_WINDOW = 1
    endif
```
    
Comment out `ofSetupOpenGL` in 
https://github.com/openframeworks/openFrameworks/blob/master/libs/openFrameworks/app/ofAppRunner.cpp#L31

of patch with ofx.patch

### PERMISSIONS
User pgenerator needs to be added to video group to allow permission to /dev/dri/card0, /dev/dri/card1, /dev/dri/render128
# usermod -a video pgenerator

### CREDITS:   
derived from 
https://github.com/matusnovak/rpi-opengl-without-x

https://gitlab.freedesktop.org/mesa/kmscube/tree/master

https://github.com/jvcleave/ofxRPI4Window

https://github.com/popcornmix/xbmc/tree/gbm_matrix


