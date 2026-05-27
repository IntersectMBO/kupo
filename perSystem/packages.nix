{
  perSystem = { hsPkgs, ... }:
    let
      kupo = hsPkgs.kupo;
    in
    {
      packages = {
        default = kupo.components.exes.kupo;
        kupo = kupo.components.exes.kupo;
        kupo-lib = kupo.components.library;
      };

      checks.kupo-unit = kupo.checks.unit;
    };
}
