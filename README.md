# DevBox Bootstrap Source Build Pipeline

Self-contained build pipeline for generating native bootstrap archives for **DevBox** (`com.devbox.terminal`) targeting **Android 14 (API 34) ARM64 (`aarch64`)**.

---

## 1. Overview & Architecture

DevBox uses a dedicated application identity (`com.devbox.terminal`) and custom prefix (`/data/data/com.devbox.terminal/files/usr`). Official Termux bootstrap archives cannot be used directly because their binaries, shared libraries, dynamic linker paths (`PT_INTERP`), and `DT_RUNPATH` are hardcoded to `/data/data/com.termux/files/usr`.

This pipeline compiles the entire bootstrap archive and all of its dependencies **directly from source** using the official Termux cross-compilation toolchain inside a containerized GitHub Actions runner, without downloading any pre-compiled `com.termux` Debian packages.

```
+-----------------------------------------------------------------------------------+
| GitHub Actions: arbdevai/devbox-packages                                         |
|                                                                                   |
|  1. Upstream Pin: termux/termux-packages @ 62195791c21099ecd1fe54a5df517d4659ec195d|
|  2. Identity: TERMUX_APP__PACKAGE_NAME="com.devbox.terminal", TERMUX__NAME="DevBox"|
|  3. Container: ghcr.io/termux/package-builder:latest                             |
|  4. Build: ./scripts/build-bootstraps.sh --architectures aarch64 -f              |
|     (Strictly without -i / -I flags to prevent downloading com.termux debs)       |
|  5. Verification: verify-bootstrap-prefix.sh (audits ELF RUNPATH & symlinks)      |
|  6. Artifacts: bootstrap-aarch64.zip, .sha256, manifest.json, CHECKSUMS.txt       |
+-----------------------------------------------------------------------------------+
```

---

## 2. Pinned Specifications

| Component | Pinned Version / Identifier | Purpose |
|---|---|---|
| **Upstream Repo** | `https://github.com/termux/termux-packages.git` | Base build definitions and package recipes |
| **Upstream Commit** | `62195791c21099ecd1fe54a5df517d4659ec195d` | Pinned stable source tree |
| **Builder Image** | `ghcr.io/termux/package-builder:latest` | Standardized cross-compilation environment (Ubuntu 24.04/26.04 + Android NDK) |
| **Target ABI** | `aarch64` (ARM64) | 64-bit ARM architecture |
| **Package Identity** | `com.devbox.terminal` | Application ID and Linux namespace |
| **Prefix Path** | `/data/data/com.devbox.terminal/files/usr` | Root filesystem prefix |
| **Home Path** | `/data/data/com.devbox.terminal/files/home` | Default user home directory |

---

## 3. Directory Layout

```
bootstrap-builder/
├── .github/
│   └── workflows/
│       └── build-devbox-bootstraps.yml   # GHA workflow template for arbdevai/devbox-packages
├── scripts/
│   ├── apply-devbox-identity.sh          # Patches properties.sh and validates derivation rules
│   ├── build-devbox-bootstrap.sh         # Executes bootstrap build inside builder container
│   └── verify-bootstrap-prefix.sh        # Unpacks and audits prefix, binaries, and symlinks
├── config.env                            # Environment variables and pinned parameters
└── README.md                             # Architecture documentation and operational guide
```

---

## 4. Key Mechanics & Evidence for Build Flags

### Identity Patching (`scripts/properties.sh`)
When `scripts/apply-devbox-identity.sh` runs against the source tree, it updates:
```bash
TERMUX__NAME="DevBox"
TERMUX_APP__PACKAGE_NAME="com.devbox.terminal"
TERMUX_APP__NAMESPACE="com.devbox.terminal"
TERMUX_REPO_APP__PACKAGE_NAME="com.devbox.terminal"
TERMUX_REPO_APP__DATA_DIR="/data/data/com.devbox.terminal"
TERMUX_REPO__ROOTFS="/data/data/com.devbox.terminal/files"
TERMUX_REPO__PREFIX="/data/data/com.devbox.terminal/files/usr"
```
The internal validation logic in `properties.sh` then automatically derives and validates:
- `TERMUX_APP__DATA_DIR` = `/data/data/com.devbox.terminal`
- `TERMUX__PREFIX` = `/data/data/com.devbox.terminal/files/usr`
- `TERMUX_PREFIX` = `/data/data/com.devbox.terminal/files/usr`
- `TERMUX_ANDROID_HOME` = `/data/data/com.devbox.terminal/files/home`

