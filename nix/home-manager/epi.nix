{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.epi;
  enabledInstances = lib.filterAttrs (_: instance: instance.enable) cfg.instances;
  toml = pkgs.formats.toml { };
  configFile = name: "epi/instances/${name}.toml";
  configSource =
    name: instance:
    toml.generate "epi-${name}.toml" (
      {
        default_name = name;
      }
      // lib.optionalAttrs (!(instance.settings ? project_dir)) { project_mount = false; }
      // instance.settings
    );
in
{
  imports = [ ../instance-options.nix ];

  config = lib.mkIf (enabledInstances != { }) {
    xdg.configFile = lib.mapAttrs' (
      name: instance:
      lib.nameValuePair (configFile name) {
        source = configSource name instance;
      }
    ) enabledInstances;

    systemd.user.services = lib.mapAttrs' (
      name: instance:
      lib.nameValuePair "epi-${name}" {
        Unit = {
          Description = "EPI instance ${name}";
          X-Restart-Triggers = [ (configSource name instance) ];
        };
        Service = {
          Type = "oneshot";
          RemainAfterExit = true;
          Environment = [
            "EPI_PROJECT_CONFIG_FILE=${config.xdg.configHome}/${configFile name}"
            "PATH=${
              lib.makeBinPath [
                cfg.package
                pkgs.coreutils
                config.home.profileDirectory
                "/run/wrappers"
                "/run/current-system/sw"
              ]
            }"
          ];
          ExecStart = "${lib.getExe cfg.package} reconcile";
          ExecStop = "${lib.getExe cfg.package} stop";
        };
        Install.WantedBy = lib.optional (instance.defaultState == "running") "default.target";
      }
    ) enabledInstances;
  };
}
