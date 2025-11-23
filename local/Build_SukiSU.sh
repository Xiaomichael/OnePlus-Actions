#!/bin/bash
#export all_proxy=socks5://192.168.x.x:x/   # 如需走代理，请在这里填写你的 socks5 代理地址
set -e

# --- 构建配置阶段 ---
clear
echo "==================================================="
echo "  SukiSU Ultra OnePlus Kernel Build Configuration  "
echo "==================================================="
echo "  按回车键可直接使用 [方括号] 中的默认值。"
echo ""

# 带默认值的交互输入函数
ask() {
    local prompt default reply
    prompt="$1"
    default="$2"
    
    read -p "$prompt [$default]: " reply
    echo "${reply:-$default}"
}

# --- 交互输入 ---
CPU=$(ask "请输入 CPU 分支 (例如: sm8750, sm8650, sm8550, sm8475)" "sm8650")
FEIL=$(ask "请输入手机型号 (例如: oneplus_13_b, oneplus_12, oneplus_11)" "oneplus_12")
ANDROID_VERSION=$(ask "请输入安卓 KMI 版本 (android15, android14, android13, android12)" "android14")
KERNEL_VERSION=$(ask "请输入内核版本 (6.6, 6.1, 5.15, 5.10)" "6.1")
KPM=$(ask "是否启用 KPM (Kernel Patch Manager)? (On/Off)" "Off")
lz4kd=$(ask "是否启用 lz4kd? (6.1 关闭时使用 lz4 + zstd; 6.6 关闭时使用 lz4) (On/Off)" "Off")
bbr=$(ask "是否启用 BBR 拥塞控制算法? (On/Off)" "Off")
bbg=$(ask "是否启用 Baseband-Guard 基带防护? (On/Off)" "On")
proxy=$(ask "是否添加代理性能优化? (如为联发科 CPU 必须选择 Off) (On/Off)" "On")

# --- 配置摘要 ---
clear
echo ""
echo "================================================="
echo "                   配置摘要"
echo "================================================="
echo "手机型号                 : $FEIL"
echo "CPU 分支                 : $CPU"
echo "安卓 KMI 版本            : $ANDROID_VERSION"
echo "内核版本                 : $KERNEL_VERSION"
echo "是否启用 KPM             : $KPM"
echo "是否启用 lz4kd           : $lz4kd"
echo "是否启用 BBR             : $bbr"
echo "是否启用 Baseband-Guard  : $bbg"
echo "是否启用代理优化         : $proxy"
echo "================================================="
read -p "按回车键开始构建流程..."
clear

# --- 环境准备 ---
echo "📦 正在准备构建工作空间..."
WORKSPACE=$PWD/build_workspace
sudo rm -rf "$WORKSPACE"
mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

# 在使用依赖前先安装
echo "📦 正在安装构建依赖(需要 sudo 权限)..."
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends \
  python3 git curl ccache libelf-dev \
  build-essential flex bison libssl-dev \
  libncurses-dev liblz4-tool zlib1g-dev \
  libxml2-utils rsync unzip python3-pip gawk
clear
echo "✅ 必要构建依赖安装完成。"

# 配置并优化 ccache
echo "⚙️ 正在配置 ccache 缓存..."
export CCACHE_DIR="$HOME/.ccache_${FEIL}_SukiSU"
export CCACHE_COMPILERCHECK="%compiler% -dumpmachine; %compiler% -dumpversion"
export CCACHE_NOHASHDIR="true"
export CCACHE_HARDLINK="true"
export CCACHE_MAXSIZE="20G"
export PATH="/usr/lib/ccache:$PATH"
mkdir -p "$CCACHE_DIR"
echo "✅ ccache 缓存目录: $CCACHE_DIR"
ccache -M "$CCACHE_MAXSIZE"
ccache -z

# 为 repo 工具配置 git 信息
echo "🔐 正在配置 Git 用户信息..."
git config --global user.name "Local Builder"
git config --global user.email "builder@localhost"
echo "✅ Git 用户信息配置完成。"

# --- 源码及工具准备 ---

# 未安装 repo 时自动安装
if ! command -v repo &> /dev/null; then
    echo "📥 未检测到 repo 工具，正在安装..."
    curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo > ~/repo
    chmod a+x ~/repo
    sudo mv ~/repo /usr/local/bin/repo
    echo "✅ repo 工具安装完成。"
