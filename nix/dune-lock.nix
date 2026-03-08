{
  lib,
  fetchurl,
  makeSetupHook,
  writeText,
  ocaml,
  lockDir,
}:

let
  # Read a .pkg file and normalize whitespace for easier matching
  readPkg = name:
    builtins.replaceStrings [ "\n" ] [ " " ] (builtins.readFile (lockDir + "/${name}"));

  # Extract url from a fetch block fragment
  extractUrl = block:
    let
      m = builtins.match ".*\\(url ([^)]+)\\).*" block;
    in
    if m != null then lib.strings.trim (builtins.head m) else null;

  # Extract checksum from a fetch block fragment
  extractChecksum = block:
    let
      m = builtins.match ".*\\(checksum ([^)]+)\\).*" block;
    in
    if m != null then lib.strings.trim (builtins.head m) else null;

  # Parse "sha256=abc123" into { type, value }
  parseChecksum = checksumStr:
    let
      parts = lib.splitString "=" checksumStr;
    in
    {
      type = builtins.head parts;
      value = builtins.elemAt parts 1;
    };

  # Create a fetch entry from url and checksum
  makeFetch = url: checksum:
    let
      parsed = parseChecksum checksum;
    in
    {
      inherit url;
      fetched = fetchurl {
        inherit url;
        ${parsed.type} = parsed.value;
      };
    };

  # Extract the main source fetch from a .pkg file
  extractSource = content:
    let
      parts = lib.splitString "(source" content;
      hasSourceBlock = builtins.length parts > 1;
      sourceSection = if hasSourceBlock then builtins.elemAt parts 1 else "";
      isMainSource = hasSourceBlock && !(lib.hasPrefix "_sources" (lib.strings.trim sourceSection));
      fetchParts = lib.splitString "(fetch" sourceSection;
      hasFetch = builtins.length fetchParts > 1;
      fetchBlock = if hasFetch then builtins.elemAt fetchParts 1 else "";
      url = extractUrl fetchBlock;
      checksum = extractChecksum fetchBlock;
    in
    if isMainSource && hasFetch && url != null && checksum != null then
      makeFetch url checksum
    else
      null;

  # Extract extra_sources fetches from a .pkg file
  extractExtraSources = content:
    let
      hasExtra = builtins.match ".*(\\(extra_sources .*).*" content != null;
      afterExtra =
        let
          parts = lib.splitString "(extra_sources" content;
        in
        if builtins.length parts > 1 then builtins.elemAt parts 1 else "";
      fetchParts = lib.splitString "(fetch" afterExtra;
      fetchBlocks = lib.tail fetchParts;
      extractBlock = block:
        let
          url = extractUrl block;
          checksum = extractChecksum block;
        in
        if url != null && checksum != null then
          makeFetch url checksum
        else
          null;
    in
    if hasExtra then
      builtins.filter (x: x != null) (map extractBlock fetchBlocks)
    else
      [ ];

  # List and process all .pkg files
  lockFiles = builtins.readDir lockDir;
  pkgFiles = lib.filterAttrs (name: _: lib.hasSuffix ".pkg" name) lockFiles;
  parsed = lib.mapAttrs (name: _:
    let
      content = readPkg name;
    in
    {
      source = extractSource content;
      extraSources = extractExtraSources content;
    }
  ) pkgFiles;

  # Collect all fetches
  allFetches =
    let
      sources = lib.filter (x: x != null) (lib.mapAttrsToList (_: pkg: pkg.source) parsed);
      extraSources = lib.concatLists (lib.mapAttrsToList (_: pkg: pkg.extraSources) parsed);
    in
    sources ++ extraSources;

  # Generate the hook script
  rewriteUrls = lib.concatStringsSep "\n" (
    map (fetch: ''sed -i "s|${fetch.url}|file://${fetch.fetched}|g" dune.lock/*.pkg'') allFetches
  );

  hookScript = ''
    duneLockPostUnpack() {
      if [ -d "$sourceRoot/dune.lock" ]; then
        chmod -R u+w "$sourceRoot/dune.lock"
        pushd "$sourceRoot" > /dev/null

        # Rewrite fetch URLs to pre-fetched Nix store paths
        ${rewriteUrls}

        # Stub OCaml compiler packages — nixpkgs provides OCaml
        echo '(version ${ocaml.version})' > dune.lock/ocaml.pkg
        echo '(version ${ocaml.version})' > dune.lock/ocaml-system.pkg
        printf '(version 3)\n(depends ocaml-system)\n' > dune.lock/ocaml-config.pkg

        popd > /dev/null
      fi
    }
    postUnpackHooks+=(duneLockPostUnpack)
  '';
in

makeSetupHook { name = "dune-lock-hook"; } (writeText "dune-lock-hook.sh" hookScript)
