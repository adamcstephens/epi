{ lib, pkgs }:
let
  fakeEpi = pkgs.writeShellScriptBin "epi" ''
    printf '%s\n' "$*" >> "$EPI_TEST_LOG"
    case "$1" in
      launch) mkdir -p "$EPI_STATE_DIR/dev"; touch "$EPI_STATE_DIR/dev/state.json" ;;
      rm) rm -rf "$EPI_STATE_DIR/dev" ;;
    esac
  '';

  postLaunchHook = pkgs.writeTextFile {
    name = "epi-post-launch";
    executable = true;
    text = ''
      #!/usr/bin/env bash
      exit 0
    '';
  };
  changedPostLaunchHook = pkgs.writeTextFile {
    name = "epi-post-launch-changed";
    executable = true;
    text = ''
      #!/usr/bin/env bash
      printf '%s\n' ready
    '';
  };
  postStartHook = pkgs.writeTextFile {
    name = "epi-post-start";
    executable = true;
    text = ''
      #!/usr/bin/env bash
      exit 0
    '';
  };
  preStopHook = pkgs.writeTextFile {
    name = "epi-pre-stop";
    executable = true;
    text = ''
      #!/usr/bin/env bash
      exit 0
    '';
  };

  evaluate =
    launchHook:
    lib.evalModules {
      specialArgs = { inherit pkgs; };
      modules = [
        (
          { lib, ... }:
          {
            options = {
              packages = lib.mkOption {
                type = lib.types.listOf lib.types.package;
                default = [ ];
              };
              xdg.config.files = lib.mkOption {
                type = lib.types.attrsOf lib.types.anything;
                default = { };
              };
              xdg.config.directory = lib.mkOption {
                type = lib.types.str;
                default = "/home/test/.config";
              };
              systemd.services = lib.mkOption {
                type = lib.types.attrsOf lib.types.anything;
                default = { };
              };
              assertions = lib.mkOption {
                type = lib.types.listOf lib.types.anything;
                default = [ ];
              };
            };
          }
        )
        ./epi.nix
        {
          services.epi.instances.dev = {
            enable = true;
            hooks.post-launch.ready = launchHook;
            hooks.post-start.ready = postStartHook;
            hooks.pre-stop.cleanup = preStopHook;
            settings = {
              target = ".#dev";
              cpus = 4;
              memory = 4096;
              ports = [ ":8080" ];
              project_dir = "/home/test/projects/dev";
              hooks.post-launch.from-settings = postLaunchHook;
              hooks.post-start.from-settings = postStartHook;
            };
          };
          services.epi.package = fakeEpi;
        }
        {
          services.epi.instances.dev.hooks.pre-stop.another = preStopHook;
          services.epi.instances.dev.hooks.post-start.another = postStartHook;
        }
      ];
    };

  evaluated = evaluate postLaunchHook;
  changed = evaluate changedPostLaunchHook;

  service = evaluated.config.systemd.services.epi-dev;
  changedService = changed.config.systemd.services.epi-dev;
  source = evaluated.config.xdg.config.files."epi/instances/dev.toml".source;
  changedSource = changed.config.xdg.config.files."epi/instances/dev.toml".source;
in
assert service.description == "EPI instance dev";
assert
  service.restartTriggers == [ evaluated.config.xdg.config.files."epi/instances/dev.toml".source ];
assert service.serviceConfig.ExecStop == "${fakeEpi}/bin/epi stop";
assert
  service.serviceConfig.Environment
  == [ "EPI_PROJECT_CONFIG_FILE=/home/test/.config/epi/instances/dev.toml" ];
assert service.restartTriggers != changedService.restartTriggers;
pkgs.runCommand "epi-hjem-module-test" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  export EPI_STATE_DIR="$TMPDIR/state"
  export EPI_TEST_LOG="$TMPDIR/commands"
  export HOME="$TMPDIR/home"

  grep --quiet '^export PATH=' ${service.serviceConfig.ExecStart}
  python3 - ${source} ${changedSource} <<'PY'
  import os
  import sys
  import tomllib

  with open(sys.argv[1], "rb") as config_file:
      config = tomllib.load(config_file)
  with open(sys.argv[2], "rb") as config_file:
      changed_config = tomllib.load(config_file)

  assert config["target"] == ".#dev"
  assert config["default_name"] == "dev"
  assert config["project_dir"] == "/home/test/projects/dev"
  assert "project_mount" not in config
  assert config["hooks"] == {
      "post-launch": {
          "ready": "${postLaunchHook}",
          "from-settings": "${postLaunchHook}",
      },
      "post-start": {
          "ready": "${postStartHook}",
          "from-settings": "${postStartHook}",
          "another": "${postStartHook}",
      },
      "pre-stop": {
          "cleanup": "${preStopHook}",
          "another": "${preStopHook}",
      },
  }
  for point in config["hooks"].values():
      for path in point.values():
          assert path.startswith("${builtins.storeDir}/")
          assert os.access(path, os.X_OK)
  assert changed_config["hooks"]["post-launch"]["ready"] == "${changedPostLaunchHook}"
  assert os.access(changed_config["hooks"]["post-launch"]["ready"], os.X_OK)
  PY

  ${service.serviceConfig.ExecStart}
  grep --quiet --line-regexp 'launch' "$EPI_TEST_LOG"
  test "$(cat "$EPI_STATE_DIR/dev/.hjem-generation")" = ${source}

  : > "$EPI_TEST_LOG"
  ${service.serviceConfig.ExecStart}
  grep --quiet --line-regexp 'start' "$EPI_TEST_LOG"

  : > "$EPI_TEST_LOG"
  ${changedService.serviceConfig.ExecStart}
  grep --quiet --line-regexp 'rm --force' "$EPI_TEST_LOG"
  grep --quiet --line-regexp 'launch' "$EPI_TEST_LOG"
  test "$(cat "$EPI_STATE_DIR/dev/.hjem-generation")" = ${changedSource}
  touch $out
''
