# claude-desktop

A Nix flake for the **official** Claude Desktop application on Linux.

Anthropic ships a real Linux build now: a signed `.deb` in an apt repository at
`downloads.claude.ai`, currently in beta, for amd64 and arm64. This flake
repackages that `.deb` for NixOS and Nix on other distributions, and keeps the
pin current automatically.

```nix
{
  inputs.claude-desktop.url = "github:danielbodart/claude-desktop";
}
```

## Why another one

Most of the Claude Desktop flakes in the wild predate the official Linux
release. They unpack the Windows installer, pull the app's resources out of an
NSIS archive, and rebuild them against a nixpkgs Electron. That was the only
option at the time. It is not the option any more, and it means running an
application in a configuration its vendor never built or tested.

The rest hardcode a `.deb` URL and a hash that someone bumps by hand when they
notice a new version. That works until the person stops noticing.

This one:

- **Packages what Anthropic ships.** The upstream `.deb`, with its own Electron
  runtime, patched only where a store path differs from an FHS one.
- **Pins to a signature, not to a download.** The version and hashes in
  `sources.json` are read out of the repository's PGP-signed index, so what is
  pinned is what Anthropic attested to. See [Provenance](#provenance).
- **Updates itself hourly**, and only lands a version that has been built and
  launched on both x86\_64 and aarch64 first.
- **Tags every release**, so `github:danielbodart/claude-desktop/v1.49585.0`
  pins one exactly.
- **Makes Cowork work.** Cowork runs agentic sessions in a QEMU virtual machine
  and expects UEFI firmware at a fixed FHS path. The NixOS module puts it
  there.
- **Keeps the closure small.** Under 900 MiB with Cowork included, against
  2.8 GiB with nixpkgs' default QEMU. See [Closure](#closure).

## Install

### NixOS

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    claude-desktop.url = "github:danielbodart/claude-desktop";
  };

  outputs = { nixpkgs, claude-desktop, ... }: {
    nixosConfigurations.yourhost = nixpkgs.lib.nixosSystem {
      modules = [
        claude-desktop.nixosModules.default
        {
          programs.claude-desktop = {
            enable = true;
            cowork = {
              enable = true;
              users = [ "yourusername" ];
            };
          };
        }
      ];
    };
  };
}
```

Members of `cowork.users` are added to the `kvm` group and have to log out and
back in once for it to take effect.

### Home Manager, or any other profile

```nix
home.packages = [ inputs.claude-desktop.packages.${pkgs.system}.default ];
```

The package is unfree, so `nixpkgs.config.allowUnfree` has to permit it. This
flake's own outputs set that for themselves; taking the overlay instead uses
your nixpkgs configuration.

### Try it without installing

```bash
nix run github:danielbodart/claude-desktop
```

## Provenance

The chain from Anthropic's signing key to the hash Nix checks has no
unauthenticated link in it:

| Step | Verified by |
| --- | --- |
| `anthropic-archive-keyring.asc` in this repository | Fingerprint `31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE`, asserted by `scripts/update.sh` |
| `dists/stable/InRelease` | PGP signature, checked with `gpgv` against that key |
| `main/binary-$arch/Packages` | SHA256 listed in the signed `InRelease` |
| `pool/.../claude-desktop_*.deb` | SHA256 listed in `Packages`, recorded in `sources.json` |
| The bytes Nix downloads | The hash in `sources.json`, checked by `fetchurl` |

`scripts/update.sh` never downloads the `.deb`. It reads the hash out of the
signed index and writes it down, and Nix checks the download against it at
build time. So the pin is a claim Anthropic signed, not a fingerprint of
whatever the updater happened to receive.

Continuous integration re-derives `sources.json` on every pull request and
fails if a hand-edited file disagrees with the signed index at the same
version.

The fingerprint above is the one in Anthropic's own
[install instructions](https://code.claude.com/docs/en/desktop-linux). Check it
against those before trusting this repository.

## How updates work

An hourly job checks the repository index. When it finds a newer version it
regenerates `sources.json`, then builds the package and runs it on both
`x86_64-linux` and `aarch64-linux` runners. Only if both succeed does the
commit reach `trunk`, followed by a `v<version>` tag and a GitHub release.

This pushes to `trunk` rather than opening a pull request on purpose. A pull
request raised with the default token does not trigger workflows, so an
auto-merged one would land without ever having been built.

Nothing about this changes when you pin a tag. `nix flake update` is still the
only thing that moves your version.

## What is packaged

The `.deb` contents, at their original layout under `lib/claude-desktop`, which
the app depends on to find its virtual machine image and helper binaries
relative to itself. On top of that:

- `autoPatchelfHook` over every ELF in the tree, including the bundled
  `virtiofsd`, the Cowork helper and the native Node modules.
- The setuid `chrome-sandbox` helper dropped, since a store path can never be
  setuid. Chromium falls back to the unprivileged user namespace sandbox, which
  NixOS enables by default.
- The desktop entry and both of its actions pointed at the wrapper's store
  path.
- The GNOME Shell search provider registered, with its D-Bus service rewritten
  to the store's `gjs`, in a separate `searchProvider` output. This is what
  `postinst` does on Debian.
- Wayland enabled when `NIXOS_OZONE_WL` is set.

## Closure

| Path | Closure |
| --- | --- |
| `claude-desktop` | 899 MiB |
| `claude-desktop.searchProvider` | +94 MiB (GJS; nothing extra where GNOME is installed) |
| `claude-desktop.override { withCowork = false; }` | 820 MiB |

What keeps it there:

- **A QEMU cut down to what Cowork uses.** The Cowork helper only ever runs a
  headless `qemu-system-<host arch>` with a fixed set of virtio devices.
  `nix/qemu-cowork.nix` builds exactly that: one CPU target, no display,
  audio, USB, smartcard or TPM backends, no edk2 images. It is 45 MiB against
  nixpkgs' default QEMU at about 1.7 GiB with its dependencies. It is not on
  `cache.nixos.org`, so CI builds it and pushes it to the
  [binary cache](#binary-cache).
- **`systemdLibs` rather than systemd.** Electron only wants `libudev` and
  `libsystemd`.
- **GIO instead of xdg-utils.** Electron runs `xdg-open`, `xdg-email`,
  `xdg-settings` and `xdg-mime` for links and the `claude://` handler.
  `nix/xdg-shims.nix` answers those from GIO, which GTK already brings, rather
  than pulling perl in for xdg-utils. They come last on `PATH`, so a real
  xdg-utils wins where there is one.
