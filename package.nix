{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  dpkg,
  makeShellWrapper,
  wrapGAppsHook3,
  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  atk,
  cairo,
  cups,
  dbus,
  expat,
  fontconfig,
  freetype,
  gdk-pixbuf,
  glib,
  gtk3,
  libcap_ng,
  libdrm,
  libgbm,
  libGL,
  libglvnd,
  libnotify,
  libseccomp,
  libsecret,
  libx11,
  libxcb,
  libxcomposite,
  libxdamage,
  libxext,
  libxfixes,
  libxkbcommon,
  libxkbfile,
  libxrandr,
  libxshmfence,
  libxtst,
  nspr,
  nss,
  pango,
  systemdLibs,
  util-linux,
  vulkan-loader,
  gjs,
  callPackage,
  # Cowork runs agentic sessions in a QEMU/KVM virtual machine that the app
  # starts itself, looking for `qemu-system-*` on PATH. The wrapper puts a
  # headless, host-only QEMU there (nix/qemu-cowork.nix), so it works out of
  # the box the way `apt install claude-desktop` does. Set to false for a
  # chat-and-code-only build, which also drops the VM payload.
  withCowork ? true,
  qemu-cowork ? callPackage ./nix/qemu-cowork.nix { },
  xdg-shims ? callPackage ./nix/xdg-shims.nix { },
  # The GNOME Shell search provider is a GJS script the shell activates over
  # D-Bus. It lives in its own `searchProvider` output, so GJS is only in the
  # closure of those who install that output.
  withGnomeSearchProvider ? true,
  sources ? lib.importJSON ./sources.json,
}:

let
  source =
    sources.sources.${stdenv.hostPlatform.system}
      or (throw "claude-desktop has no Linux package for ${stdenv.hostPlatform.system}; Anthropic publishes amd64 and arm64 only");

  # Where the .deb puts everything, and where we keep it. Preserving the
  # layout under $out matters: the app resolves its virtual machine image,
  # virtiofsd and Cowork helper relative to `process.resourcesPath`.
  appDir = "lib/claude-desktop";
