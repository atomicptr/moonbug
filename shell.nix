{
  pkgs ? import <nixpkgs> { },
}:

pkgs.mkShell {
  packages = [
    (pkgs.lua5_5.withPackages (
      ps: with ps; [
        luasocket
        lua-cjson
      ]
    ))
  ];

  MOONBUG_LOG = "debug";

  shellHook = ''
    export LUA_PATH=";;"
    export LUA_CPATH=";;"
  '';
}
