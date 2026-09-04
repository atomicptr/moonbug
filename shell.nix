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

    (pkgs.luajit.withPackages (
      ps: with ps; [
        luasocket
        lua-cjson
      ]
    ))
  ];

  MOONBUG_LOG = "debug";
}
