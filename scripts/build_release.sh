#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_dir="$(cd -- "${script_dir}/.." && pwd -P)"
project_file="${project_dir}/MacPowerFlow.xcodeproj"
scheme="MacPowerFlow"
product_name="MacPowerFlow.app"
archive_name="MacPowerFlow-1.5.2.zip"
dist_dir="${project_dir}/dist"
backup_dir="${project_dir}/.build/previous-releases"
output_archive="${dist_dir}/${archive_name}"

for command_name in git tar xcodebuild codesign ditto xattr; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        echo "错误：找不到 ${command_name}，请安装并选择完整的 Xcode。" >&2
        exit 1
    fi
done

if [[ ! -d "${project_file}" ]]; then
    echo "错误：找不到工程 ${project_file}" >&2
    exit 1
fi

if [[ "$(uname -m)" != "arm64" ]]; then
    echo "错误：MacPowerFlow 当前只支持在 Apple Silicon Mac 上构建。" >&2
    exit 1
fi

temp_base="${TMPDIR:-/tmp}"
temp_base="${temp_base%/}"
if [[ -z "${temp_base}" ]]; then
    temp_base="/tmp"
fi

build_root="$(mktemp -d "${temp_base}/MacPowerFlow.release.XXXXXX")"
source_root="${build_root}/Source"
derived_data="${build_root}/DerivedData"
staged_app="${build_root}/${product_name}"
staged_archive="${build_root}/${archive_name}"

cleanup() {
    case "${build_root}" in
        "${temp_base}"/MacPowerFlow.release.*)
            if [[ -d "${build_root}" ]]; then
                find "${build_root}" -depth -delete 2>/dev/null || true
            fi
            ;;
    esac
}
trap cleanup EXIT

echo "正在把构建所需源码暂存到独立目录…"
mkdir -p "${source_root}"
source_items=(MacPowerFlow.xcodeproj PowerFlow Shared Helper Installer)

# Documents may be backed by File Provider and can contain evicted, dataless
# copies of otherwise unchanged tracked files. Stage the committed baseline
# directly from Git's object database, then apply the current tracked diff.
# This keeps local release builds deterministic without blocking on iCloud.
git -C "${project_dir}" archive --format=tar HEAD -- "${source_items[@]}" \
    | tar -xf - -C "${source_root}"
git -C "${project_dir}" diff --binary HEAD -- "${source_items[@]}" \
    | git -C "${source_root}" apply --binary --whitespace=nowarn

# Include any intentional, non-ignored new source file in the working tree.
while IFS= read -r -d '' untracked_source; do
    mkdir -p "${source_root}/$(dirname -- "${untracked_source}")"
    ditto --noextattr --noqtn \
        "${project_dir}/${untracked_source}" \
        "${source_root}/${untracked_source}"
done < <(
    git -C "${project_dir}" ls-files \
        --others --exclude-standard -z -- "${source_items[@]}"
)

echo "正在构建 MacPowerFlow Release（arm64）…"
xcodebuild \
    -quiet \
    -project "${source_root}/MacPowerFlow.xcodeproj" \
    -scheme "${scheme}" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "${derived_data}" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    build

built_app="${derived_data}/Build/Products/Release/${product_name}"
if [[ ! -d "${built_app}" ]]; then
    echo "错误：构建完成，但没有找到 ${built_app}" >&2
    exit 1
fi

ditto "${built_app}" "${staged_app}"

echo "正在进行 ad-hoc 签名…"
xattr -cr "${staged_app}"
helper_path="${staged_app}/Contents/Library/LaunchServices/com.llf.MacPowerFlow.PrivilegedHelper"
installer_path="${staged_app}/Contents/Library/LaunchServices/com.llf.MacPowerFlow.PrivilegedInstaller"

if [[ ! -f "${helper_path}" || ! -f "${installer_path}" ]]; then
    echo "错误：应用包缺少增强服务或首次安装器。" >&2
    exit 1
fi

codesign \
    --force \
    --sign - \
    --identifier com.llf.MacPowerFlow.PrivilegedHelper \
    --options runtime \
    --timestamp=none \
    "${helper_path}"
codesign \
    --force \
    --sign - \
    --identifier com.llf.MacPowerFlow.PrivilegedInstaller \
    --options runtime \
    --timestamp=none \
    "${installer_path}"
codesign \
    --force \
    --sign - \
    --identifier com.llf.MacPowerFlow \
    --options runtime \
    --timestamp=none \
    "${staged_app}"
codesign --verify --strict --verbose=2 "${helper_path}"
codesign --verify --strict --verbose=2 "${installer_path}"
codesign --verify --strict --verbose=2 "${staged_app}"
ditto -c -k \
    --keepParent \
    --norsrc \
    --noextattr \
    --noqtn \
    --noacl \
    "${staged_app}" \
    "${staged_archive}"

mkdir -p "${dist_dir}"
mkdir -p "${backup_dir}"
backup_archive=""
legacy_output_app="${dist_dir}/${product_name}"
if [[ -e "${legacy_output_app}" ]]; then
    timestamp="$(date +%Y%m%d-%H%M%S)"
    legacy_backup_app="${backup_dir}/MacPowerFlow.previous-${timestamp}-$$.app"
    mv "${legacy_output_app}" "${legacy_backup_app}"
    echo "旧的裸应用已保留为 ${legacy_backup_app}"
fi
if [[ -e "${output_archive}" ]]; then
    timestamp="$(date +%Y%m%d-%H%M%S)"
    backup_archive="${backup_dir}/MacPowerFlow.previous-${timestamp}-$$.zip"
    mv "${output_archive}" "${backup_archive}"
    echo "已有压缩包已保留为 ${backup_archive}"
fi

if ! mv "${staged_archive}" "${output_archive}"; then
    if [[ -n "${backup_archive}" && -e "${backup_archive}" && ! -e "${output_archive}" ]]; then
        mv "${backup_archive}" "${output_archive}"
    fi
    echo "错误：无法发布 ${output_archive}" >&2
    exit 1
fi

archive_check="${build_root}/ArchiveCheck"
mkdir -p "${archive_check}"
ditto -x -k --noextattr "${output_archive}" "${archive_check}"
unpacked_app="${archive_check}/${product_name}"
codesign --verify --strict --verbose=2 \
    "${unpacked_app}/Contents/Library/LaunchServices/com.llf.MacPowerFlow.PrivilegedHelper"
codesign --verify --strict --verbose=2 \
    "${unpacked_app}/Contents/Library/LaunchServices/com.llf.MacPowerFlow.PrivilegedInstaller"
codesign --verify --strict --verbose=2 "${unpacked_app}"

echo "构建完成并通过解包验签：${output_archive}"
