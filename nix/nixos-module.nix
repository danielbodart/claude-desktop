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
  # attribute; only the file name differs. The app finds the variable store
  # template by replacing CODE with VARS in the code path, so both are linked.
  firmware =
    if pkgs.stdenv.hostPlatform.isAarch64 then
      {
        code = "/usr/share/AAVMF/AAVMF_CODE.fd";
        vars = "/usr/share/AAVMF/AAVMF_VARS.fd";
      }
    else
      {
        code = "/usr/share/OVMF/OVMF_CODE_4M.fd";
        vars = "/usr/share/OVMF/OVMF_VARS_4M.fd";
      };

  gnome = config.services.desktopManager.gnome.enable;
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

    gnomeSearchProvider = lib.mkOption {
      type = lib.types.bool;
      default = gnome && cfg.package ? searchProvider;
      defaultText = lib.literalExpression "config.services.desktopManager.gnome.enable";
      description = ''
        Whether to register Claude as a GNOME Shell search provider. The
        provider is a separate output of the package, because it is a GJS
        script and GJS is only worth its closure where GNOME already has it.
      '';
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

      (lib.mkIf cfg.gnomeSearchProvider {
        environment.systemPackages = [ cfg.package.searchProvider ];
        services.dbus.packages = [ cfg.package.searchProvider ];
      })

      (lib.mkIf cfg.cowork.enable {
        boot.kernelModules = [
          "kvm"
          "vhost_vsock"
        ];

        # Cowork resolves QEMU through PATH but hardcodes the firmware and
        # virtiofsd locations, so the FHS paths it insists on are linked into
        # place. It only falls back to its bundled virtiofsd on Ubuntu 22.04;
        # anywhere else it reports Cowork unsupported without a system one.
        # The bundled copy is the one Anthropic ships and tests, so that is
        # what gets linked.
        systemd.tmpfiles.rules = [
          "L+ ${firmware.code} - - - - ${pkgs.OVMF.firmware}"
          "L+ ${firmware.vars} - - - - ${pkgs.OVMF.variables}"
          "L+ /usr/libexec/virtiofsd - - - - ${cfg.package}/lib/claude-desktop/resources/virtiofsd"
        ];

        users.users = lib.genAttrs cfg.cowork.users (_: {
          extraGroups = [ "kvm" ];
        });
      })
    ]
  );
}
