{ inputs, self, ... }:

{
  perSystem = { pkgs, lib, ... }:
    let
      project = pkgs.haskell-nix.cabalProject' ({ config, pkgs, ... }: {
        src = pkgs.haskell-nix.haskellLib.cleanSourceWith {
          name = "kupo-src";
          src = self;
          # Filter out package.yaml files so plan-to-nix uses the
          # pre-generated .cabal files instead. The package.yaml files
          # `!include` .hpack.config.yaml via relative paths that the
          # haskell.nix sandbox can't always resolve.
          filter = path: type:
            builtins.all (x: x) [
              (baseNameOf path != "package.yaml")
            ];
        };
        name = "kupo";
        compiler-nix-name = lib.mkDefault "ghc984";

        inputMap = {
          "https://input-output-hk.github.io/cardano-haskell-packages" = inputs.CHaP;
        };

        # Mirrors source-repository-package entries in cabal.project so
        # haskell.nix can fetch them deterministically.
        sha256map = {
          "https://github.com/CardanoSolutions/ogmios"."ae876badb138f42dcd6d2389734b0c15502684ed" = "sha256-xkOfOdX6Dxi7+VW78Tk3n3MoguIg39pKdxiNVfdeEwE=";
          "https://github.com/CardanoSolutions/sqlite-simple"."08015be2ee52a7e67159b6b0c476bd3e0a2e0b87" = "1ahpjycsfibv09kzgfbm4i55z4nz1p3rvnmfwwwraxy45n1ivl85";
          "https://github.com/CardanoSolutions/direct-sqlite"."2b14a78cb73805e2e5d84354230e872a223faa39" = "1lwaariy0zjjh006ll1zbpdi9sphyqmcbbxhb0rj99nii5s91fd7";
          "https://github.com/CardanoSolutions/text-ansi"."e204822d2f343b2d393170a2ec46ee935571345c" = "16ki7wsf7wivxn65acv4hxwfrzmphq4zp61lpxwzqkgrg8shi8bv";
        };

        modules = [
          {
            doHaddock = false;
            packages.kupo.ghcOptions = [ "-Werror" ];
            # GHC 9.8 enabled -Wx-partial by default; kupo was written for
            # 9.6 and uses `Prelude.head` in a handful of test spots.
            # Silence it under -Werror until the source is updated.
            packages.kupo.components.tests.unit.ghcOptions = [ "-Wno-x-partial" ];

            # Tests use relative paths like `./test/vectors/...` and
            # `./config/network/.../config.json`. The default test runCommand
            # CWD is empty, so populate it with the vectors tree and the
            # cardano-configurations submodule before invoking the binary.
            packages.kupo.components.tests.unit.preCheck = ''
              cp -r ${self}/test/vectors ./test/vectors
              cp -r ${self}/config ./config
            '';
          }
          ({ pkgs, ... }: {
            # Use the VRF fork of libsodium
            packages = {
              cardano-crypto-praos.components.library.pkgconfig = pkgs.lib.mkForce [
                [ pkgs.libsodium-vrf ]
              ];
              cardano-crypto-class.components.library.pkgconfig = pkgs.lib.mkForce [
                [ pkgs.libsodium-vrf pkgs.secp256k1 pkgs.libblst ]
              ];
            };
          })
        ];
      });
    in
    {
      _module.args.hsPkgs = project.hsPkgs;
      _module.args.shellFor = args: project.shellFor args;
    };
}
