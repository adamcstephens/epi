{ lib, pkgs }:
let
  hook = pkgs.writeShellScript "epi-ready" ''
    exit 0
  '';
  changedHook = pkgs.writeShellScript "epi-ready-changed" ''
    printf '%s\n' ready
  '';
  evaluate =
    launchHook:
    lib.evalModules {
      specialArgs = { inherit pkgs; };
      modules = [
        {
          options = {
            xdg.configFile = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              default = { };
            };
            xdg.configHome = lib.mkOption {
              type = lib.types.str;
              default = "/home/test/.config";
            };
            home.profileDirectory = lib.mkOption {
              type = lib.types.str;
              default = "/home/test/.nix-profile";
            };
            systemd.user.services = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              default = { };
            };
          };
        }
        ./epi.nix
        {
          services.epi = {
            package = pkgs.hello;
            instances = {
              dev = {
                hooks.post-launch.ready = launchHook;
                settings = {
                  target = ".#dev";
                  project_dir = "/home/test/src/dev";
                  hooks.post-start.ready = hook;
                };
              };
              sleeping = {
                defaultState = "stopped";
                settings.target = ".#sleeping";
              };
              disabled.enable = false;
            };
          };
        }
        {
          services.epi.instances.dev.hooks = {
            post-start.another = hook;
            pre-stop.cleanup = hook;
          };
        }
      ];
    };
  evaluated = (evaluate hook).config;
  changed = (evaluate changedHook).config;
  service = evaluated.systemd.user.services.epi-dev;
  sleeping = evaluated.systemd.user.services.epi-sleeping;
  source = evaluated.xdg.configFile."epi/instances/dev.toml".source;
  sleepingSource = evaluated.xdg.configFile."epi/instances/sleeping.toml".source;
in
assert !(evaluated.systemd.user.services ? epi-disabled);
assert !(evaluated.xdg.configFile ? "epi/instances/disabled.toml");
assert service.Install.WantedBy == [ "default.target" ];
assert sleeping.Install.WantedBy == [ ];
assert
  service.Unit.X-Restart-Triggers != changed.systemd.user.services.epi-dev.Unit.X-Restart-Triggers;
pkgs.runCommand "epi-home-manager-module-test" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  python3 - ${source} ${sleepingSource} <<'PY'
  import sys
  import tomllib

  with open(sys.argv[1], "rb") as file:
      dev = tomllib.load(file)
  with open(sys.argv[2], "rb") as file:
      sleeping = tomllib.load(file)

  assert dev["target"] == ".#dev"
  assert dev["default_name"] == "dev"
  assert dev["project_dir"] == "/home/test/src/dev"
  assert "project_mount" not in dev
  assert sleeping["default_name"] == "sleeping"
  assert sleeping["project_mount"] is False
  assert dev["hooks"] == {
      "post-launch": {"ready": "${hook}"},
      "post-start": {"ready": "${hook}", "another": "${hook}"},
      "pre-stop": {"cleanup": "${hook}"},
  }
  PY
  touch "$out"
''
