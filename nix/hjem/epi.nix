{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    filterAttrs
    getExe
    mapAttrs'
    mkIf
    mkOption
    nameValuePair
    ;
  inherit (lib.types)
    attrsOf
    package
    str
    submodule
    ;

  cfg = config.services.epi;
  enabledInstances = filterAttrs (_: instance: instance.enable) cfg.instances;
  toml = pkgs.formats.toml { };

  instanceConfig =
    name: instance:
    instance.settings
    // {
      target = instance.target;
      default_name = name;
      project_mount = false;
    };

  configFile = name: "epi/instances/${name}.toml";
  configPath = name: "${config.xdg.config.directory}/${configFile name}";
  configSource = name: instance: toml.generate "epi-${name}.toml" (instanceConfig name instance);
  startScript =
    name: instance:
    pkgs.writeShellApplication {
      name = "epi-${name}-start";
      runtimeInputs = [
        cfg.package
        pkgs.coreutils
      ];
      text = ''
        state_dir="''${EPI_STATE_DIR:-$HOME/.local/state/epi}"
        state_file="$state_dir/${name}/state.json"
        generation_file="$state_dir/${name}/.hjem-generation"
        generation=${configSource name instance}

        if [ -e "$state_file" ] && [ -f "$generation_file" ] && [ "$(cat "$generation_file")" = "$generation" ]; then
          exec ${getExe cfg.package} start
        fi

        if [ -e "$state_file" ]; then
          ${getExe cfg.package} rm --force
        fi

        ${getExe cfg.package} launch
        mkdir -p "$state_dir/${name}"
        printf '%s' "$generation" > "$generation_file"
      '';
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
            options = {
              enable = lib.mkOption {
                type = lib.types.bool;
                description = "enable instance";
                default = true;
              };

              target = mkOption {
                type = str;
                description = "Flake target for this instance.";
              };

              settings = mkOption {
                type = lib.types.submodule {
                  freeformType = toml.type;
                };

                default = { };
                description = "Additional EPI project configuration written as TOML.";
              };
            };
          }
        )
      );
      default = { };
      description = "EPI instances managed as systemd user services.";
    };
  };

  config = mkIf (enabledInstances != { }) {
    xdg.config.files = mapAttrs' (
      name: instance:
      nameValuePair (configFile name) {
        source = configSource name instance;
      }
    ) enabledInstances;

    systemd.services = mapAttrs' (
      name: instance:
      nameValuePair "epi-${name}" {
        description = "EPI instance ${name}";
        path = [
          "/run/wrappers"
          "/run/current-system/sw"
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          Environment = [ "EPI_PROJECT_CONFIG_FILE=${configPath name}" ];
          ExecStart = "${startScript name instance}/bin/epi-${name}-start";
          ExecStop = "${getExe cfg.package} stop";
        };
        wantedBy = [ "default.target" ];
        restartTriggers = [ (configSource name enabledInstances.${name}) ];
      }
    ) enabledInstances;
  };
}
