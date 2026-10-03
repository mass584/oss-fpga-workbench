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
              pkgs.python3Packages.apycula # Gowin bitstream DB + gowin_pack / gowin_unpack
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
