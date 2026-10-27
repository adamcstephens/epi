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
    nameValuePair
    ;

  cfg = config.services.epi;
  enabledInstances = filterAttrs (_: instance: instance.enable) cfg.instances;
  toml = pkgs.formats.toml { };

  instanceConfig =
    name: instance:
    {
      default_name = name;
    }
    // lib.optionalAttrs (!(instance.settings ? project_dir)) {
      project_mount = false;
    }
    // instance.settings;

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
        exec ${getExe cfg.package} reconcile
      '';
    };
in
{
  imports = [ ../instance-options.nix ];

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
          "${config.directory}/.local/state/hjem/standalone/current-profile"
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
        wantedBy = lib.optional (instance.defaultState == "running") "default.target";
        restartTriggers = [ (configSource name enabledInstances.${name}) ];
      }
    ) enabledInstances;
  };
}
