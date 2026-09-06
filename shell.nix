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
  # MOONBUG_LOG = "trace";

  MOONBUG_PORT = 8888;
  MOONBUG_TEST_COVERAGE_PORT = 8000;
}
