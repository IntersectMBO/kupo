{ inputs, ... }: {
  perSystem = { shellFor, pkgs, ... }: {
    devShells.default = shellFor {
      packages = p: [ p.kupo ];

      nativeBuildInputs = [
        pkgs.jq
        pkgs.gh
      ];

      tools = {
        cabal = "latest";
        ghcid = "latest";
        haskell-language-server = {
          src = inputs.haskellNix.inputs."hls-2.10";
          configureArgs = "--disable-benchmarks --disable-tests";
        };
      };

      shellHook = ''
        export LANG="en_US.UTF-8"
        # Warm-case helper: re-sync submodules to whatever the current branch
        # pins (e.g. after upstream bumps a submodule SHA). Does NOT help the
        # cold-start case — if submodules aren't initialized, nix's git fetcher
        # fails on `self.submodules = true` before this hook ever runs. See
        # README "Building from source" for the bootstrap command.
        git submodule update --init --recursive

        # Symlink .claude -> .ai so Claude Code auto-discovers .ai/skills/.
        # Runs on both `nix develop` and direnv (`use flake`). The symlink is
        # gitignored.
        if [ -d .claude ] && [ ! -L .claude ]; then
          echo "WARNING: .claude is a real directory, not a symlink; leaving it as-is." >&2
          echo "  Move its contents into .ai/ and remove .claude to enable .ai/skills auto-discovery." >&2
        else
          ln -sfn .ai .claude
        fi
      '';

      withHoogle = false;
    };
  };
}
