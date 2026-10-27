{ lib, pkgs, ... }:
let
  inherit (lib) mkOption;
  inherit (lib.types) attrsOf package submodule;
  toml = pkgs.formats.toml { };
  hostHooks = submodule {
    options = {
      post-launch = mkOption {
        type = attrsOf lib.types.path;
        default = { };
        description = ''
          Named executable scripts run on the host after launch, rebuild, or
          boot upgrade, in lexical name order. Paths are saved with the instance at launch.
        '';
      };
      post-start = mkOption {
        type = attrsOf lib.types.path;
        default = { };
        description = ''
          Named executable scripts run on the host after SSH readiness on
          launch and start, in lexical name order. On launch, these run after
          post-launch hooks. Paths are saved with the instance at launch.
        '';
      };
      pre-stop = mkOption {
        type = attrsOf lib.types.path;
        default = { };
        description = ''
          Named executable scripts run on the host before the instance stops,
          in lexical name order. Paths are saved with the instance at launch.
        '';
      };
    };
  };
in
{
  options.services.epi = {
    package = mkOption {
      type = package;
      description = "The EPI package used by managed instances.";
    };

    instances = mkOption {
      type = attrsOf (
        submodule (
          { ... }:
          {
            imports = [ (lib.mkAliasOptionModule [ "hooks" ] [ "settings" "hooks" ]) ];

            options = {
              enable = lib.mkOption {
                type = lib.types.bool;
                description = "enable instance";
                default = true;
              };

              defaultState = lib.mkOption {
                type = lib.types.enum [
                  "running"
                  "stopped"
                ];
                default = "running";
                description = ''
                  Whether the instance starts with the user's default systemd
                  target. A stopped instance remains available for manual start.
                '';
              };

              hooks = mkOption {
                type = hostHooks;
              };

              settings = mkOption {
                type = lib.types.submodule {
                  freeformType = toml.type;
                  options.hooks = mkOption {
                    type = hostHooks;
                    default = { };
                    description = ''
                      Host lifecycle hooks saved with the instance at launch.
                      Named entries merge with the hooks option; conflicting
                      definitions of the same name require an explicit override.
                    '';
                  };
                };

                default = { };
                description = "EPI project configuration written as TOML.";
              };
            };
          }
        )
      );
      default = { };
      description = "EPI instances managed as systemd user services.";
    };
  };
}