### Forcing Full Source Compilation (No Prebuilt Debs)
In upstream `build-package.sh` and `scripts/build/termux_step_get_dependencies.sh`:
- Passing `-i` or `-I` sets `TERMUX_INSTALL_DEPS=true`, causing the builder to download official pre-compiled `.deb` packages from `packages-cf.termux.dev`. Those packages contain binaries linked against `/data/data/com.termux/files/usr`.
- By invoking `./scripts/build-bootstraps.sh --architectures aarch64 -f` without `-i` or `-I`, `TERMUX_INSTALL_DEPS` remains `false`.
- When `TERMUX_INSTALL_DEPS=false`, `termux_step_get_dependencies()` resolves transitive dependencies via `scripts/buildorder.py` and builds every package and subpackage directly from source with `$TERMUX_PREFIX` set to `/data/data/com.devbox.terminal/files/usr`.

---

## 5. Verification & Quality Gates (`verify-bootstrap-prefix.sh`)

Before any artifact is uploaded or released, `verify-bootstrap-prefix.sh` executes the following automated checks:
1. **Symlink Integrity**: Verifies `SYMLINKS.txt` exists and contains valid `target←link` entries.
2. **Essential Binaries**: Ensures `bin/bash`, `bin/dash`, `bin/dpkg`, `bin/apt`, and `var/lib/dpkg/status` are present.
3. **Prefix Isolation**: Scans text files and ELF binaries with `strings` to verify:
   - Presence of `/data/data/com.devbox.terminal/files/usr`
   - **Zero** occurrences of `/data/data/com.termux` (fails immediately if detected).
4. **Manifest Generation**: Generates `bootstrap-aarch64.zip.sha256` and `manifest.json` recording file count, symlink count, size, sha256 hash, and package inventory.

---

## 6. How to Deploy to `arbdevai/devbox-packages`

### Step 1: Initialize the Remote Repository
Create or use the private repository `arbdevai/devbox-packages`. You can either:
- **Fork `termux/termux-packages`** to `arbdevai/devbox-packages` and copy `bootstrap-builder/` into the root.
- **Or push `bootstrap-builder/`** as a standalone workflow repository (the workflow will automatically clone the pinned upstream commit).

### Step 2: Trigger the Build in GitHub Actions
1. Navigate to **Actions** -> **Build DevBox Bootstrap Archives (ARM64)** in `arbdevai/devbox-packages`.
2. Click **Run workflow**.
3. (Optional) Set `publish_release=true` and `release_tag=v0.1.0-bootstrap` to create a GitHub Release with the build outputs attached.

### Step 3: Consume Artifact in DevBox Android App
Once the workflow finishes:
1. Download `bootstrap-aarch64.zip` and note its SHA256 checksum from `bootstrap-aarch64.zip.sha256`.
2. In the DevBox application repository (`arbdevai/DevBox`), place `bootstrap-aarch64.zip` at:
   ```
   app/src/main/cpp/bootstrap-aarch64.zip
   ```
3. Update `app/build.gradle` `downloadBootstraps` task with the new SHA256 hash:
   ```groovy
   downloadBootstrap("aarch64", "<NEW_SHA256_HASH>", version)
   ```
4. Build the DevBox APK (`./gradlew assembleDebug` or via DevBox CI).

---

## 7. APT Repository Follow-Up

The bootstrap archive generated by this pipeline provides a self-contained offline base environment (Bash shell, Coreutils, Dpkg, Apt, Grep, Tar, Sed, etc.) enabling DevBox to initialize and run commands immediately on first launch.

For subsequent online package management (`apt update && apt install <package>`):
1. **Package Compilation**: Build desired packages (`git`, `python`, `nodejs`, `clang`, etc.) using `./scripts/run-docker.sh ./build-package.sh -a aarch64 <package>`.
2. **Repository Hosting**: Publish the resulting `.deb` files and `InRelease`/`Packages.xz` to a static repository (e.g. GitHub Pages or Cloudflare R2 bucket at `https://packages.devbox.terminal` or similar).
3. **Keyring & Sources**: Package a custom `devbox-keyring` and configure `etc/apt/sources.list` pointing to the DevBox APT repository.
