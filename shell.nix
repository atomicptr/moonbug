{
  pkgs ? import <nixpkgs> { },
}:

pkgs.mkShell {
  packages = with pkgs; [
    (lua5_5.withPackages (
      ps: with ps; [
        lua-cjson
        luacov
        luasocket
      ]
    ))

    (luajit.withPackages (
      ps: with ps; [
        lua-cjson
        luacov
        luasocket
      ]
    ))

    python3
    watchexec
  ];

  MOONBUG_LOG = "debug";
}
