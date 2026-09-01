{ lib, pkgs }:
let
  fakeEpi = pkgs.writeShellScriptBin "epi" ''
    printf '%s\n' "$*" >> "$EPI_TEST_LOG"
    case "$1" in
      launch) mkdir -p "$EPI_STATE_DIR/dev"; touch "$EPI_STATE_DIR/dev/state.json" ;;
      rm) rm -rf "$EPI_STATE_DIR/dev" ;;
    esac
  '';

  evaluated = lib.evalModules {
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
          target = ".#dev";
          settings = {
            cpus = 4;
            memory = 4096;
            ports = [ ":8080" ];
          };
        };
        services.epi.package = fakeEpi;
      }
    ];
  };

  service = evaluated.config.systemd.services.epi-dev;
in
assert service.description == "EPI instance dev";
assert
  service.restartTriggers == [ evaluated.config.xdg.config.files."epi/instances/dev.toml".source ];
assert service.serviceConfig.ExecStop == "${fakeEpi}/bin/epi stop";
assert
  service.serviceConfig.Environment
  == [ "EPI_PROJECT_CONFIG_FILE=/home/test/.config/epi/instances/dev.toml" ];
pkgs.runCommand "epi-hjem-module-test" { } ''
  export EPI_STATE_DIR="$TMPDIR/state"
  export EPI_TEST_LOG="$TMPDIR/commands"
  export HOME="$TMPDIR/home"

  grep -q '^export PATH=' ${service.serviceConfig.ExecStart}
  grep -qx 'target = ".#dev"' ${evaluated.config.xdg.config.files."epi/instances/dev.toml".source}
  grep -qx 'default_name = "dev"' ${evaluated.config.xdg.config.files."epi/instances/dev.toml".source}
  grep -qx 'project_mount = false' ${
    evaluated.config.xdg.config.files."epi/instances/dev.toml".source
  }

  ${service.serviceConfig.ExecStart}
  grep -qx 'launch' "$EPI_TEST_LOG"
  test "$(cat "$EPI_STATE_DIR/dev/.hjem-generation")" = ${
    evaluated.config.xdg.config.files."epi/instances/dev.toml".source
  }

  : > "$EPI_TEST_LOG"
  ${service.serviceConfig.ExecStart}
  grep -qx 'start' "$EPI_TEST_LOG"

  : > "$EPI_TEST_LOG"
  printf 'old-generation' > "$EPI_STATE_DIR/dev/.hjem-generation"
  ${service.serviceConfig.ExecStart}
  grep -qx 'rm --force' "$EPI_TEST_LOG"
  grep -qx 'launch' "$EPI_TEST_LOG"
  test "$(cat "$EPI_STATE_DIR/dev/.hjem-generation")" = ${
    evaluated.config.xdg.config.files."epi/instances/dev.toml".source
  }
  touch $out
''
