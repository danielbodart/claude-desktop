self:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.claude-desktop;

  # OVMF for x86_64, AAVMF for aarch64. Both come out of the same nixpkgs
  # attribute; only the file name differs.
  firmware =
    if pkgs.stdenv.hostPlatform.isAarch64 then
      {
        path = "/usr/share/AAVMF/AAVMF_CODE.fd";
        file = "${pkgs.OVMF.firmware}";
      }
    else
      {
        path = "/usr/share/OVMF/OVMF_CODE_4M.fd";
        file = "${pkgs.OVMF.firmware}";
      };
in
{
  options.programs.claude-desktop = {
    enable = lib.mkEnableOption "Claude Desktop";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.claude-desktop;
      defaultText = lib.literalMD "`claude-desktop` from this flake";
      description = "The claude-desktop package to install.";
    };

    cowork = {
      enable = lib.mkEnableOption ''
        the system side of Cowork, which runs agentic sessions in a QEMU
        virtual machine. The application finds QEMU on its own PATH, but it
        looks for UEFI firmware at a fixed FHS path and needs KVM access,
        neither of which a package can arrange for itself
      '';

      users = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "alice" ];
        description = ''
          Users to add to the `kvm` group. Cowork needs `/dev/vhost-vsock` as
          well as `/dev/kvm`, and only `kvm` group members can open it, so
          this is required even where `/dev/kvm` is already world-accessible.
          Members must log out and back in for it to take effect.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        environment.systemPackages = [ cfg.package ];

        # The app stores account credentials in the login keyring.
        services.gnome.gnome-keyring.enable = lib.mkDefault true;
      }

      (lib.mkIf cfg.cowork.enable {
        boot.kernelModules = [
          "kvm"
          "vhost_vsock"
        ];

        # Cowork resolves QEMU through PATH but hardcodes the firmware location,
        # so the one FHS path it insists on is linked into place. The bundled
        # virtiofsd needs no help: the app falls back to its own copy under
        # resources/ when the system has none.
        systemd.tmpfiles.rules = [
          "L+ ${firmware.path} - - - - ${firmware.file}"
        ];

        users.users = lib.genAttrs cfg.cowork.users (_: {
          extraGroups = [ "kvm" ];
        });
      })
    ]
  );
}
