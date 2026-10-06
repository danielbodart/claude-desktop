# The QEMU that Cowork's helper actually drives, and nothing else.
#
# nixpkgs' default qemu carries every CPU target, every display and audio
# backend, and the edk2 firmware images, which together pull in python,
# gtk4, gstreamer, pipewire and ffmpeg: about 1.7 GiB on top of the app.
# The helper (resources/cowork-linux-helper) only ever runs a headless
# `qemu-system-<host arch>` with a fixed device set:
#
#   -machine q35,accel=kvm (TCG via COWORK_VM_ACCEL)  -cpu host|max
#   -object memory-backend-memfd,share=on            -sandbox on,...
#   -qmp unix:...  -display none  -vga none          -kernel/-initrd or pflash
#   -netdev user (slirp)                             virtio-{blk,net,rng}-pci
#   vhost-vsock-pci  vhost-user-fs-pci               virtio-serial-pci + virtconsole
#
# so everything else is switched off. The `qemu-cowork-devices` flake check
# asserts that each of those is still present.
{
  lib,
  stdenv,
  qemu,
}:

(qemu.override {
  hostCpuTargets = [ "${stdenv.hostPlatform.qemuArch}-softmmu" ];
  guestAgentSupport = false;
  alsaSupport = false;
  pulseSupport = false;
  pipewireSupport = false;
  jackSupport = false;
  sdlSupport = false;
  gtkSupport = false;
  vncSupport = false;
  ncursesSupport = false;
  smartcardSupport = false;
  spiceSupport = false;
  usbredirSupport = false;
  openGLSupport = false;
  virglSupport = false;
  rutabagaSupport = false;
  libiscsiSupport = false;
  tpmSupport = false;
  fuseSupport = false;
  capstoneSupport = false;
  brlttySupport = false;
  enableDocs = false;
  enableTools = false;
}).overrideAttrs
  (old: {
    pname = "qemu-cowork";

    # Neither has an override flag. vde2 drags in libpcap, rdma-core and perl;
    # curl brings openssl and krb5 for HTTP block devices nobody uses here.
    buildInputs = lib.filter (
      d:
      !(lib.elem (lib.getName d) [
        "vde2"
        "curl"
      ])
    ) old.buildInputs;
    configureFlags = old.configureFlags ++ [
      "--disable-vde"
      "--disable-curl"
    ];

    # The edk2 images are about 300 MiB. Cowork never loads QEMU's copies: for
    # EFI boot it reads OVMF/AAVMF from the FHS path the NixOS module links.
    # The other blobs stay, since virtio-net loads its option ROM from them.
    postInstall = (old.postInstall or "") + ''
      rm -f $out/share/qemu/edk2-* $out/share/qemu/firmware/*edk2*.json
    '';

    meta = old.meta // {
      description = "Headless, host-architecture-only QEMU with just what Claude Desktop's Cowork uses";
    };
  })
