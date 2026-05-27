{
  perSystem = { hsPkgs, ... }:
    let
      kupo = hsPkgs.kupo;
    in
    {
      packages.kupo = kupo.components.library;
      packages.kupo-exe = kupo.components.exes.kupo;
      checks.kupo-unit = kupo.checks.unit;
    };
}
