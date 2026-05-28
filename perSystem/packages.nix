{
  perSystem = { hsPkgs, ... }:
    let
      kupo = hsPkgs.kupo;
    in
    {
      packages = {
        default = kupo.components.exes.kupo;
        kupo = kupo.components.library;
        kupo-exe = kupo.components.exes.kupo;
      };

      checks.kupo-unit = kupo.checks.unit;
    };
}
