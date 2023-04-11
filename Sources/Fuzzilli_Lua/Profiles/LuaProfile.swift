let LuaProfile = Profile(
    processArgs: ["-r"],

    processEnv: ["ASAN_OPTIONS":"handle_segv=0"],
    maxExecsBeforeRespawn: 1000
)