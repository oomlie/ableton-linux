{
  description = ''
    Ableton Live 12 on patched Wine (ableton-linux) for NixOS.

    NixOS isn't FHS-compliant, so the prebuilt Wine tree this project ships
    (a normal glibc/Ubuntu-22.04-linked ELF tree) can't run directly. This
    flake provides:

      - `devShells.default`  — host tools needed to *build* the patched Wine
        tarball via ./build.sh (podman/docker still does the actual compile
        inside its own Ubuntu 22.04 container, so NixOS's non-FHS layout
        doesn't matter there).

      - `apps.fhs` / `packages.fhs` — an FHS-compatible sandbox (via
        buildFHSEnv) carrying every runtime library the patched Wine build,
        WineASIO, and the XDG file-dialog portal need, so `./scripts/install.sh`,
        `./scripts/setup-prefix.sh` and `ableton-live` run unmodified inside it.
  '';

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    (flake-utils.lib.eachSystem [ "x86_64-linux" ] (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        # `nix develop` — build-side tooling for ./build.sh, ./scripts/make-installer.sh,
        # and the Makefile's verify/vendor-cache targets. Does NOT include podman/docker:
        # rootless container engines need subuid/subgid + cgroup wiring that belongs in
        # NixOS system config (`virtualisation.podman.enable = true`), not a devShell.
        devShells.default = pkgs.mkShellNoCC {
          name = "ableton-linux-build";
          packages = with pkgs; [
            zstd
            cabextract
            binutils
            git
            gnumake
          ];
          shellHook = ''
            if ! command -v podman >/dev/null && ! command -v docker >/dev/null; then
              echo "note: no podman/docker on PATH — enable one via NixOS config," >&2
              echo "      e.g. virtualisation.podman.enable = true;" >&2
            fi
          '';
        };

        # `nix run .#fhs` — drops you into a shell with the FHS layout + libraries
        # the patched Wine tree (and its bundled WineASIO/libusb/portal builtins)
        # expect to dlopen at runtime. Run the project's own scripts inside it:
        #   ./scripts/install.sh && ./scripts/setup-prefix.sh && ableton-live
        packages.fhs = pkgs.buildFHSEnv {
          name = "ableton-live-fhs";
          targetPkgs = pkgs: with pkgs; [
            # X11 windowing (winex11.drv)
            xorg.libX11
            xorg.libXext
            xorg.libXrandr
            xorg.libXrender
            xorg.libXi
            xorg.libXfixes
            xorg.libXcursor
            xorg.libXcomposite
            xorg.libXinerama
            xorg.libXxf86vm
            libxkbcommon

            # GL / Vulkan (VST3/JUCE/OpenGL editor windows, wined3d)
            libGL
            libglvnd
            vulkan-loader
            mesa

            # fonts (Live UI, plugin editors)
            freetype
            fontconfig

            # audio: ALSA MIDI (winealsa.drv), PulseAudio, WineASIO -> JACK/PipeWire
            alsa-lib
            libpulseaudio
            pipewire
            pipewire.jack

            # TLS (Live online auth/pack downloads), Push 2 USB bridge, session bus
            gnutls
            libusb1
            dbus

            # native file dialogs (comdlg32 XDG portal patch)
            xdg-desktop-portal
            xdg-desktop-portal-gtk
            glib
            gsettings-desktop-schemas
            desktop-file-utils

            # host tools install.sh / setup-prefix.sh / ableton-live shell out to
            cabextract
            zstd
            binutils
            procps # pgrep
            util-linux # chrt
            curl
          ];
          runScript = "bash";
        };

        apps.fhs = {
          type = "app";
          program = "${self.packages.${system}.fhs}/bin/ableton-live-fhs";
        };
      }))
    // {
      # `imports = [ inputs.ableton-linux.nixosModules.default ];` then
      # `programs.ableton-linux.enable = true;` — bundles the system-level
      # toggles the README's manual NixOS instructions used to ask for by hand.
      nixosModules.default = { config, lib, ... }:
        with lib;
        let
          cfg = config.programs.ableton-linux;
        in
        {
          options.programs.ableton-linux = {
            enable = mkEnableOption "system-level toggles for Ableton Live 12 on patched Wine";

            containerEngine = mkOption {
              type = types.nullOr (types.enum [ "podman" "docker" ]);
              default = null;
              description = ''
                Enable a container engine for building the patched Wine tree via
                ./build.sh. Leave null (the default) if you only install prebuilt
                release tarballs and never build from source.
              '';
            };

            realtimeAudio.enable = mkOption {
              type = types.bool;
              default = true;
              description = ''
                Grant the `audio` group elevated rtprio/memlock/nice PAM limits so
                the launcher's `chrt -r 10 wine` succeeds instead of silently
                falling back to non-realtime scheduling. Inert unless your user is
                actually in the `audio` group.
              '';
            };
          };

          config = mkIf cfg.enable (mkMerge [
            {
              # WineASIO -> JACK/PipeWire; the runtime library itself is provided
              # by packages.fhs, this is what makes the JACK server side exist.
              services.pipewire.enable = mkDefault true;
              services.pipewire.jack.enable = mkDefault true;
            }
            (mkIf (cfg.containerEngine == "podman") {
              virtualisation.podman.enable = mkDefault true;
            })
            (mkIf (cfg.containerEngine == "docker") {
              virtualisation.docker.enable = mkDefault true;
            })
            (mkIf cfg.realtimeAudio.enable {
              security.pam.loginLimits = [
                { domain = "@audio"; item = "rtprio"; type = "-"; value = "99"; }
                { domain = "@audio"; item = "memlock"; type = "-"; value = "unlimited"; }
                { domain = "@audio"; item = "nice"; type = "-"; value = "-19"; }
              ];
            })
          ]);
        };
    };
}
