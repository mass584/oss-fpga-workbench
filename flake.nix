{
  description = "OSS FPGA development environment (Gowin / Lattice, macOS & Linux)";

  inputs = {
    # All tool versions are pinned by flake.lock. Update with `make update`.
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (pkgs:
        let
          inherit (pkgs) lib;
          # Optional tools are only added where nixpkgs supports the platform.
          optional = p: lib.optional (lib.meta.availableOn pkgs.stdenv.hostPlatform p) p;
          # Apicula 0.33: gowin_pack crashes (UnboundLocalError: offx) when the left rPLL of
          # GW1N-9C is used, i.e. any design with two PLLs on Tang Nano 9K. Local fix until upstream.
          apycula = pkgs.python3Packages.apycula.overridePythonAttrs (old: {
            patches = (old.patches or [ ]) ++ [ ./nix/apycula-pll-offx.patch ];
          });
        in
        {
          default = pkgs.mkShell {
            packages = [
              # --- simulation / lint ---
              pkgs.iverilog # Verilog simulator (iverilog / vvp)
              pkgs.verilator # fast lint (--lint-only) and C++ simulation
              # --- synthesis / place & route / bitstream ---
              pkgs.yosys # synthesis (synth_gowin, synth_ice40, synth_ecp5, ...)
              pkgs.nextpnr # nextpnr-himbaechel (gowin), nextpnr-ice40, nextpnr-ecp5, ...
              apycula # Gowin bitstream DB + gowin_pack / gowin_unpack (patched, see above)
              pkgs.icestorm # Lattice iCE40 packer (icepack) for other boards
              pkgs.trellis # Lattice ECP5 packer (ecppack) for other boards
              # --- programming ---
              pkgs.openfpgaloader # JTAG/SPI programmer (Tang Nano, iCEBreaker, ULX3S, ...)
              # --- build ---
              pkgs.gnumake
            ]
            # --- waveform viewers ---
            ++ optional pkgs.gtkwave
            ++ optional pkgs.surfer;

            shellHook = ''
              export FPGA_ENV=nix
            '';
          };
        });
    };
}
