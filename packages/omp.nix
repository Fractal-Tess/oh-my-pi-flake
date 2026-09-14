{
  autoPatchelfHook,
  alsa-lib,
  bun,
  bun2nix,
  cmake,
  lib,
  libopus,
  libpulseaudio,
  makeBinaryWrapper,
  ninja,
  pipewire,
  pkg-config,
  removeReferencesTo,
  rustPlatform,
  rustToolchain,
  source,
  stdenv,
  stdenvNoCC,
  unzip,
  withWaylandScreencast ? false,
}:
let
  packageJson = lib.importJSON "${source}/packages/coding-agent/package.json";
  rootPackageJson = lib.importJSON "${source}/package.json";
  platform =
    {
      aarch64-linux = {
        addon = "pi_natives.linux-arm64.node";
        nativeLibrary = "libpi_natives.so";
      };
      x86_64-linux = {
        addon = "pi_natives.linux-x64-baseline.node";
        nativeLibrary = "libpi_natives.so";
        rustFlags = "-C target-cpu=x86-64-v2";
      };
    }
    .${stdenv.hostPlatform.system} or (throw "Unsupported OMP platform: ${stdenv.hostPlatform.system}");
  patchedDependencies = lib.mapAttrs (
    _: patch: source + "/${patch}"
  ) rootPackageJson.patchedDependencies;
  patchOverrides = bun2nix.patchedDependenciesToOverrides { inherit patchedDependencies; };
  runtimeNativeLibraries = [
    stdenv.cc.cc.lib
  ]
  ++ lib.optional (stdenv.cc.cc ? libgcc) stdenv.cc.cc.libgcc;
  bunRuntimeTemplate = stdenvNoCC.mkDerivation {
    pname = "omp-bun-runtime-template";
    inherit (bun) version;
    src = bun.src;

    nativeBuildInputs = [ unzip ];
    dontUnpack = true;
    dontFixup = true;

    installPhase = ''
      runHook preInstall
      unzip -q "$src"
      install -Dm755 bun-*/bun "$out/libexec/bun"
      runHook postInstall
    '';
  };
