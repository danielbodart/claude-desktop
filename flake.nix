{
  description = "Claude Desktop for Linux, pinned to Anthropic's signed apt repository";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      # Anthropic publishes claude-desktop for amd64 and arm64 Linux only.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems = nixpkgs.lib.genAttrs systems;

      # The upstream binary is proprietary, so the flake enables unfree for its
      # own outputs. Consumers who take the overlay instead get their own
      # nixpkgs config, and will need allowUnfree set there.
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

      overlay = final: prev: {
        claude-desktop = final.callPackage ./package.nix { };
      };
    in
    {
      overlays.default = overlay;

      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          claude-desktop = pkgs.callPackage ./package.nix { };
        in
        {
          inherit claude-desktop;
          default = claude-desktop;
          claude-desktop-minimal = claude-desktop.override {
            withCowork = false;
            withGnomeSearchProvider = false;
          };
        }
      );

      apps = forAllSystems (system: {
        default = self.apps.${system}.claude-desktop;
        claude-desktop = {
          type = "app";
          program = nixpkgs.lib.getExe self.packages.${system}.claude-desktop;
          meta.description = "Launch Claude Desktop";
        };
      });

      nixosModules.default = import ./nix/nixos-module.nix self;

      # `nix flake check` builds these. The package build is the real test:
      # autoPatchelfHook fails the build on any unresolved shared library, so
      # a green check means every dependency Electron links is present.
      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          inherit (self.packages.${system}) claude-desktop claude-desktop-minimal;

          # The version in sources.json has to be the version inside the
          # archive, otherwise the flake is pinning a label rather than a
          # release. The .deb's own version string comes from the same build
          # metadata, so this compares against the app's package.json.
          version-matches-package =
            pkgs.runCommand "claude-desktop-version-matches-package"
              {
                nativeBuildInputs = [
                  pkgs.asar
                  pkgs.jq
                ];
              }
              ''
                expected="${self.packages.${system}.claude-desktop.version}"
                # `asar extract-file` writes the file into the working directory
                # rather than to stdout.
                asar extract-file \
                  ${self.packages.${system}.claude-desktop}/lib/claude-desktop/resources/app.asar \
                  package.json
                actual="$(jq -r .version package.json)"
                if [ "$expected" != "$actual" ]; then
                  echo "sources.json says $expected, the packaged app is $actual" >&2
                  exit 1
                fi
                echo "claude-desktop $actual" >$out
              '';

          # Evaluation only, not a build: enough to catch an option this module
          # sets that nixpkgs has since renamed or removed, or an assertion the
          # combination trips, without standing up a whole system.
          #
          # unsafeDiscardStringContext is what keeps it that way. Interpolating
          # a drvPath with its context intact makes the toplevel an input of
          # this derivation, and `nix flake check` would go and build a NixOS
          # system.
          nixos-module = pkgs.runCommand "claude-desktop-nixos-module" { } ''
            echo ${
              builtins.unsafeDiscardStringContext
                (nixpkgs.lib.nixosSystem {
                  modules = [
                    self.nixosModules.default
                    {
                      nixpkgs.hostPlatform = system;
                      boot.loader.grub.devices = [ "/dev/null" ];
                      fileSystems."/" = {
                        device = "/dev/null";
                        fsType = "ext4";
                      };
                      system.stateVersion = "26.05";
                      users.users.tester.isNormalUser = true;
                      programs.claude-desktop = {
                        enable = true;
                        cowork = {
                          enable = true;
                          users = [ "tester" ];
                        };
                      };
                    }
                  ];
                }).config.system.build.toplevel.drvPath
            } >$out
          '';

          shellcheck =
            pkgs.runCommand "claude-desktop-shellcheck" { nativeBuildInputs = [ pkgs.shellcheck ]; }
              ''
                shellcheck ${./scripts/update.sh}
                touch $out
              '';
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              curl
              dpkg
              gnupg
              jq
              nixfmt
              shellcheck
            ];
          };
        }
      );

      formatter = forAllSystems (system: (pkgsFor system).nixfmt);
    };
}
