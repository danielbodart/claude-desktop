# libpipewire for the app's native binding, without the rest of PipeWire.
#
# @ant/claude-native links libpipewire-0.3.so.0, so it has to resolve at
# build time. nixpkgs' pipewire has no separate lib output, and its single
# output carries the daemon's modules: gstreamer, ffmpeg, bluez, libcamera,
# vulkan and python, about 635 MiB. The client library only talks to the
# PipeWire daemon the system already runs, so all of that is switched off.
{
  lib,
  pipewire,
}:

(pipewire.override {
  bluezSupport = false;
  vulkanSupport = false;
  zeroconfSupport = false;
  raopSupport = false;
  rocSupport = false;
  x11Support = false;
  ffadoSupport = false;
}).overrideAttrs
  (old: {
    pname = "libpipewire";

    # Meson takes the last value given for an option, so these win over the
    # package's own settings.
    mesonFlags = old.mesonFlags ++ [
      (lib.mesonEnable "gstreamer" false)
      (lib.mesonEnable "gstreamer-device-provider" false)
      (lib.mesonEnable "ffmpeg" false)
      (lib.mesonEnable "pw-cat-ffmpeg" false)
      (lib.mesonEnable "libcamera" false)
      (lib.mesonEnable "echo-cancel-webrtc" false)
      (lib.mesonEnable "libmysofa" false)
      (lib.mesonEnable "v4l2" false)
      (lib.mesonEnable "pipewire-v4l2" false)
      (lib.mesonEnable "avb" false)
      (lib.mesonEnable "docs" false)
      (lib.mesonEnable "man" false)
      (lib.mesonEnable "installed_tests" false)
    ];

    # Nothing to put in these once docs, man pages and tests are off.
    postInstall = (old.postInstall or "") + ''
      mkdir -p $doc $man $installedTests
    '';

    meta = old.meta // {
      description = "PipeWire client library, built without the daemon's media backends";
    };
  })
