# Boots qemu-cowork with the machine Cowork's helper asks for and checks over
# QMP that every device was instantiated. The flags mirror the string literals
# in resources/cowork-linux-helper; when an app update adds one, add it here.
{
  lib,
  stdenv,
  runCommand,
  python3,
  qemu-cowork,
  claude-desktop,
}:

let
  arch = stdenv.hostPlatform.qemuArch;
  # q35 is what the x86_64 helper names. aarch64 has no q35; virt is the
  # only general-purpose arm64 machine QEMU has.
  machine = if stdenv.hostPlatform.isx86_64 then "q35" else "virt";
  qemuBin = "${qemu-cowork}/bin/qemu-system-${arch}";
  resources = "${claude-desktop}/lib/claude-desktop/resources";

  devices = [
    "virtio-blk-pci"
    "virtio-net-pci"
    "virtio-rng-pci"
    "virtio-serial-pci"
    "virtconsole"
    "vhost-vsock-pci"
    "vhost-user-fs-pci"
  ];
in
runCommand "qemu-cowork-boots" { nativeBuildInputs = [ python3 ]; } ''
  set -euo pipefail

  ${qemuBin} -machine help | grep -qw ${machine}
  ${qemuBin} -accel help | grep -qw tcg
  ${qemuBin} -accel help | grep -qw kvm
  ${qemuBin} -netdev help | grep -qw user
  ${qemuBin} -object help | grep -qw memory-backend-memfd
  for d in ${lib.escapeShellArgs devices}; do
    ${qemuBin} -device help | grep -q "name \"$d\"" || {
      echo "qemu-cowork has no $d" >&2
      exit 1
    }
  done

  truncate -s 64M rootfs.img
  truncate -s 64M session.img
  truncate -s 64M smolbin.img
  mkdir shared

  # The bundled virtiofsd, as patched by the package, is what Cowork falls
  # back to on a host without one, so it doubles as the vhost-user backend.
  ${resources}/virtiofsd --socket-path=vfs.sock --shared-dir=shared --sandbox none \
    >virtiofsd.log 2>&1 &
  for _ in $(seq 100); do [ -S vfs.sock ] && break; sleep 0.1; done

  ${qemuBin} \
    -machine ${machine},accel=tcg,memory-backend=mem0 -cpu max -smp 1 -m 256M \
    -object memory-backend-memfd,id=mem0,size=256M,share=on \
    -display none -vga none -nodefaults \
    -sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny \
    -qmp unix:qmp.sock,server=on,wait=off \
    -drive file=rootfs.img,if=none,format=raw,cache=writeback,id=rootdisk -device virtio-blk-pci,drive=rootdisk \
    -drive file=session.img,if=none,format=raw,id=sessiondisk -device virtio-blk-pci,drive=sessiondisk \
    -drive file=smolbin.img,if=none,format=raw,readonly=on,id=smolbindisk -device virtio-blk-pci,drive=smolbindisk \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
    -chardev socket,id=virtiofs0,path=vfs.sock -device vhost-user-fs-pci,chardev=virtiofs0,tag=claudeshared \
    -device virtio-serial-pci \
    -chardev file,id=kernellog,path=kernel.log -device virtconsole,chardev=kernellog \
    -chardev file,id=daemonlog,path=daemon.log -device virtconsole,chardev=daemonlog,name=claude-daemon-console \
    -device virtio-rng-pci \
    >qemu.log 2>&1 &
  qemu=$!
  for _ in $(seq 100); do [ -S qmp.sock ] && break; sleep 0.1; done

  python3 - qmp.sock <<'EOF'
  import json, socket, sys

  s = socket.socket(socket.AF_UNIX)
  s.connect(sys.argv[1])
  f = s.makefile("rw")

  def call(cmd):
      f.write(json.dumps({"execute": cmd}) + "\n")
      f.flush()
      while True:
          msg = json.loads(f.readline())
          if "return" in msg:
              return msg["return"]
          if "error" in msg:
              sys.exit(f"{cmd}: {msg['error']}")

  json.loads(f.readline())  # greeting
  call("qmp_capabilities")

  status = call("query-status")["status"]
  print("status:", status)
  assert status == "running", status

  # PCI device ids: 0x1001 blk, 0x1000 net, 0x1005 rng, 0x1003 console,
  # 0x105a virtio-fs (modern-only, so 0x1040 + 26).
  found = []
  for bus in call("query-pci"):
      for dev in bus["devices"]:
          found.append(dev["id"]["device"])
  want = {0x1001: 3, 0x1000: 1, 0x1005: 1, 0x1003: 1, 0x105A: 1}
  for dev_id, count in want.items():
      have = found.count(dev_id)
      print(f"device {dev_id:#x}: {have}")
      assert have >= count, f"expected {count} of {dev_id:#x}, found {have}"

  call("quit")
  EOF

  wait $qemu || true
  grep -q "Client connected" virtiofsd.log || {
    cat virtiofsd.log >&2
    exit 1
  }
  touch $out
''