in
stdenv.mkDerivation (finalAttrs: {
  pname = "claude-desktop";
  version = sources.version;

  outputs = [
    "out"
    "doc"
  ]
  ++ lib.optional withGnomeSearchProvider "searchProvider";

  src = fetchurl {
    inherit (source) url hash;
  };

  nativeBuildInputs = [
    autoPatchelfHook
    dpkg
    makeShellWrapper
    wrapGAppsHook3
  ];

  buildInputs = [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    atk
    cairo
    cups
    dbus
    expat
    fontconfig
    freetype
    gdk-pixbuf
    glib
    gtk3
    libdrm
    libgbm
    libGL
    libnotify
    libsecret
    libx11
    libxcb
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxkbcommon
    libxkbfile
    libxrandr
    libxshmfence
    libxtst
    nspr
    nss
    pango
    # libudev and libsystemd only; `lib.getLib systemd` is the whole of
    # systemd, since it has no separate lib output.
    systemdLibs
    util-linux
  ]
  # Wanted by the virtiofsd that Cowork falls back to when the host has none
  # of its own.
  ++ lib.optionals withCowork [
    libcap_ng
    libseccomp
  ];

  # Loaded with dlopen at runtime rather than linked, so autoPatchelfHook
  # cannot see the need for them from the ELF headers.
  runtimeDependencies = [
    systemdLibs
    libglvnd
    libnotify
    libsecret
    vulkan-loader
  ];

  # `dpkg-deb --extract` restores permissions, and the archive's setuid
  # chrome-sandbox cannot be created inside the build sandbox. That helper is
  # unusable from a store path anyway -- it only works setuid root -- and
  # leaving it out makes Chromium fall back to the unprivileged user namespace
  # sandbox instead of aborting with a misconfiguration error.
  unpackPhase = ''
    runHook preUnpack

    dpkg-deb --fsys-tarfile "$src" |
      tar --extract --no-same-permissions --no-same-owner \
        --exclude=./usr/lib/claude-desktop/chrome-sandbox

    runHook postUnpack
  '';

  # Electron ships a prebuilt Chromium whose asar archive and V8 snapshots are
  # checked against their own offsets; rewriting the binary breaks it.
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/${appDir}" "$out/bin" "$out/share"
    cp -r usr/${appDir}/. "$out/${appDir}/"
    cp -r usr/share/icons "$out/share/icons"

    # 20 MiB of HTML nothing reads at runtime.
    mkdir -p "$doc/share/doc/claude-desktop"
    mv "$out/${appDir}/LICENSES.chromium.html" "$doc/share/doc/claude-desktop/"
  ''
  + lib.optionalString (!withCowork) ''
    # The VM disk, virtiofsd and helper are dead weight without QEMU.
    rm "$out/${appDir}/resources/smol-bin."*.img \
      "$out/${appDir}/resources/virtiofsd" \
      "$out/${appDir}/resources/cowork-linux-helper"
  ''
  + ''

    # The bare `claude-desktop` in Exec= resolves against a Debian $PATH.
    # Point the entry and both of its actions at the wrapper instead, so a
    # launcher finds the app without the profile having to be on PATH.
    install -Dm644 usr/share/applications/com.anthropic.Claude.desktop \
      "$out/share/applications/com.anthropic.Claude.desktop"

    substituteInPlace "$out/share/applications/com.anthropic.Claude.desktop" \
      --replace-fail "Exec=claude-desktop" "Exec=$out/bin/claude-desktop"

    runHook postInstall
  '';

  postFixup = ''
    makeShellWrapper "$out/${appDir}/claude-desktop" "$out/bin/claude-desktop" \
      "''${gappsWrapperArgs[@]}" \
      ${lib.optionalString withCowork "--prefix PATH : ${lib.makeBinPath [ qemu-cowork ]}"} \
      --suffix PATH : ${lib.makeBinPath [ xdg-shims ]} \
      --prefix LD_LIBRARY_PATH : ${
        lib.makeLibraryPath [
          libglvnd
          vulkan-loader
        ]
      } \
      --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations}}"
  ''
  + lib.optionalString withGnomeSearchProvider ''
    # dpkg's postinst copies these two files into place and rewrites nothing,
    # because on Debian the paths it names already exist. Here the D-Bus
    # service has to point into the store instead. Both go in their own
    # output, so the reference to GJS stays out of the main closure.
    providerScripts="$out/${appDir}/resources/gnome-search-provider"

    install -Dm644 "$providerScripts/com.anthropic.Claude.search-provider.ini" \
      "$searchProvider/share/gnome-shell/search-providers/com.anthropic.Claude.search-provider.ini"

    install -Dm644 "$providerScripts/com.anthropic.Claude.SearchProvider.service" \
      "$searchProvider/share/dbus-1/services/com.anthropic.Claude.SearchProvider.service"

    substituteInPlace "$searchProvider/share/dbus-1/services/com.anthropic.Claude.SearchProvider.service" \
      --replace-fail "/usr/bin/gjs" "${lib.getExe' gjs "gjs"}" \
      --replace-fail "/usr/lib/claude-desktop/resources/gnome-search-provider" "$providerScripts"
  '';

  # wrapGAppsHook3 would otherwise wrap the Electron binary directly, and the
  # wrapper it writes replaces argv[0] with a path Chromium then re-execs for
  # its zygote processes.
  dontWrapGApps = true;

  passthru = {
    inherit (source) url;
    inherit qemu-cowork;
    updateScript = ./scripts/update.sh;
  };

  meta = {
    description = "Desktop application for Claude, packaged from Anthropic's apt repository";
    longDescription = ''
      The official Claude desktop application for Linux, currently in beta.
      Chat, Cowork and Claude Code in one window, with parallel sessions,
      visual diff review, an integrated terminal and editor, and live app
      preview.

      Repackaged from the .deb Anthropic publishes at downloads.claude.ai,
      pinned to a hash taken from that repository's PGP-signed index.
    '';
    homepage = "https://claude.com/download";
    downloadPage = "https://code.claude.com/docs/en/desktop-linux";
    changelog = "https://code.claude.com/docs/en/changelog";
    license = {
      fullName = "Anthropic Consumer Terms of Service";
      url = "https://www.anthropic.com/legal/consumer-terms";
      free = false;
      redistributable = false;
    };
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    mainProgram = "claude-desktop";
    outputsToInstall = [ "out" ];
  };
})