- **The search provider and Chromium's 20 MiB license file in their own
  outputs** (`searchProvider` and `doc`), which a profile installs only when
  asked.

`nix flake check` fails if full QEMU, systemd, perl, python, GJS or xdg-utils
reappear in the closure, or if it grows past 1000 MiB. It also boots the
Cowork machine shape under TCG and checks over QMP that every device came up.

### Options

```nix
claude-desktop.override {
  withCowork = false;              # no QEMU and no VM payload
  withGnomeSearchProvider = false; # no searchProvider output at all
  qemu-cowork = pkgs.qemu_kvm;     # a cached QEMU instead, at about 1.3 GiB more
}
```

## Cowork

Cowork runs longer agentic work in a QEMU virtual machine the app starts
itself. Four things have to be true, and only one of them can be arranged by a
package:

1. **QEMU on `PATH`.** The wrapper does this, unless `withCowork = false`.
2. **UEFI firmware at `/usr/share/OVMF/OVMF_CODE_4M.fd`**, and its variable
   store template beside it as `OVMF_VARS_4M.fd` (`AAVMF_*` on arm64). The app
   hardcodes those paths with no fallback. `programs.claude-desktop.cowork.enable`
   links the store's OVMF there with tmpfiles rules.
3. **`virtiofsd` at `/usr/libexec/virtiofsd` or `/usr/bin/virtiofsd`.** The
   app only falls back to the copy it bundles on Ubuntu 22.04, and otherwise
   reports Cowork as needing QEMU. The module links the bundled copy there.
4. **Access to `/dev/kvm` and `/dev/vhost-vsock`.** Only `kvm` group members
   can open the second one, so joining the group is required even where
   `/dev/kvm` is already accessible.

Off NixOS, arrange 2 to 4 yourself.

## GNOME search

The NixOS module registers the search provider whenever
`services.desktopManager.gnome.enable` is set; `programs.claude-desktop.gnomeSearchProvider`
overrides that. Elsewhere, install the output alongside the app:

```nix
home.packages = with inputs.claude-desktop.packages.${pkgs.system}; [
  claude-desktop
  claude-desktop.searchProvider
];
```

## Development

```bash
nix develop              # curl, gnupg, jq, dpkg, shellcheck, nixfmt
nix flake check          # builds the package, runs shellcheck, checks the pin
./scripts/update.sh      # regenerate sources.json
./scripts/update.sh --check   # exit non-zero if a newer version exists
./scripts/update.sh --force   # rewrite even when already current
```

## Binary cache

CI pushes both architectures to `https://danielbodart.cachix.org`, so you can
substitute the build instead of downloading a 170 MB `.deb` and patching it
yourself.

The flake offers the cache through `nixConfig`, which Nix applies only if you
are a trusted user and otherwise reports as ignored. On NixOS the reliable
place to put it is your own configuration:

```nix
nix.settings = {
  substituters = [ "https://danielbodart.cachix.org" ];
  trusted-public-keys = [
    "danielbodart.cachix.org-1:751qv4GxLFJCThWMEw1WL6kUqY0DpF6oqPqsLKnnEwU="
  ];
};
```

Everything else in the closure comes from `cache.nixos.org` as usual. Only the
Claude Desktop outputs and the trimmed `qemu-cowork` are unique to this cache.

The cache serves the `qemu-cowork` built against this flake's nixpkgs. If you
make the input follow your own nixpkgs, Nix builds QEMU locally instead, which
takes a few minutes.

## Not covered

Anthropic lists these as missing from the Linux beta: Computer Use, dictation,
and the Quick Entry global hotkey on native Wayland. Nothing here can add them.

## License

The packaging in this repository is MIT. Claude Desktop itself is proprietary
and covered by [Anthropic's Consumer Terms](https://www.anthropic.com/legal/consumer-terms).
This repository redistributes no Anthropic binaries; it records where to fetch
them and what they should hash to.