in
stdenv.mkDerivation {
  pname = "omp";
  inherit (packageJson) version;
  src = source;

  cargoDeps = rustPlatform.importCargoLock { lockFile = "${source}/Cargo.lock"; };
  bunDeps = bun2nix.fetchBunDeps {
    bunNix = "${source}/nix/bun.nix";
    overrides = patchOverrides;
  };

  nativeBuildInputs = [
    bun
    bun2nix.hook
    cmake
    ninja
    pkg-config
    removeReferencesTo
    rustPlatform.bindgenHook
    rustPlatform.cargoSetupHook
    rustToolchain
    autoPatchelfHook
    makeBinaryWrapper
  ];

  # pcre2 is vendored via PCRE2_SYS_STATIC, but opus must link the nixpkgs
  buildInputs = [
    libopus
    stdenv.cc.cc.lib
  ]
  ++ lib.optionals withWaylandScreencast [ pipewire ];

  strictDeps = true;
  # Nix builders cannot reliably hardlink cache files into node_modules.
  bunInstallFlags = [
    "--linker=isolated"
    "--backend=copyfile"
  ];
  dontConfigure = true;
  dontRunLifecycleScripts = true;
  dontUseBunBuild = true;
  dontUseBunCheck = true;
  dontUseBunInstall = true;
  dontStrip = true;

  env = {
    CMAKE_POLICY_VERSION_MINIMUM = "3.5";
    PCRE2_SYS_STATIC = "1";
    SOURCE_DATE_EPOCH = "1";
  }
  // lib.optionalAttrs (platform ? rustFlags) {
    RUSTFLAGS = platform.rustFlags;
  };

  # This revision missed the Collab CLI when migrating off the chalk package.
  postPatch = ''
    substituteInPlace packages/coding-agent/src/cli/collab-cli.ts \
      --replace-fail 'from "chalk"' 'from "@oh-my-pi/pi-utils/chalk"'
  '';

  buildPhase = ''
    runHook preBuild

    echo "Building pi-natives"
    cargo build --release -p pi-natives ${lib.optionalString withWaylandScreencast "--features wayland-pipewire"}
    install -Dm755 "target/release/${platform.nativeLibrary}" \
      "packages/natives/native/${platform.addon}"
    # The loader extracts this archived addon at runtime, so fix its
    # interpreter-independent Nix RPATH before Bun embeds it.
    autoPatchelf -- "packages/natives/native/${platform.addon}"
    # pi-voice dlopens libpulse-simple.so.0 / libpulse.so.0 / libasound.so.2
    # by bare name; append the client libraries because they are not linked by
    # the addon and autoPatchelf cannot discover them on its own.
    patchelf --add-rpath "${
      lib.makeLibraryPath [
        libpulseaudio
        alsa-lib
      ]
    }" \
      "packages/natives/native/${platform.addon}"

    echo "Compiling OMP"
    BUN_COMPILE_EXECUTABLE_PATH="${bunRuntimeTemplate}/libexec/bun" \
      bun --cwd="$PWD/packages/coding-agent" run build

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 packages/coding-agent/dist/omp "$out/bin/omp"
    install -Dm644 LICENSE "$out/share/doc/omp/LICENSE"
    install -Dm644 THIRD-PARTY-NOTICES.txt "$out/share/doc/omp/THIRD-PARTY-NOTICES.txt"

    # The addon is gzip-compressed inside the compiled binary, so the store
    # paths it links against are invisible to Nix's output reference scanner.
    mkdir -p "$out/nix-support"
    patchelf --print-rpath "packages/natives/native/${platform.addon}" \
      > "$out/nix-support/embedded-addon-runpath"

    runHook postInstall
  '';

  # Bun serializes the build interpreter path into the bundled entrypoint's
  # inert shebang. Remove its hash before Nix scans output references.
  preFixup = ''
    remove-references-to -t ${bun} "$out/bin/omp"
  '';

  # Prebuilt addons installed by the inference worker need libstdc++.so.6 and
  # libgcc_s.so.1. Keep this path on the worker-facing environment variable,
  # not process-wide LD_LIBRARY_PATH, so user commands retain their loader
  # behavior. Force libstdc++ into DT_NEEDED for direct addon dlopen calls.
  postFixup = ''
    patchelf --add-needed libstdc++.so.6 "$out/bin/omp"
    wrapProgram "$out/bin/omp" \
      --set-default OMP_NATIVE_LIBRARY_PATH "${lib.makeLibraryPath runtimeNativeLibraries}"
  '';

  disallowedReferences = [ bun ];

  # Bun's compile output can retain a stale DT_VERDEF address after fixups;
  # correct it after autoPatchelf and wrapProgram have completed.
  preInstallCheck = ''
    bun ${source}/scripts/fix-dt-verdef.ts "$out/bin/.omp-wrapped"
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    smokeOutput="$($out/bin/omp --smoke-test)"
    grep -q "smoke-test: ok" <<<"$smokeOutput"
    BUN_BE_BUN=1 "$out/bin/omp" -e \
      'if (Bun.version !== "${bun.version}" || typeof Bun.Image !== "function") process.exit(1)'
    env -u LD_LIBRARY_PATH BUN_BE_BUN=1 "$out/bin/omp" -e \
      'const {dlopen}=require("bun:ffi");const dirs=(process.env.OMP_NATIVE_LIBRARY_PATH||"").split(":").filter(Boolean);const need={"libstdc++.so.6":{__cxa_demangle:{args:["ptr","ptr","ptr","ptr"],returns:"ptr"}},"libgcc_s.so.1":{_Unwind_Backtrace:{args:["ptr","ptr"],returns:"i32"}}};for(const lib of Object.keys(need)){let ok=false;for(const d of dirs){try{dlopen(d+"/"+lib,need[lib]);ok=true;break}catch(e){}}if(!ok){console.error("unresolved: "+lib);process.exit(1)}}'
    env -u LD_LIBRARY_PATH BUN_BE_BUN=1 "$out/bin/omp" -e \
      'require("bun:ffi").dlopen("libstdc++.so.6", {__cxa_demangle:{args:["ptr","ptr","ptr","ptr"],returns:"ptr"}})'
    runHook postInstallCheck
  '';

  meta = {
    description = "Terminal-based coding agent with multi-model support";
    homepage = "https://omp.sh";
    changelog = "https://github.com/can1357/oh-my-pi/releases/tag/v${packageJson.version}";
    license = lib.licenses.mit;
    mainProgram = "omp";
    platforms = [
      "aarch64-linux"
      "x86_64-linux"
    ];
    sourceProvenance = with lib.sourceTypes; [
      binaryNativeCode
      fromSource
    ];
  };
}