else
    echo "ℹ️ 已检测到 repo 工具，跳过安装。"
fi

# 克隆内核源码
echo "⬇️ 正在准备内核源码目录..."
sudo rm -rf kernel_workspace
mkdir -p kernel_workspace && cd kernel_workspace

echo "🌐 正在初始化 oneplus/${CPU} 分支、机型 ${FEIL} 的 manifest..."
repo init -u https://github.com/Xiaomichael/kernel_manifest.git -b refs/heads/oneplus/${CPU} -m ${FEIL}.xml --depth=1

echo "🔄 正在同步内核源码仓库 (使用 $(nproc --all) 线程)..."
repo sync -c -j$(nproc --all) --no-tags --no-clone-bundle --force-sync

export adv=$ANDROID_VERSION
echo "🔧 正在清理并修改版本字符串..."
rm -f kernel_platform/common/android/abi_gki_protected_exports_* || echo "common 目录下无受保护导出表，无需删除。"
rm -f kernel_platform/msm-kernel/android/abi_gki_protected_exports_* || echo "msm-kernel 目录下无受保护导出表，无需删除。"

# 去除 -dirty 并清理 setlocalversion
sed -i 's/ -dirty//g' kernel_platform/common/scripts/setlocalversion
sed -i 's/ -dirty//g' kernel_platform/msm-kernel/scripts/setlocalversion
sed -i 's/ -dirty//g' kernel_platform/external/dtc/scripts/setlocalversion
sed -i '$i res=$(echo "$res" | sed '\''s/-dirty//g'\'')' kernel_platform/common/scripts/setlocalversion
sed -i '$i res=$(echo "$res" | sed '\''s/-dirty//g'\'')' kernel_platform/msm-kernel/scripts/setlocalversion
sed -i '$i res=$(echo "$res" | sed '\''s/-dirty//g'\'')' kernel_platform/external/dtc/scripts/setlocalversion

if [ "$KERNEL_VERSION" != "6.6" ]; then
  # 6.1 / 5.15 / 5.10 延续旧的版本后缀拼接方式
  sed -i '$s|echo "\$res"|echo "-'"$adv"'-oki-xiaoxiaow"|' kernel_platform/common/scripts/setlocalversion
  sed -i '$s|echo "\$res"|echo "-'"$adv"'-oki-xiaoxiaow"|' kernel_platform/msm-kernel/scripts/setlocalversion
  sed -i '$s|echo "\$res"|echo "-'"$adv"'-oki-xiaoxiaow"|' kernel_platform/external/dtc/scripts/setlocalversion
else
  ESCAPED_SUFFIX=$(printf '%s\n' "-${ANDROID_VERSION}-oki-xiaoxiaow" | sed 's:[\/&]:\\&:g')
  sed -i "s/-4k/${ESCAPED_SUFFIX}/g" kernel_platform/common/arch/arm64/configs/gki_defconfig
  sed -i 's/\${scm_version}//' kernel_platform/common/scripts/setlocalversion
  sed -i 's/\${scm_version}//' kernel_platform/msm-kernel/scripts/setlocalversion
fi

echo "✅ 内核仓库准备完毕并完成版本号清理。"

if [ "$bbg" = "On" ] && [ "$KPM" = "Off" ]; then
    set -e
    cd kernel_platform/common
    echo "🛡️ 正在配置 Baseband-Guard 基带防护..."
    curl -sSL https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh -o setup.sh
    bash setup.sh
    cd ../..
    echo "✅ Baseband-Guard 配置完成。"
fi

# --- 内核个性化定制 ---
# 配置 SukiSU Ultra
echo "⚡ 正在配置 SukiSU Ultra..."
cd kernel_platform
curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/susfs-main/kernel/setup.sh" | bash -s susfs-main

# 获取 KSU 版本信息并写入 Makefile
cd KernelSU
KSU_VERSION_COUNT=$(git rev-list --count main)
export KSUVER=$(expr $KSU_VERSION_COUNT + 37185)

