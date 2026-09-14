{ lib, package }:
{
  programs.omp = {
    enable = lib.mkEnableOption "the Oh My Pi coding agent";

    package = lib.mkOption {
      type = lib.types.package;
      default = package;
      description = "Oh My Pi package to install.";
    };
  };
}