for i in {1..3}; do
  KSU_API_VERSION=$(curl -fsSL "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/susfs-main/kernel/Makefile" | \
    grep -m1 "KSU_VERSION_API :=" | cut -d'=' -f2 | tr -d '[:space:]')
  [ -n "$KSU_API_VERSION" ] && break || sleep 2
done

if [ -z "$KSU_API_VERSION" ]; then
  echo "❌ 错误：未能获取 KSU_API_VERSION" >&2
  exit 1
fi

KSU_COMMIT_HASH=$(git ls-remote https://github.com/SukiSU-Ultra/SukiSU-Ultra.git refs/heads/susfs-main | cut -f1 | cut -c1-8)
KSU_VERSION_FULL="v${KSU_API_VERSION}-${KSU_COMMIT_HASH}-xiaoxiaow"

# 删除旧的 KSU 版本定义
sed -i '/define get_ksu_version_full/,/endef/d' kernel/Makefile
sed -i '/KSU_VERSION_API :=/d' kernel/Makefile
sed -i '/KSU_VERSION_FULL :=/d' kernel/Makefile

# 在 REPO_OWNER := 后插入新的 KSU 版本定义
TMP_FILE=$(mktemp)
while IFS= read -r line; do
  echo "$line" >> "$TMP_FILE"
  if echo "$line" | grep -q 'REPO_OWNER :='; then
    cat >> "$TMP_FILE" <<EOF
define get_ksu_version_full
v\\\$\$1-${KSU_COMMIT_HASH}-xiaoxiaow
endef

KSU_VERSION_API := ${KSU_API_VERSION}
KSU_VERSION_FULL := ${KSU_VERSION_FULL}
EOF
  fi
done < kernel/Makefile
mv "$TMP_FILE" kernel/Makefile

echo "✅ SukiSU Ultra 版本信息配置完成。"
cd ../..
# 回到 $WORKSPACE/kernel_workspace

# 准备 SUSFS 及其他补丁
echo "🔧 正在下载 SUSFS 及相关补丁..."
git clone https://gitlab.com/simonpunk/susfs4ksu.git -b gki-${ANDROID_VERSION}-${KERNEL_VERSION}
git clone https://github.com/Xiaomichael/kernel_patches.git
git clone https://github.com/ShirkNeko/SukiSU_patch.git

cd kernel_platform
echo "📝 正在复制补丁文件..."
cp ../susfs4ksu/kernel_patches/50_add_susfs_in_gki-${ANDROID_VERSION}-${KERNEL_VERSION}.patch ./common/
cp ../susfs4ksu/kernel_patches/fs/* ./common/fs/
cp ../susfs4ksu/kernel_patches/include/linux/* ./common/include/linux/

cp ../kernel_patches/zram/001-lz4.patch ./common/
cp ../kernel_patches/zram/lz4armv8.S ./common/lib
cp ../kernel_patches/zram/002-zstd.patch ./common/

if [ "$lz4kd" = "On" ]; then
  echo "🚀 正在复制 lz4kd 相关补丁..."
  cp -r ../SukiSU_patch/other/zram/lz4k/include/linux/* ./common/include/linux
  cp -r ../SukiSU_patch/other/zram/lz4k/lib/* ./common/lib
  cp -r ../SukiSU_patch/other/zram/lz4k/crypto/* ./common/crypto
  cp -r ../SukiSU_patch/other/zram/lz4k_oplus ./common/lib/
fi

echo "🔧 正在应用补丁..."
cd ./common
patch -p1 < 50_add_susfs_in_gki-${ANDROID_VERSION}-${KERNEL_VERSION}.patch || true
cp ../../kernel_patches/69_hide_stuff.patch ./
patch -p1 -F 3 < 69_hide_stuff.patch || true

# 6.1：应用 lz4 + zstd 补丁
if [ "$lz4kd" = "Off" ] && [ "$KERNEL_VERSION" = "6.1" ]; then
  echo "📦 正在为 6.1 应用 lz4 + zstd 补丁..."
  git apply 001-lz4.patch || true
  patch -p1 < 002-zstd.patch || true
fi

# 6.6：仅应用 lz4 补丁
if [ "$lz4kd" = "Off" ] && [ "$KERNEL_VERSION" = "6.6" ]; then
  echo "📦 正在为 6.6 应用 lz4 补丁..."
  git apply 001-lz4.patch || true
fi

if [ "$lz4kd" = "On" ]; then
  echo "🚀 正在应用 lz4kd / lz4k_oplus 补丁..."
  cp ../../SukiSU_patch/other/zram/zram_patch/${KERNEL_VERSION}/lz4kd.patch ./
  patch -p1 -F 3 < lz4kd.patch || true
  cp ../../SukiSU_patch/other/zram/zram_patch/${KERNEL_VERSION}/lz4k_oplus.patch ./
  patch -p1 -F 3 < lz4k_oplus.patch || true
fi
echo "✅ 所有补丁应用完成。"
cd ../..
# 回到 $WORKSPACE/kernel_workspace

# 6.6 专用 风驰补丁 or OGKI转GKI
if [ "$KERNEL_VERSION" = "6.6" ]; then
  echo "正在拉取风驰补丁"
  if ["$FEIL" = "oneplus_ace5_ultra"]; then
      git clone https://github.com/Numbersf/SCHED_PATCH.git -b "mt6991"
  else
      git clone https://github.com/Numbersf/SCHED_PATCH.git -b "sm8750"
  fi
  cp ./SCHED_PATCH/fengchi_$FEIL.patch ./
  if [[ -f "fengchi_$FEIL.patch" ]]; then
    echo "开始应用风驰补丁"
    dos2unix "fengchi_$FEIL.patch"
    patch -p1 -F 3 < "fengchi_$FEIL.patch"
    echo "完美风驰补丁应用完成"
  else
    echo "该机型暂不支持风驰补丁，正在应用OGKI转GKI补丁"
    sed -i '1iobj-y += hmbird_patch.o' drivers/Makefile
    wget https://github.com/Numbersf/Action-Build/raw/SukiSU-Ultra/patches/hmbird_patch.patch
    echo "⚙️ 正在打OGKI转换GKI补丁"
    patch -p1 -F 3 < hmbird_patch.patch
    echo "✅ OGKI转换GKI_patch完成"
  fi
  cd ../..
fi

# 配置内核编译选项（defconfig）
echo "⚙️ 正在配置内核编译选项 (defconfig)..."
DEFCONFIG_PATH="$WORKSPACE/kernel_workspace/kernel_platform/common/arch/arm64/configs/gki_defconfig"

cat <<EOT >> "$DEFCONFIG_PATH"

#--- SukiSU Ultra & SUSFS 自定义配置 ---
CONFIG_KSU=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SUS_OVERLAYFS=n
CONFIG_KSU_SUSFS_TRY_UMOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MAP=y

# 为 Mountify (backslashxx/mountify) 模块开启必要选项
CONFIG_TMPFS_XATTR=y
CONFIG_TMPFS_POSIX_ACL=y
EOT

if [ "$KPM" = "On" ]; then echo "CONFIG_KPM=y" >> "$DEFCONFIG_PATH"; fi

if [ "$bbg" = "On" ] && [ "$KPM" = "Off" ]; then
  echo "📦 在 defconfig 中启用 BBG..."
  cat <<EOT >> "$DEFCONFIG_PATH"
CONFIG_BBG=y
CONFIG_LSM="landlock,lockdown,yama,loadpin,safesetid,integrity,selinux,smack,tomoyo,apparmor,bpf,baseband_guard"
EOT
fi

if [ "$bbr" = "On" ]; then
  echo "🌐 在 defconfig 中启用 BBR 拥塞控制..."
  cat <<EOT >> "$DEFCONFIG_PATH"
CONFIG_TCP_CONG_ADVANCED=y
CONFIG_TCP_CONG_BBR=y
CONFIG_NET_SCH_FQ=y
CONFIG_TCP_CONG_BIC=n
CONFIG_TCP_CONG_WESTWOOD=n
CONFIG_TCP_CONG_HTCP=n
EOT
fi

if [ "$lz4kd" = "On" ]; then
  echo "📦 在 defconfig 中启用 lz4kd 与写回支持..."
  cat <<EOT >> "$DEFCONFIG_PATH"
CONFIG_CRYPTO_LZ4KD=y
CONFIG_CRYPTO_LZ4K_OPLUS=y
CONFIG_ZRAM_WRITEBACK=y
EOT
fi

# 6.1 & 6.6：开启性能优化 O2
if [ "$KERNEL_VERSION" = "6.1" ] || [ "$KERNEL_VERSION" = "6.6" ]; then
  echo "CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y" >> "$DEFCONFIG_PATH"
fi

if [ "$proxy" = "On" ]; then
  echo "📦 在 defconfig 中添加代理相关网络优化选项..."
  cat <<EOT >> "$DEFCONFIG_PATH"
CONFIG_BPF_STREAM_PARSER=y
CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y
CONFIG_NETFILTER_XT_SET=y
CONFIG_IP_SET=y
CONFIG_IP_SET_MAX=65534
CONFIG_IP_SET_BITMAP_IP=y
CONFIG_IP_SET_BITMAP_IPMAC=y
CONFIG_IP_SET_BITMAP_PORT=y
CONFIG_IP_SET_HASH_IP=y
CONFIG_IP_SET_HASH_IPMARK=y
CONFIG_IP_SET_HASH_IPPORT=y
CONFIG_IP_SET_HASH_IPPORTIP=y
CONFIG_IP_SET_HASH_IPPORTNET=y
CONFIG_IP_SET_HASH_IPMAC=y
CONFIG_IP_SET_HASH_MAC=y
CONFIG_IP_SET_HASH_NETPORTNET=y
CONFIG_IP_SET_HASH_NET=y
CONFIG_IP_SET_HASH_NETNET=y
CONFIG_IP_SET_HASH_NETPORT=y
CONFIG_IP_SET_HASH_NETIFACE=y
CONFIG_IP_SET_LIST_SET=y
CONFIG_IP6_NF_NAT=y
CONFIG_IP6_NF_TARGET_MASQUERADE=y
EOT
fi

if [ "$KERNEL_VERSION" = "5.10" ] || [ "$KERNEL_VERSION" = "5.15" ]; then
  echo "📦 正在为 5.10 / 5.15 系配置 LTO..."
  sed -i 's/^CONFIG_LTO=n/CONFIG_LTO=y/' "$DEFCONFIG_PATH"
  sed -i 's/^CONFIG_LTO_CLANG_FULL=y/CONFIG_LTO_CLANG_THIN=y/' "$DEFCONFIG_PATH"
  sed -i 's/^CONFIG_LTO_CLANG_NONE=y/CONFIG_LTO_CLANG_THIN=y/' "$DEFCONFIG_PATH"
  grep -q '^CONFIG_LTO_CLANG_THIN=y' "$DEFCONFIG_PATH" || echo 'CONFIG_LTO_CLANG_THIN=y' >> "$DEFCONFIG_PATH"
fi

# 跳过安装 uapi 头文件，节省时间
echo "CONFIG_HEADERS_INSTALL=n" >> "$DEFCONFIG_PATH"

# 移除多余的 check_defconfig 步骤
sed -i 's/check_defconfig//' "$WORKSPACE/kernel_workspace/kernel_platform/common/build.config.gki"
echo "✅ defconfig 配置更新完成。"
cd ../..
# 回到 $WORKSPACE

# --- 编译与打包 ---

echo "🔨 开始内核编译..."
cd "$WORKSPACE/kernel_workspace/kernel_platform/common"

MAKE_CMD_COMMON="make -j$(nproc --all) LLVM=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=\"ccache clang\" RUSTC=../../prebuilts/rust/linux-x86/1.73.0b/bin/rustc PAHOLE=../../prebuilts/kernel-build-tools/linux-x86/bin/pahole LD=ld.lld HOSTLD=ld.lld O=out gki_defconfig all"

if [ "$KERNEL_VERSION" = "6.1" ]; then
    export KBUILD_BUILD_TIMESTAMP="Wed Aug 20 07:17:20 UTC 2025"
    export KBUILD_BUILD_VERSION=1
    export PATH="$WORKSPACE/kernel_workspace/kernel_platform/prebuilts/clang/host/linux-x86/clang-r487747c/bin:$PATH"
    eval "$MAKE_CMD_COMMON KCFLAGS+=-O2"
elif [ "$KERNEL_VERSION" = "6.6" ]; then
    export KBUILD_BUILD_VERSION=1
    export PATH="$WORKSPACE/kernel_workspace/kernel_platform/prebuilts/clang/host/linux-x86/clang-r510928/bin:$PATH"
    eval "$MAKE_CMD_COMMON KCFLAGS+=-O2"
elif [ "$KERNEL_VERSION" = "5.15" ]; then
    export PATH="$WORKSPACE/kernel_workspace/kernel_platform/prebuilts/clang/host/linux-x86/clang-r450784e/bin:$PATH"
    eval "$MAKE_CMD_COMMON"
elif [ "$KERNEL_VERSION" = "5.10" ]; then
    export PATH="$WORKSPACE/kernel_workspace/kernel_platform/prebuilts-master/clang/host/linux-x86/clang-r416183b/bin:$PATH"
    eval "make -j$(nproc --all) LLVM_IAS=1 LLVM=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=\"ccache clang\" RUSTC=../../prebuilts/rust/linux-x86/1.73.0b/bin/rustc PAHOLE=../../prebuilts/kernel-build-tools/linux-x86/bin/pahole LD=ld.lld HOSTLD=ld.lld O=out gki_defconfig all"
else
    echo "❌ 不支持的内核版本: $KERNEL_VERSION" && exit 1
fi

echo "📊 当前 ccache 统计信息如下:"
ccache -s
echo "✅ 内核编译完成。"
cd "$WORKSPACE"

# 使用 AnyKernel3 进行打包
echo "📦 正在获取 AnyKernel3 并准备打包..."
git clone https://github.com/Xiaomichael/AnyKernel3 --depth=1
rm -rf ./AnyKernel3/.git

IMAGE_PATH=$(find "$WORKSPACE/kernel_workspace/kernel_platform/common/out/" -name "Image" | head -n 1)
if [ -z "$IMAGE_PATH" ]; then echo "❌ 严重错误：编译完成后未找到 Kernel Image！" && exit 1; fi

echo "✅ 已找到 Kernel Image: $IMAGE_PATH"
cp "$IMAGE_PATH" ./AnyKernel3/Image

# 如启用 KPM，则对 Image 进行补丁处理
if [ "$KPM" = 'On' ]; then
    echo "🧩 正在对内核 Image 应用 KPM 补丁..."
    mkdir -p kpm_patch_temp && cd kpm_patch_temp
    curl -LO https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/download/0.12.2/patch_linux
    chmod +x patch_linux
    cp "$WORKSPACE/AnyKernel3/Image" ./Image
    ./patch_linux
    mv oImage "$WORKSPACE/AnyKernel3/Image"
    cd .. && rm -rf kpm_patch_temp
    echo "✅ KPM 补丁应用完成。"
fi

# --- 构建结果输出 ---

if [ "$lz4kd" = "On" ]; then
  ARTIFACT_NAME="${FEIL}_SukiSU_Ultra_lz4kd_${KSUVER}"
elif [ "$KERNEL_VERSION" = "6.1" ]; then
  ARTIFACT_NAME="${FEIL}_SukiSU_Ultra_lz4_zstd_${KSUVER}"
elif [ "$KERNEL_VERSION" = "6.6" ]; then
  ARTIFACT_NAME="${FEIL}_SukiSU_Ultra_lz4_${KSUVER}"
else
  ARTIFACT_NAME="${FEIL}_SukiSU_Ultra_${KSUVER}"
fi
FINAL_ZIP_NAME="${ARTIFACT_NAME}.zip"

echo "📦 正在创建最终可刷入压缩包: ${FINAL_ZIP_NAME}..."
cd AnyKernel3 && zip -q -r9 "../${FINAL_ZIP_NAME}" ./* && cd ..

# --- 构建总结 ---
echo ""
echo "================================================="
echo "                  构建完成！"
echo "================================================="
echo "-> 可刷入内核压缩包路径: $WORKSPACE/${FINAL_ZIP_NAME}"

ZRAM_KO_PATH=$(find "$WORKSPACE/kernel_workspace/kernel_platform/common/out/" -name "zram.ko" | head -n 1)
if [ -n "$ZRAM_KO_PATH" ]; then
    cp "$ZRAM_KO_PATH" "$WORKSPACE/"
    echo "-> zram.ko 模块路径: $WORKSPACE/zram.ko"
fi

echo "================================================="
echo ""
