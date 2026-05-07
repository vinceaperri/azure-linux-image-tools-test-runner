#!/usr/bin/env bash
#
# A comprehensive test runner for azure-linux-image-tools.
# This script runs all unit tests, functional tests, and VM tests for imagecustomizer and osmodifier.
#
# It does not cover initial machine setup.
#
set -euo pipefail

# Azure resources used to download base images.
# Override via environment variables.
# Required when base images need to be downloaded.
AZURE_LINUX_IMAGE_TOOLS_SUBSCRIPTION_ID="${AZURE_LINUX_IMAGE_TOOLS_SUBSCRIPTION_ID:-}"
AZURE_LINUX_IMAGE_TOOLS_STORAGE="${AZURE_LINUX_IMAGE_TOOLS_STORAGE:-}"
AZURE_LINUX_IMAGE_TOOLS_CONTAINER="${AZURE_LINUX_IMAGE_TOOLS_CONTAINER:-}"

case "$(uname -m)" in
    x86_64) HOST_ARCH="amd64" ;;
    *)      HOST_ARCH="arm64" ;;
esac

SCRIPT_DIR_SYM="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR_REAL="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
TEST_DOC_COMPLETENESS_SCRIPT="$SCRIPT_DIR_REAL/test-documentation-completeness.py"
CHECK_CONFIG_TEST_NAMES_SCRIPT="$SCRIPT_DIR_REAL/check-config-test-names.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
RUN_DOCS=true
RUN_BUILD=true
RUN_UNIT_TESTS=true
RUN_IMAGE_TESTS=true
RUN_FUNCTIONAL_TESTS=true
RUN_VM_TESTS=true
RUN_IMAGECUSTOMIZER=true
RUN_OSMODIFIER=true
GO_TEST_TIMEOUT="120m"
GO_TEST_RUN_VALUE="all" # Regex pattern to filter tests (passed to go test -run), or all to not filter
GO_TEST_FILES=() # Relative paths to _test.go files to extract Test functions from
PYTEST_K_VALUE="all" # Expression to filter pytest tests (passed to pytest -k), or all to not filter

# Distro image flags (all enabled by default)
USE_AZURE_LINUX_20=true
USE_AZURE_LINUX_30=true
USE_AZURE_LINUX_40=true
USE_UBUNTU_2204=true
USE_UBUNTU_2404=true

# Test image paths (required for functional/VM tests)
AZURE_LINUX_2_CORE_LEGACY_VHD=""
AZURE_LINUX_2_CORE_EFI_VHDX=""
AZURE_LINUX_3_CORE_LEGACY_VHD=""
AZURE_LINUX_3_CORE_EFI_VHDX=""
AZURE_LINUX_4_CORE_LEGACY_VHD=""
AZURE_LINUX_4_CORE_EFI_VHDX=""
UBUNTU_AZURE_CLOUD_2204=""
UBUNTU_AZURE_CLOUD_2404=""
FAIL_FAST="n"
SSH_PRIVATE_KEY_FILE="$HOME/.ssh/id_ed25519"
KEEP_ENVIRONMENT="n"
SERVE_UNIT_COVERAGE=false

IMAGE_CUSTOMIZER_CONTAINER_TAG="imagecustomizer:dev"
CONFIG_DIR=""
REPO_DIR=""
TEST_DIR=""
API_COVERAGE_OUTPUT=""
LIB_COVERAGE_OUTPUT=""
UNIT_COVERAGE_OUTPUT=""
ORIGINAL_SUBSCRIPTION=""
LOG_LEVEL="debug"

if command -v ukify &> /dev/null; then
    UKIFY_PATH=$(which ukify)
    UKIFY_BAK="${UKIFY_PATH}.bak"
else
    UKIFY_PATH=""
    UKIFY_BAK=""
fi

print_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Comprehensive test runner for azure-linux-image-tools.

OPTIONS:
    -h, --help                      Show this help message
    --repo-dir PATH                 Path to the azure-linux-image-tools repository root.
                                    Default: auto-detected from script location ('.' or './azure-linux-image-tools')
    --test-dir PATH                 Path to the test directory (for base images, etc.).
                                    Default: 'test' beside the repository directory
    -t, --go-test-timeout DURATION  Timeout for go tests.
                                    Default: 120m.
                                    Unit and Functional tests only.
                                    See go test -timeout flag for details.
    -r, --go-test-run REGEXP        Run only tests matching regular expression.
                                    If 'all', no filtering will be done.
                                    Default: 'all'.
                                    Functional tests only.
                                    See go test -run flag for details.
                                    Mutually incompatible with -g/--go-test-files.
    -g, --go-test-files FILE...     Extract Test functions from the specified _test.go
                                    files (relative paths) and construct a -run filter.
                                    Can be specified multiple times.
                                    Mutually incompatible with -r/--go-test-run.
    -k, --pytest-k EXPR             Run only pytests matching this expression.
                                    If 'all', no filtering will be done.
                                    Default: 'all'.
                                    VM tests only.
                                    See pytest -k flag for details.
    -x, --fail-fast                 Stop the tests after the first failure

Build Options:
    -d, --docs   Only build documentation and run documentation checks
    --no-docs    Skip documentation build and checks
    -b, --build  Only build binaries without running tests
    --no-build   Skip building binaries

Test Selection:
    -u, --unit-tests        Only run unit tests
    --no-unit-tests         Skip unit tests
    -i, --image-tests       Only run image tests
    --no-image-tests        Skip image tests
    -f, --functional-tests  Only run functional tests
    --no-functional-tests   Skip functional tests
    -m, --vm-tests          Only run VM tests (requires QEMU/KVM)
    --no-vm-tests           Skip VM tests
    -a, --all               Run all tests (unit + functional + VM) [default]

    Short flags -b, -o, -u, -f, -m can be combined (e.g., -buf for build + unit + functional).

Test Options:
    --config-dir DIR             Directory containing test configuration files
    --ssh-key PATH               SSH private key file (default: ~/.ssh/id_ed25519)
    --keep-environment           Keep test environment after completion
    --unit-coverage-output PATH  Output path for unit test coverage report (must end with .cov)
    --lib-coverage-output PATH   Output path for imagecustomizerlib coverage report (must end with .cov)
                                     (.log and .txt files will be saved alongside .cov file)
    --api-coverage-output PATH   Output path for imagecustomizerapi coverage report (must end with .cov)
                                     (.log and .txt files will be saved alongside .cov file)
    -s,--serve-unit-coverage     Generate HTML unit test coverage report and serves it via HTTP
                                     (.html will be saved along .cov, .log, and .txt files)

Component Selection:
    --imagecustomizer           Only build and run imagecustomizer tests
    --no-imagecustomizer        Skip imagecustomizer build and tests
    --osmodifier                Only build and run osmodifier tests
    --no-osmodifier             Skip osmodifier build and tests

Distro Image Selection:
    --azure-linux-20            Only use Azure Linux 2.0 base image in functional tests
    --no-azure-linux-20         Skip Azure Linux 2.0 base image in functional tests
    --azure-linux-30            Only use Azure Linux 3.0 base image in functional tests
    --no-azure-linux-30         Skip Azure Linux 3.0 base image in functional tests
    --azure-linux-40            Only use Azure Linux 4.0 base image in functional tests
    --no-azure-linux-40         Skip Azure Linux 4.0 base image in functional tests
    --azure-linux               Shortcut for --azure-linux-20, --azure-linux-30, and --azure-linux-40
    --no-azure-linux            Shortcut for --no-azure-linux-20, --no-azure-linux-30, and --no-azure-linux-40
    --ubuntu-2204               Only use Ubuntu 22.04 base image in functional tests
    --no-ubuntu-2204            Skip Ubuntu 22.04 base image in functional tests
    --ubuntu-2404               Only use Ubuntu 24.04 base image in functional tests
    --no-ubuntu-2404            Skip Ubuntu 24.04 base image in functional tests
    --ubuntu                    Shortcut for --ubuntu-2204 and --ubuntu-2404
    --no-ubuntu                 Shortcut for --no-ubuntu-2204 and --no-ubuntu-2404

EXAMPLES:
    # Run unit tests only
    $0 -u

    # Build and run unit tests
    $0 -bu

    # Run functional tests (base images auto-downloaded)
    $0 -f

    # Run all tests (base images auto-downloaded)
    $0

    # Run VM tests filtered to a specific test
    $0 -m -k test_create_fedora

EOF
}

log_info() {
    echo -e "$BLUE[INFO]$NC $1"
}

log_success() {
    echo -e "$GREEN[SUCCESS]$NC $1"
}

log_error() {
    echo -e "$RED[ERROR]$NC $1"
}

log_section() {
    echo ""
    echo -e "$BLUE========================================$NC"
    echo -e "$BLUE$1$NC"
    echo -e "$BLUE========================================$NC"
}

log_info_and_run() {
    local description="$1"
    shift

    log_info "$description [$*]"
    "$@"
}

check_root() {
    if [[ $EUID -eq 0 ]]; then
        log_error "This script cannot be run as root. It will use sudo for privileged operations."
        exit 1
    fi
}

patch_ukify() {
    local patch_file="./.github/workflows/scripts/ukify-fix-insertion-of-padding-in-merged-sections.patch"
    if [[ ! -e "$patch_file" ]]; then
        log_info "ukify patch file not found, skipping ukify patching"
        return
    fi

    # Skip patching if the patch is already applied.
    if sudo patch --dry-run -R "$UKIFY_PATH" "$patch_file" &>/dev/null; then
        log_info "ukify patch already applied, skipping"
        return
    fi

    log_info "Applying ukify patch to fix insertion of padding in merged sections"
    sudo cp "$UKIFY_PATH" "$UKIFY_BAK"
    sudo patch "$UKIFY_PATH" "$patch_file"
}

ensure_imagecustomizer_test_util_for_distro() {
    local distro="$1"
    local version="$2"

    local arch_arg=""
    if "$DOWNLOAD_TEST_UTILS_SCRIPT" -h 2>&1 | grep -qE -- '-a '; then
        # If the script supports architecture argument, set it based on host architecture
        arch_arg="-a $HOST_ARCH"
    fi

    tools_file="$DOWNLOAD_TEST_UTILS_DIR/build/tools-$distro-$version.tar.gz"
    rpms_dir="$DOWNLOAD_TEST_UTILS_DIR/downloadedrpms/$distro/$version"
    if [[ ! -f "$tools_file" || ! -d "$rpms_dir" ]]; then
        log_info_and_run \
            "Downloading test utils for $distro $version" \
            "$DOWNLOAD_TEST_UTILS_SCRIPT" $arch_arg -d "$distro" -t "$version" -s true
    else
        log_info "Test utils for $distro $version already exist, skipping download."
    fi
}

ensure_imagecustomizer_test_utils() {
    ensure_imagecustomizer_test_util_for_distro "azurelinux" "3.0"
    ensure_imagecustomizer_test_util_for_distro "azurelinux" "4.0"
    ensure_imagecustomizer_test_util_for_distro "fedora" "42"
}

# Verify that the Azure variables required to download base images are set.
require_azure_download_vars() {
    local missing=()
    [[ -z "$AZURE_LINUX_IMAGE_TOOLS_SUBSCRIPTION_ID" ]] && missing+=("AZURE_LINUX_IMAGE_TOOLS_SUBSCRIPTION_ID")
    [[ -z "$AZURE_LINUX_IMAGE_TOOLS_STORAGE" ]]         && missing+=("AZURE_LINUX_IMAGE_TOOLS_STORAGE")
    [[ -z "$AZURE_LINUX_IMAGE_TOOLS_CONTAINER" ]]       && missing+=("AZURE_LINUX_IMAGE_TOOLS_CONTAINER")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Environment variables are required to download base images but are not set: ${missing[*]}"
        exit 1
    fi
}

# Download a base image from Azure DevOps pipeline artifacts
ensure_base_image() {
    local distro="$1"
    local variant="$2"
    local version="$3"
    local arch="$4"
    local format="$5"
    local output_path="$BASE_IMAGES_DIR/$distro-$variant-$version-$arch.$format"

    # Skip if already downloaded
    if [[ -f "$output_path" ]]; then
        log_info "Base image already exists: $output_path"
        return 0
    fi

    require_azure_download_vars

    ORIGINAL_SUBSCRIPTION=$(az account show --query id -o tsv)
    az account set --subscription "$AZURE_LINUX_IMAGE_TOOLS_SUBSCRIPTION_ID"

    log_info_and_run \
        "Downloading base image: $output_path" \
        "$REPO_DIR/.github/workflows/scripts/download-image.sh" \
            "$AZURE_LINUX_IMAGE_TOOLS_STORAGE" \
            "$AZURE_LINUX_IMAGE_TOOLS_CONTAINER" \
            "$distro/$variant-$format-$version-$arch" \
            "$BASE_IMAGES_DIR"

    az account set --subscription "$ORIGINAL_SUBSCRIPTION"
    ORIGINAL_SUBSCRIPTION=""

    mv "$BASE_IMAGES_DIR/image.$format" "$output_path"
}

# Ensure all base images needed for testing are downloaded
ensure_base_images() {
    # Download core-efi (VHDX) and bare-metal (VHD) images for Azure Linux 2.0 and 3.0
    if [[ "$USE_AZURE_LINUX_20" == "true" ]]; then
        if [[ "$HOST_ARCH" == "amd64" ]]; then
            ensure_base_image "azure-linux" "core-legacy" "2.0" "$HOST_ARCH" "vhd"
            AZURE_LINUX_2_CORE_LEGACY_VHD="$BASE_IMAGES_DIR/azure-linux-core-legacy-2.0-$HOST_ARCH.vhd"
        fi

        ensure_base_image "azure-linux" "core-efi" "2.0" "$HOST_ARCH" "vhdx"
        AZURE_LINUX_2_CORE_EFI_VHDX="$BASE_IMAGES_DIR/azure-linux-core-efi-2.0-$HOST_ARCH.vhdx"
    fi

    if [[ "$USE_AZURE_LINUX_30" == "true" ]]; then
        if [[ "$HOST_ARCH" == "amd64" ]]; then
            ensure_base_image "azure-linux" "core-legacy" "3.0" "$HOST_ARCH" "vhd"
            AZURE_LINUX_3_CORE_LEGACY_VHD="$BASE_IMAGES_DIR/azure-linux-core-legacy-3.0-$HOST_ARCH.vhd"
        fi

        ensure_base_image "azure-linux" "core-efi" "3.0" "$HOST_ARCH" "vhdx"
        AZURE_LINUX_3_CORE_EFI_VHDX="$BASE_IMAGES_DIR/azure-linux-core-efi-3.0-$HOST_ARCH.vhdx"
    fi

    if [[ "$USE_AZURE_LINUX_40" == "true" ]]; then
        if [[ "$HOST_ARCH" == "amd64" ]]; then
            ensure_base_image "azure-linux" "core-legacy" "4.0" "$HOST_ARCH" "vhd"
            AZURE_LINUX_4_CORE_LEGACY_VHD="$BASE_IMAGES_DIR/azure-linux-core-legacy-4.0-$HOST_ARCH.vhd"
        fi

        ensure_base_image "azure-linux" "core-efi" "4.0" "$HOST_ARCH" "vhdx"
        AZURE_LINUX_4_CORE_EFI_VHDX="$BASE_IMAGES_DIR/azure-linux-core-efi-4.0-$HOST_ARCH.vhdx"
    fi

    # Download Ubuntu cloud images
    if [[ "$USE_UBUNTU_2204" == "true" ]]; then
        ensure_base_image "ubuntu" "azure-cloud" "22.04" "$HOST_ARCH" "vhdx"
        UBUNTU_AZURE_CLOUD_2204="$BASE_IMAGES_DIR/ubuntu-azure-cloud-22.04-$HOST_ARCH.vhdx"
    fi

    if [[ "$USE_UBUNTU_2404" == "true" ]]; then
        ensure_base_image "ubuntu" "azure-cloud" "24.04" "$HOST_ARCH" "vhdx"
        UBUNTU_AZURE_CLOUD_2404="$BASE_IMAGES_DIR/ubuntu-azure-cloud-24.04-$HOST_ARCH.vhdx"
    fi
}

validate_base_images() {
    local failed=0

    if [[ -e "$AZURE_LINUX_2_CORE_LEGACY_VHD" ]]; then
        sudo "$SCRIPT_DIR_REAL/validate-image.sh" "azure-linux/core-legacy-vhd-2.0-$HOST_ARCH" "$AZURE_LINUX_2_CORE_LEGACY_VHD" || {
            log_error "Validation failed for $AZURE_LINUX_2_CORE_LEGACY_VHD"
            failed=1
        }
    fi

    if [[ -e "$AZURE_LINUX_2_CORE_EFI_VHDX" ]]; then
        sudo "$SCRIPT_DIR_REAL/validate-image.sh" "azure-linux/core-efi-vhdx-2.0-$HOST_ARCH" "$AZURE_LINUX_2_CORE_EFI_VHDX" || {
            log_error "Validation failed for $AZURE_LINUX_2_CORE_EFI_VHDX"
            failed=1
        }
    fi

    if [[ -e "$AZURE_LINUX_3_CORE_LEGACY_VHD" ]]; then
        sudo "$SCRIPT_DIR_REAL/validate-image.sh" "azure-linux/core-legacy-vhd-3.0-$HOST_ARCH" "$AZURE_LINUX_3_CORE_LEGACY_VHD" || {
            log_error "Validation failed for $AZURE_LINUX_3_CORE_LEGACY_VHD"
            failed=1
        }
    fi

    if [[ -e "$AZURE_LINUX_3_CORE_EFI_VHDX" ]]; then
        sudo "$SCRIPT_DIR_REAL/validate-image.sh" "azure-linux/core-efi-vhdx-3.0-$HOST_ARCH" "$AZURE_LINUX_3_CORE_EFI_VHDX" || {
            log_error "Validation failed for $AZURE_LINUX_3_CORE_EFI_VHDX"
            failed=1
        }
    fi

    if [[ -e "$AZURE_LINUX_4_CORE_LEGACY_VHD" ]]; then
        sudo "$SCRIPT_DIR_REAL/validate-image.sh" "azure-linux/core-legacy-vhd-4.0-$HOST_ARCH" "$AZURE_LINUX_4_CORE_LEGACY_VHD" || {
            log_error "Validation failed for $AZURE_LINUX_4_CORE_LEGACY_VHD"
            failed=1
        }
    fi

    if [[ -e "$AZURE_LINUX_4_CORE_EFI_VHDX" ]]; then
        sudo "$SCRIPT_DIR_REAL/validate-image.sh" "azure-linux/core-efi-vhdx-4.0-$HOST_ARCH" "$AZURE_LINUX_4_CORE_EFI_VHDX" || {
            log_error "Validation failed for $AZURE_LINUX_4_CORE_EFI_VHDX"
            failed=1
        }
    fi

    if [[ -e "$UBUNTU_AZURE_CLOUD_2204" ]]; then
        sudo "$SCRIPT_DIR_REAL/validate-image.sh" "ubuntu/azure-cloud-vhdx-22.04-$HOST_ARCH" "$UBUNTU_AZURE_CLOUD_2204" || {
            log_error "Validation failed for $UBUNTU_AZURE_CLOUD_2204"
            failed=1
        }
    fi

    if [[ -e "$UBUNTU_AZURE_CLOUD_2404" ]]; then
        sudo "$SCRIPT_DIR_REAL/validate-image.sh" "ubuntu/azure-cloud-vhdx-24.04-$HOST_ARCH" "$UBUNTU_AZURE_CLOUD_2404" || {
            log_error "Validation failed for $UBUNTU_AZURE_CLOUD_2404"
            failed=1
        }
    fi

    return "$failed"
}

format_go() {
    log_section "Running Go Format"

    log_info_and_run \
        "Formatting Go code" \
        make -C "$TOOLKIT_DIR" go-fmt-all

    log_success "Go format completed"
}

check_go_modules() {
    log_section "Checking Go Modules"

    log_info_and_run \
        "Running go mod tidy" \
        make -C "$TOOLKIT_DIR" go-mod-tidy

    # Check if go.mod or go.sum changed
    local modchanges sumchanges
    modchanges=$(git -C "$REPO_DIR" diff go.mod || true)
    sumchanges=$(git -C "$REPO_DIR" diff go.sum || true)

    if [[ -n "$modchanges$sumchanges" ]]; then
        log_error "Module files out of date!"
        git -C "$REPO_DIR" diff go.mod
        git -C "$REPO_DIR" diff go.sum
        exit 1
    fi

    log_success "Go modules check completed"
}

update_schema() {
    log_section "Updating Schema"

    log_info_and_run \
        "Updating schema.json" \
        make -C "$TOOLS_DIR/imagecustomizerschemacli/"

    log_success "Schema update completed"
}

ensure_vm_tests_venv() {
    if [[ ! -d "$VMTESTS_DIR/build/venv" ]]; then
        log_info_and_run \
            "Creating VM tests Python virtual environment" \
            make -C "$VMTESTS_DIR" create-venv
    else
        log_info_and_run \
            "Updating VM tests Python virtual environment" \
            make -C "$VMTESTS_DIR" update-venv
    fi
}

check_vm_tests_formatting() {
    log_section "Checking VMTests Formatting"

    log_info_and_run \
        "Fixing VM tests (isort and black)" \
        make -C "$VMTESTS_DIR" fix

    log_info_and_run \
        "Checking VM tests (mypy, flake, black, and isort)" \
        make -C "$VMTESTS_DIR" check

    log_success "VMTests formatting check completed"
}

check_docs() {
    log_section "Checking Documentation"

    local docs_dir="$REPO_DIR/docs"

    (
        cd "$docs_dir"

        log_info_and_run \
            "Installing Ruby dependencies" \
            env BUNDLE_PATH=vendor/bundle bundle install

        log_info_and_run \
            "Building Jekyll site" \
            env BUNDLE_PATH=vendor/bundle bundle exec jekyll build

        log_info_and_run \
            "Running HTML proofer" \
            env BUNDLE_PATH=vendor/bundle bundle exec htmlproofer \
                --disable-external \
                --assume_extension '.html' \
                ./_site

        log_info_and_run \
            "Running doc completeness check" \
            "$TEST_DOC_COMPLETENESS_SCRIPT" --repo-dir "$REPO_DIR" -k "$PYTEST_K_VALUE" # Technically unittest
    )

    log_success "Documentation check completed"
}

build_tool() {
    local tool_name="$1"
    local output_file="$2"
    local ignore_skipped_tests_file="$3"

    local build_id="build-$tool_name"

    mkdir -p "$(dirname "$output_file")"

    local exit_code=0
    set +o pipefail
    log_info_and_run \
            "Building tool(s)" \
            sudo make -B -C "$TOOLKIT_DIR" "$tool_name" 2>&1 | \
        tee "$output_file"
    exit_code=${PIPESTATUS[0]}
    set -o pipefail

    check_for_failed_tests "$output_file" "$build_id"

    if [[ "$exit_code" -ne 0 ]]; then
        log_error "Building $tool_name failed with exit code $exit_code"
        exit "$exit_code"
    fi

    check_for_skipped_tests "$output_file" "$build_id" "$ignore_skipped_tests_file"
}

build_tools() {
    log_section "Building Tools"

    if [[ "$RUN_IMAGECUSTOMIZER" == "true" ]]; then
        mkdir -p "$(dirname "$BUILD_IMAGECUSTOMIZER_IGNORE_SKIPPED_TESTS_FILE")"

        cp "$CONFIG_DIR/tests-disabled-for-short-mode.txt" "$BUILD_IMAGECUSTOMIZER_IGNORE_SKIPPED_TESTS_FILE"
        cat "$CONFIG_DIR/tests-requiring-download-rpms-dir.txt" >> "$BUILD_IMAGECUSTOMIZER_IGNORE_SKIPPED_TESTS_FILE"
        cat "$CONFIG_DIR/tests-requiring-base-image.txt" >> "$BUILD_IMAGECUSTOMIZER_IGNORE_SKIPPED_TESTS_FILE"

        build_tool "imagecustomizer-targz" "$BUILD_IMAGECUSTOMIZER_OUTPUT" "$BUILD_IMAGECUSTOMIZER_IGNORE_SKIPPED_TESTS_FILE"

        mkdir -p "$(dirname "$BUILD_CONTAINER_OUTPUT")"

        local container_build_exit_code=0
        set +o pipefail
        log_info_and_run \
                "Building container" \
                "$TOOLS_DIR/imagecustomizer/container/build-container.sh" \
                    -a $HOST_ARCH -t "$IMAGE_CUSTOMIZER_CONTAINER_TAG" 2>&1 | \
            tee -a "$BUILD_CONTAINER_OUTPUT"
        container_build_exit_code=${PIPESTATUS[0]}
        set -o pipefail

        check_for_failed_tests "$BUILD_CONTAINER_OUTPUT" "build-container"

        if [[ "$container_build_exit_code" -ne 0 ]]; then
            log_error "Container build failed with exit code $container_build_exit_code"
            exit "$container_build_exit_code"
        fi

        check_for_skipped_tests "$BUILD_CONTAINER_OUTPUT" "build-container" ""
    fi

    if [[ "$RUN_OSMODIFIER" == "true" ]]; then
        mkdir -p "$(dirname "$BUILD_OSMODIFIER_IGNORE_SKIPPED_TESTS_FILE")"

        cp "$CONFIG_DIR/tests-disabled-for-short-mode.txt" "$BUILD_OSMODIFIER_IGNORE_SKIPPED_TESTS_FILE"
        cat "$CONFIG_DIR/tests-requiring-download-rpms-dir.txt" >> "$BUILD_OSMODIFIER_IGNORE_SKIPPED_TESTS_FILE"
        cat "$CONFIG_DIR/tests-requiring-base-image.txt" >> "$BUILD_OSMODIFIER_IGNORE_SKIPPED_TESTS_FILE"

        build_tool "go-osmodifier" "$BUILD_OSMODIFIER_OUTPUT" "$BUILD_OSMODIFIER_IGNORE_SKIPPED_TESTS_FILE"
    fi

    log_success "Build completed"
}

check_config() {
    $CHECK_CONFIG_TEST_NAMES_SCRIPT --config-dir "$CONFIG_DIR"
}

run_unit_tests() {
    log_section "Running Unit Tests"

    local test_args="-v -timeout $GO_TEST_TIMEOUT"
    if [[ "$GO_TEST_RUN_VALUE" != "all" ]]; then
        test_args+=" -run $GO_TEST_RUN_VALUE"
    fi
    if [[ "$FAIL_FAST" == "y" ]]; then
        test_args+=" -failfast"
    fi

    mkdir -p "$(dirname "$UNIT_COVERAGE_OUTPUT")"

    # Run all toolkit unit tests with coverage
    # Use sudo because previous tests may have left root-owned test artifacts that cause permission issues.
    local exit_code=0
    set +o pipefail
    log_info_and_run \
            "Running all toolkit unit tests with coverage" \
            sudo go test -C "$TOOLS_DIR" \
                $test_args \
                -coverprofile="$UNIT_COVERAGE_OUTPUT" \
                -covermode=count \
                -coverpkg=./... \
                ./... 2>&1 | \
        tee "$UNIT_COVERAGE_OUTPUT_TXT"
    exit_code=${PIPESTATUS[0]}
    set -o pipefail

    check_for_failed_tests "$UNIT_COVERAGE_OUTPUT_TXT" "unit tests"

    if [[ "$exit_code" -ne 0 ]]; then
        log_error "Unit tests failed with exit code $exit_code"
        exit "$exit_code"
    fi

    cp "$CONFIG_DIR/tests-requiring-download-rpms-dir.txt" "$UNIT_IGNORE_SKIPPED_TESTS_FILE"
    cat "$CONFIG_DIR/tests-requiring-base-image.txt" >> "$UNIT_IGNORE_SKIPPED_TESTS_FILE"

    check_for_skipped_tests "$UNIT_COVERAGE_OUTPUT_TXT" "unit tests" "$UNIT_IGNORE_SKIPPED_TESTS_FILE"

    # Generate function coverage report
    go -C "$TOOLS_DIR" tool cover -func="$UNIT_COVERAGE_OUTPUT" -o "${UNIT_COVERAGE_OUTPUT%.cov}.func"

    log_info "Unit test coverage saved to $UNIT_COVERAGE_OUTPUT"
    log_info "Unit test function coverage saved to ${UNIT_COVERAGE_OUTPUT%.cov}.func"
    log_info "Unit test results saved to ${UNIT_COVERAGE_OUTPUT%.cov}.txt"

    log_success "Unit tests completed"
}

run_api_tests() {
    log_section "Running Image Customizer API tests"

    local test_args="-v -timeout $GO_TEST_TIMEOUT"
    if [[ "$GO_TEST_RUN_VALUE" != "all" ]]; then
        test_args+=" -run $GO_TEST_RUN_VALUE"
    fi
    if [[ "$FAIL_FAST" == "y" ]]; then
        test_args+=" -failfast"
    fi

    mkdir -p "$(dirname "$API_COVERAGE_OUTPUT")"

    # Run imagecustomizerapi tests
    local api_test_exit_code=0
    set +o pipefail
    log_info_and_run \
            "Running imagecustomizerapi tests" \
            sudo env "PATH=$PATH" go test -C "$TOOLS_DIR" \
                $test_args \
                -coverprofile="$API_COVERAGE_OUTPUT" \
                -covermode=count \
                ./imagecustomizerapi 2>&1 | \
        tee "$API_COVERAGE_OUTPUT_TXT"
    api_test_exit_code=${PIPESTATUS[0]}
    set -o pipefail

    check_for_failed_tests "$API_COVERAGE_OUTPUT_TXT" "imagecustomizerapi"

    if [[ "$api_test_exit_code" -ne 0 ]]; then
        log_error "imagecustomizerapi tests failed with exit code $api_test_exit_code"
        exit "$api_test_exit_code"
    fi

    check_for_skipped_tests "$API_COVERAGE_OUTPUT_TXT" "imagecustomizerapi" ""

    log_info "imagecustomizerapi test coverage saved to $API_COVERAGE_OUTPUT"
    log_info "imagecustomizerapi test log saved to $API_COVERAGE_OUTPUT_TXT"

    log_info_and_run \
        "Generating imagecustomizerapi function coverage report" \
        go -C "$TOOLS_DIR" tool cover -func="$API_COVERAGE_OUTPUT" -o "$API_COVERAGE_OUTPUT_FUNC"

    log_info "imagecustomizerapi test function coverage saved to $API_COVERAGE_OUTPUT_FUNC"
}

# Check test output for failed tests and print them to the console.
# Arguments:
#   $1 - Path to the test output file
#   $2 - Description of the test suite (for display)
check_for_failed_tests() {
    local output_file="$1"
    local suite_name="$2"

    if [[ ! -f "$output_file" ]]; then
        log_error "Test output file not found: $output_file"
        return 1
    fi

    local failed_tests
    failed_tests=$(awk '
            /^=== RUN[[:space:]]/ {
                buf = $0 "\n"
                in_run = 1
                next
            }
            in_run && /^[[:space:]]*--- / {
                if (/^[[:space:]]*--- FAIL:/) {
                    printf "%s%s\n", buf, $0
                }
                in_run = 0
                buf = ""
                next
            }
            in_run {
                buf = buf $0 "\n"
            }
        ' "$output_file")

    if [[ -n "$failed_tests" ]]; then
        log_error "Failed tests in $suite_name:"
        echo "$failed_tests"
        echo ""
    fi
}

# Check test output for skipped tests and error if any are found.
# Arguments:
#   $1 - Path to the test output file
#   $2 - Description of the test suite (for error messages)
#   $3 - Path to a file containing test names to ignore (one per line).
#          Lines starting with '#' and empty lines are ignored.
check_for_skipped_tests() {
    local output_file="$1"
    local suite_name="$2"
    local ignore_list_file="$3"

    if [[ ! -f "$output_file" ]]; then
        log_error "Test output file not found: $output_file"
        return 1
    fi

    local ignore_pattern=""
    if [[ -n "$ignore_list_file" ]]; then
        if [[ ! -f "$ignore_list_file" ]]; then
            log_error "Skip ignore list file not found: $ignore_list_file"
            return 1
        fi

        # Build a '|'-delimited pattern from non-empty, non-comment lines.
        ignore_pattern=$(grep -vE '^\s*(#|$)' "$ignore_list_file" | paste -sd '|' || true)
    fi

    local skipped_tests
    skipped_tests=$(awk -v ignore="$ignore_pattern" '
            /^=== RUN[[:space:]]/ {
                buf = $0 "\n"
                # Extract the test name (second field after "=== RUN").
                test_name = $3
                in_run = 1
                next
            }
            in_run && /^[[:space:]]*--- / {
                if (/^[[:space:]]*--- SKIP:/) {
                    if (ignore == "" || !match(test_name, "^(" ignore ")$")) {
                        printf "%s%s\n", buf, $0
                    }
                }
                in_run = 0
                buf = ""
                next
            }
            in_run {
                buf = buf $0 "\n"
            }
        ' "$output_file")

    if [[ -n "$skipped_tests" ]]; then
        log_error "Skipped tests detected in $suite_name:"
        echo "$skipped_tests"
        echo ""
        return 1
    fi
}

run_imagecustomizer_functional_tests() {
    local test_distro="$1"

    log_section "Running ImageCustomizer Functional Tests for $test_distro"

    # -v is necessary for functional tests so that skipped tests are visible in the output.
    local test_args="-v -timeout $GO_TEST_TIMEOUT"
    if [[ "$GO_TEST_RUN_VALUE" != "all" ]]; then
        test_args+=" -run $GO_TEST_RUN_VALUE"
    fi
    if [[ "$FAIL_FAST" == "y" ]]; then
        test_args+=" -failfast"
    fi

    # Build the base image args conditionally
    local base_image_args=()
    if [[ "$test_distro" == azl ]]; then
        if [[ "$USE_AZURE_LINUX_20" == "true" ]]; then
            base_image_args+=(
                -base-image-core-efi-azl2 "$AZURE_LINUX_2_CORE_EFI_VHDX"
            )
        fi
        if [[ "$USE_AZURE_LINUX_30" == "true" ]]; then
            base_image_args+=(
                -base-image-core-efi-azl3 "$AZURE_LINUX_3_CORE_EFI_VHDX"
            )
        fi
        if [[ "$USE_AZURE_LINUX_40" == "true" ]]; then
            base_image_args+=(
                -base-image-core-efi-azl4 "$AZURE_LINUX_4_CORE_EFI_VHDX"
            )
        fi
    fi

    if [[ "$test_distro" == "ubuntu" ]]; then
        if [[ "$USE_UBUNTU_2204" == "true" ]]; then
            base_image_args+=(
                -base-image-azure-cloud-ubuntu2204 "$UBUNTU_AZURE_CLOUD_2204"
            )
        fi
        if [[ "$USE_UBUNTU_2404" == "true" ]]; then
            base_image_args+=(
                -base-image-azure-cloud-ubuntu2404 "$UBUNTU_AZURE_CLOUD_2404"
            )
        fi
    fi

    mkdir -p "$(dirname "$LIB_COVERAGE_OUTPUT")"

    # Run imagecustomizerlib functional tests
    # Note: -base-image-bare-metal-azl2/azl3 are not used in actual workflows.
    local lib_test_exit_code=0
    set +o pipefail
    log_info_and_run \
            "Running imagecustomizerlib functional tests" \
            sudo env "PATH=$PATH" go test -C "$TOOLS_DIR" \
                $test_args \
                -coverprofile="$LIB_COVERAGE_OUTPUT" \
                -covermode=count \
                ./pkg/imagecustomizerlib \
                -args \
                "${base_image_args[@]}" \
                -log-level $LOG_LEVEL 2>&1 | \
        tee "$LIB_COVERAGE_OUTPUT_TXT"
    lib_test_exit_code=${PIPESTATUS[0]}
    set -o pipefail

    check_for_failed_tests "$LIB_COVERAGE_OUTPUT_TXT" "imagecustomizerlib"

    if [[ "$lib_test_exit_code" -ne 0 ]]; then
        log_error "imagecustomizerlib tests failed with exit code $lib_test_exit_code"
        exit "$lib_test_exit_code"
    fi

    check_for_skipped_tests "$LIB_COVERAGE_OUTPUT_TXT" "imagecustomizerlib" ""

    log_info "imagecustomizerlib test coverage saved to $LIB_COVERAGE_OUTPUT"
    log_info "imagecustomizerlib test log saved to $LIB_COVERAGE_OUTPUT_TXT"

    log_info_and_run \
        "Generating imagecustomizerlib function coverage report" \
        go -C "$TOOLS_DIR" tool cover -func="$LIB_COVERAGE_OUTPUT" -o "$LIB_COVERAGE_OUTPUT_FUNC"

    log_info "imagecustomizerlib test function coverage saved to $LIB_COVERAGE_OUTPUT_FUNC"

    log_success "ImageCustomizer functional tests for $test_distro passed"
}

run_imagecustomizer_vm_tests() {
    log_section "Running ImageCustomizer VM Tests"

    # Paths are always relative to testrpms directory (matches workflow)
    local testrpms_dir="$TOOLS_DIR/internal/testutils/testrpms"
    local rpm_sources_azl3="$testrpms_dir/downloadedrpms/azurelinux/3.0"
    local tools_file_azl3="$testrpms_dir/build/tools-azurelinux-3.0.tar.gz"
    local rpm_sources_azl4="$testrpms_dir/downloadedrpms/azurelinux/4.0"
    local tools_file_azl4="$testrpms_dir/build/tools-azurelinux-4.0.tar.gz"
    local rpm_sources_fedora42="$testrpms_dir/downloadedrpms/fedora/42"
    local tools_file_fedora42="$testrpms_dir/build/tools-fedora-42.tar.gz"

    local test_filter=""
    if [[ "$PYTEST_K_VALUE" != "all" ]]; then
        test_filter="$PYTEST_K_VALUE"
    fi

    log_info_and_run \
        "Running imagecustomizer VM tests" \
        sudo make -C "$VMTESTS_DIR" test-imagecustomizer \
            IMAGE_CUSTOMIZER_CONTAINER_TAG="$IMAGE_CUSTOMIZER_CONTAINER_TAG" \
            CORE_EFI_AZL2="$AZURE_LINUX_2_CORE_EFI_VHDX" \
            CORE_EFI_AZL3="$AZURE_LINUX_3_CORE_EFI_VHDX" \
            CORE_EFI_AZL4="$AZURE_LINUX_4_CORE_EFI_VHDX" \
            CORE_LEGACY_AZL2="$AZURE_LINUX_2_CORE_LEGACY_VHD" \
            CORE_LEGACY_AZL3="$AZURE_LINUX_3_CORE_LEGACY_VHD" \
            CORE_LEGACY_AZL4="$AZURE_LINUX_4_CORE_LEGACY_VHD" \
            RPM_SOURCES_AZL3="$rpm_sources_azl3" \
            TOOLS_FILE_AZL3="$tools_file_azl3" \
            RPM_SOURCES_AZL4="$rpm_sources_azl4" \
            TOOLS_FILE_AZL4="$tools_file_azl4" \
            RPM_SOURCES_FEDORA42="$rpm_sources_fedora42" \
            TOOLS_FILE_FEDORA42="$tools_file_fedora42" \
            SSH_PRIVATE_KEY_FILE="$SSH_PRIVATE_KEY_FILE" \
            KEEP_ENVIRONMENT="$KEEP_ENVIRONMENT" \
            TEST_FILTER="$test_filter" \
            FAIL_FAST="$FAIL_FAST"

    log_success "ImageCustomizer VM tests completed"
}

run_osmodifier_vm_tests() {
    log_section "Running OSModifier VM Tests"

    local test_filter=""
    if [[ "$PYTEST_K_VALUE" != "all" ]]; then
        test_filter="$PYTEST_K_VALUE"
    fi

    # Run OSModifier tests for AZL 2.0 (amd64 only in workflow, but we run locally)
    if [[ -e "$AZURE_LINUX_2_CORE_EFI_VHDX" ]]; then
        log_info "Running OSModifier tests with AZL 2.0 image"
        sudo make -C "$VMTESTS_DIR" test-osmodifier \
            IMAGE_CUSTOMIZER_CONTAINER_TAG="$IMAGE_CUSTOMIZER_CONTAINER_TAG" \
            OSMODIFIER_BIN="$OSMODIFIER_BIN" \
            INPUT_IMAGE="$AZURE_LINUX_2_CORE_EFI_VHDX" \
            DISTRO_ID="azurelinux" \
            VERSION_ID="2.0" \
            SSH_PRIVATE_KEY_FILE="$SSH_PRIVATE_KEY_FILE" \
            KEEP_ENVIRONMENT="$KEEP_ENVIRONMENT" \
            TEST_FILTER="$test_filter" \
            FAIL_FAST="$FAIL_FAST"
    else
        log_info "Skipping OSModifier tests for AZL 2.0 - base image not available"
    fi

    # Run OSModifier tests for AZL 3.0
    if [[ -e "$AZURE_LINUX_3_CORE_EFI_VHDX" ]]; then
        log_info "Running OSModifier tests with AZL 3.0 image"
        sudo make -C "$VMTESTS_DIR" test-osmodifier \
            IMAGE_CUSTOMIZER_CONTAINER_TAG="$IMAGE_CUSTOMIZER_CONTAINER_TAG" \
            OSMODIFIER_BIN="$OSMODIFIER_BIN" \
            INPUT_IMAGE="$AZURE_LINUX_3_CORE_EFI_VHDX" \
            DISTRO_ID="azurelinux" \
            VERSION_ID="3.0" \
            SSH_PRIVATE_KEY_FILE="$SSH_PRIVATE_KEY_FILE" \
            KEEP_ENVIRONMENT="$KEEP_ENVIRONMENT" \
            TEST_FILTER="$test_filter" \
            FAIL_FAST="$FAIL_FAST"
    else
        log_info "Skipping OSModifier tests for AZL 3.0 - base image not available"
    fi

    # Run OSModifier tests for AZL 4.0
    if [[ -e "$AZURE_LINUX_4_CORE_EFI_VHDX" ]]; then
        log_info "Running OSModifier tests with AZL 4.0 image"
        sudo make -C "$VMTESTS_DIR" test-osmodifier \
            IMAGE_CUSTOMIZER_CONTAINER_TAG="$IMAGE_CUSTOMIZER_CONTAINER_TAG" \
            OSMODIFIER_BIN="$OSMODIFIER_BIN" \
            INPUT_IMAGE="$AZURE_LINUX_4_CORE_EFI_VHDX" \
            DISTRO_ID="azurelinux" \
            VERSION_ID="4.0" \
            SSH_PRIVATE_KEY_FILE="$SSH_PRIVATE_KEY_FILE" \
            KEEP_ENVIRONMENT="$KEEP_ENVIRONMENT" \
            TEST_FILTER="$test_filter" \
            FAIL_FAST="$FAIL_FAST"
    else
        log_info "Skipping OSModifier tests for AZL 4.0 - base image not available"
    fi

    # Run OSModifier tests for AZL 4.0 legacy (amd64 only - no arm64 legacy boot images available)
    if [[ -e "$AZURE_LINUX_4_CORE_LEGACY_VHD" ]]; then
        log_info "Running OSModifier tests with AZL 4.0 legacy image"
        sudo make -C "$VMTESTS_DIR" test-osmodifier \
            IMAGE_CUSTOMIZER_CONTAINER_TAG="$IMAGE_CUSTOMIZER_CONTAINER_TAG" \
            OSMODIFIER_BIN="$OSMODIFIER_BIN" \
            INPUT_IMAGE="$AZURE_LINUX_4_CORE_LEGACY_VHD" \
            DISTRO_ID="azurelinux" \
            VERSION_ID="4.0" \
            SSH_PRIVATE_KEY_FILE="$SSH_PRIVATE_KEY_FILE" \
            KEEP_ENVIRONMENT="$KEEP_ENVIRONMENT" \
            TEST_FILTER="$test_filter" \
            FAIL_FAST="$FAIL_FAST"
    else
        log_info "Skipping OSModifier tests for AZL 4.0 legacy - base image not available"
    fi

    log_success "OSModifier VM tests completed"
}


# Cleanup function to unmount any leftover mounts and detach loop devices
# This runs on script exit (success, failure, or interrupt)
cleanup_mounts_and_loops() {
    log_info "Cleaning up any leftover mounts and loop devices..."

    if [[ -e "$UKIFY_BAK" ]]; then
        log_info "Restoring original ukify over patched version"
        sudo mv "$UKIFY_BAK" "$UKIFY_PATH"
    fi

    # Find and unmount any imagecustomizerlib test mounts
    local mounts
    mounts=$(mount | grep "imagecustomizerlib/_tmp" | awk '{print $3}' | sort -r || true)

    if [[ -n "$mounts" ]]; then
        log_info "Found leftover mounts, cleaning up..."
        for mount_point in $mounts; do
            log_info_and_run \
                "Unmounting: $mount_point" \
                sudo umount -l "$mount_point" 2>/dev/null || true
        done
    fi

    # Find and detach any loop devices associated with imagecustomizerlib tests
    local loop_devices
    loop_devices=$(sudo losetup -a 2>/dev/null | grep "imagecustomizerlib/_tmp" | cut -d: -f1 || true)

    if [[ -n "$loop_devices" ]]; then
        log_info "Found leftover loop devices, cleaning up..."
        for loop_dev in $loop_devices; do
            log_info_and_run \
                "Deleting partition mappings for $loop_dev" \
                sudo kpartx -d "$loop_dev" 2>/dev/null || true
            log_info_and_run \
                "Detaching loop device $loop_dev" \
                sudo losetup -d "$loop_dev" 2>/dev/null || true
        done
    fi

    if [[ -n "$ORIGINAL_SUBSCRIPTION" ]]; then
        log_info "Restoring original Azure subscription: $ORIGINAL_SUBSCRIPTION"
        az account set --subscription "$ORIGINAL_SUBSCRIPTION"
        ORIGINAL_SUBSCRIPTION=""
    fi

    log_info "Cleanup complete"
}

# Generate HTML coverage report and serve it
serve_coverage() {
    log_section "Serving Coverage Report"

    if [[ ! -f "$UNIT_COVERAGE_OUTPUT" ]]; then
        log_error "Coverage file not found: $UNIT_COVERAGE_OUTPUT"
        log_error "Run tests first to generate coverage data."
        return 1
    fi

    # Run from TOOLS_DIR so go tool cover can resolve module packages
    log_info_and_run \
        "Generating HTML coverage report" \
        go -C "$TOOLS_DIR" tool cover -html="$UNIT_COVERAGE_OUTPUT" -o "$UNIT_COVERAGE_OUTPUT_HTML"

    log_success "Coverage report generated: $UNIT_COVERAGE_OUTPUT_HTML"

    local port=8765
    log_info "Starting HTTP server on port $port..."
    log_info "Open http://localhost:$port/$(basename "$UNIT_COVERAGE_OUTPUT_HTML") in your browser"
    log_info "Press Ctrl+C to stop the server"

    cd "$(dirname "$UNIT_COVERAGE_OUTPUT_HTML")"
    python3 -m http.server "$port"
}

# Main execution
main() {
    check_root

    # Set trap to run cleanup on exit (EXIT covers normal exit, errors, and signals)
    trap cleanup_mounts_and_loops EXIT

    log_section "Azure Linux Image Tools - Test Runner"

    log_info "Configuration:"
    log_info "  Repo Dir:          $REPO_DIR"
    log_info "  Test Dir:          $TEST_DIR"
    log_info "  Unit Tests:        $RUN_UNIT_TESTS"
    log_info "  Image Tests:       $RUN_IMAGE_TESTS"
    log_info "  Functional Tests:  $RUN_FUNCTIONAL_TESTS"
    log_info "  VM Tests:          $RUN_VM_TESTS"
    log_info "  ImageCustomizer:   $RUN_IMAGECUSTOMIZER"
    log_info "  OSModifier:        $RUN_OSMODIFIER"
    log_info "  Go Test Timeout:   $GO_TEST_TIMEOUT"
    log_info "  Go Test Run:       $GO_TEST_RUN_VALUE"
    log_info "  Pytest K:          $PYTEST_K_VALUE"

    patch_ukify

    if [[ "$RUN_DOCS" == "true" ]]; then
        check_docs
    fi

    if [[ "$RUN_BUILD" == "true" || "$RUN_UNIT_TESTS" == "true" ]]; then
        check_config
    fi

    if [[ "$RUN_BUILD" == "true" ]]; then
        format_go
        check_go_modules
        update_schema
        build_tools
    fi

    # Run unit tests
    if [[ "$RUN_UNIT_TESTS" == "true" ]]; then
        run_unit_tests
        run_api_tests
    fi

    # Run image tests
    if [[ "$RUN_IMAGE_TESTS" == "true" ]]; then
        ensure_base_images
        validate_base_images
    fi

    # Run functional tests
    if [[ "$RUN_FUNCTIONAL_TESTS" == "true" ]]; then
        if [[ "$RUN_IMAGECUSTOMIZER" == "true" ]]; then
            ensure_imagecustomizer_test_utils
            ensure_base_images
            if [[ "$USE_UBUNTU_2204" == "true" || "$USE_UBUNTU_2404" == "true" ]]; then
                run_imagecustomizer_functional_tests ubuntu
            fi

            if [[ "$USE_AZURE_LINUX_20" == "true" || "$USE_AZURE_LINUX_30" == "true" || "$USE_AZURE_LINUX_40" == "true" ]]; then
                run_imagecustomizer_functional_tests azl
            fi
        fi
    fi

    # Run VM tests
    if [[ "$RUN_VM_TESTS" == "true" ]]; then
        ensure_vm_tests_venv
        check_vm_tests_formatting

        if [[ "$RUN_IMAGECUSTOMIZER" == "true" ]]; then
            ensure_base_images
            ensure_imagecustomizer_test_utils
            run_imagecustomizer_vm_tests
        fi
        if [[ "$RUN_OSMODIFIER" == "true" ]]; then
            ensure_base_images
            run_osmodifier_vm_tests
        fi
    fi

    log_section "All Tests Completed Successfully!"

    if [[ "$SERVE_UNIT_COVERAGE" == "true" ]]; then
        serve_coverage
    fi
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            print_usage
            exit 0
            ;;
        -t|--go-test-timeout)
            GO_TEST_TIMEOUT="$2"
            shift 2
            ;;
        -r|--go-test-run)
            GO_TEST_RUN_VALUE="$2"
            shift 2
            ;;
        -g|--go-test-files)
            GO_TEST_FILES+=("$2")
            shift 2
            ;;
        -k|--pytest-k)
            PYTEST_K_VALUE="$2"
            shift 2
            ;;
        -x|--fail-fast)
            FAIL_FAST="y"
            shift
            ;;
        --repo-dir)
            REPO_DIR="$(cd "$2" && pwd)"
            shift 2
            ;;
        --test-dir)
            TEST_DIR="$(cd "$2" && pwd)"
            shift 2
            ;;
        -b|--build)
            RUN_DOCS=false
            RUN_BUILD=true
            RUN_UNIT_TESTS=false
            RUN_IMAGE_TESTS=false
            RUN_FUNCTIONAL_TESTS=false
            RUN_VM_TESTS=false
            shift
            ;;
        --no-build)
            RUN_BUILD=false
            shift
            ;;
        -d|--docs)
            RUN_DOCS=true
            RUN_BUILD=false
            RUN_UNIT_TESTS=false
            RUN_IMAGE_TESTS=false
            RUN_FUNCTIONAL_TESTS=false
            RUN_VM_TESTS=false
            shift
            ;;
        --no-docs)
            RUN_DOCS=false
            shift
            ;;
        -u|--unit-tests)
            RUN_DOCS=false
            RUN_BUILD=false
            RUN_UNIT_TESTS=true
            RUN_IMAGE_TESTS=false
            RUN_FUNCTIONAL_TESTS=false
            RUN_VM_TESTS=false
            shift
            ;;
        --no-unit-tests)
            RUN_UNIT_TESTS=false
            shift
            ;;
        -i|--image-tests)
            RUN_DOCS=false
            RUN_BUILD=false
            RUN_UNIT_TESTS=false
            RUN_IMAGE_TESTS=true
            RUN_FUNCTIONAL_TESTS=false
            RUN_VM_TESTS=false
            shift
            ;;
        --no-image-tests)
            RUN_IMAGE_TESTS=false
            shift
            ;;
        -f|--functional-tests)
            RUN_DOCS=false
            RUN_BUILD=false
            RUN_UNIT_TESTS=false
            RUN_IMAGE_TESTS=false
            RUN_FUNCTIONAL_TESTS=true
            RUN_VM_TESTS=false
            shift
            ;;
        --no-functional-tests)
            RUN_FUNCTIONAL_TESTS=false
            shift
            ;;
        -m|--vm-tests)
            RUN_DOCS=false
            RUN_BUILD=false
            RUN_UNIT_TESTS=false
            RUN_IMAGE_TESTS=false
            RUN_FUNCTIONAL_TESTS=false
            RUN_VM_TESTS=true
            shift
            ;;
        --no-vm-tests)
            RUN_VM_TESTS=false
            shift
            ;;
        -a|--all)
            RUN_DOCS=true
            RUN_BUILD=true
            RUN_UNIT_TESTS=true
            RUN_IMAGE_TESTS=true
            RUN_FUNCTIONAL_TESTS=true
            RUN_VM_TESTS=true
            shift
            ;;
        -[dbuifm][dbuifm]*)
            # Combined short flags, e.g. -buf means --build --unit-tests --functional-tests
            if [[ "${1#-}" =~ [^dbuifm] ]]; then
                log_error "Unknown option: $1"
                print_usage
                exit 1
            fi
            RUN_DOCS=false
            RUN_BUILD=false
            RUN_UNIT_TESTS=false
            RUN_IMAGE_TESTS=false
            RUN_FUNCTIONAL_TESTS=false
            RUN_VM_TESTS=false
            [[ "$1" == *d* ]] && RUN_DOCS=true
            [[ "$1" == *b* ]] && RUN_BUILD=true
            [[ "$1" == *u* ]] && RUN_UNIT_TESTS=true
            [[ "$1" == *i* ]] && RUN_IMAGE_TESTS=true
            [[ "$1" == *f* ]] && RUN_FUNCTIONAL_TESTS=true
            [[ "$1" == *m* ]] && RUN_VM_TESTS=true
            shift
            ;;
        --config-dir)
            CONFIG_DIR="$(cd "$2" && pwd)"
            shift 2
            ;;
        --ssh-key)
            SSH_PRIVATE_KEY_FILE="$2"
            shift 2
            ;;
        --keep-environment)
            KEEP_ENVIRONMENT="y"
            shift
            ;;
        --unit-coverage-output)
            UNIT_COVERAGE_OUTPUT="$2"
            UNIT_COVERAGE_OUTPUT_TXT="${UNIT_COVERAGE_OUTPUT%.cov}.txt"
            UNIT_COVERAGE_OUTPUT_HTML="${UNIT_COVERAGE_OUTPUT%.cov}.html"
            if [[ "${UNIT_COVERAGE_OUTPUT: -4}" != ".cov" ]]; then
                log_error "--unit-coverage-output must end with .cov"
                exit 1
            fi
            shift 2
            ;;
        --api-coverage-output)
            API_COVERAGE_OUTPUT="$2"
            API_COVERAGE_OUTPUT_TXT="${API_COVERAGE_OUTPUT%.cov}.txt"
            API_COVERAGE_OUTPUT_FUNC="${API_COVERAGE_OUTPUT%.cov}.func"
            if [[ "${API_COVERAGE_OUTPUT: -4}" != ".cov" ]]; then
                log_error "--api-coverage-output must end with .cov"
                exit 1
            fi
            shift 2
            ;;
        --lib-coverage-output)
            LIB_COVERAGE_OUTPUT="$2"
            LIB_COVERAGE_OUTPUT_TXT="${LIB_COVERAGE_OUTPUT%.cov}.txt"
            LIB_COVERAGE_OUTPUT_FUNC="${LIB_COVERAGE_OUTPUT%.cov}.func"
            if [[ "${LIB_COVERAGE_OUTPUT: -4}" != ".cov" ]]; then
                log_error "--lib-coverage-output must end with .cov"
                exit 1
            fi
            shift 2
            ;;
        --imagecustomizer)
            RUN_IMAGECUSTOMIZER=true
            RUN_OSMODIFIER=false
            shift
            ;;
        --no-imagecustomizer)
            RUN_IMAGECUSTOMIZER=false
            shift
            ;;
        --osmodifier)
            RUN_IMAGECUSTOMIZER=false
            RUN_OSMODIFIER=true
            shift
            ;;
        --no-osmodifier)
            RUN_OSMODIFIER=false
            shift
            ;;
        --azure-linux-20)
            USE_AZURE_LINUX_20=true
            USE_AZURE_LINUX_30=false
            USE_AZURE_LINUX_40=false
            USE_UBUNTU_2204=false
            USE_UBUNTU_2404=false
            shift
            ;;
        --azure-linux-30)
            USE_AZURE_LINUX_20=false
            USE_AZURE_LINUX_30=true
            USE_AZURE_LINUX_40=false
            USE_UBUNTU_2204=false
            USE_UBUNTU_2404=false
            shift
            ;;
        --azure-linux-40)
            USE_AZURE_LINUX_20=false
            USE_AZURE_LINUX_30=false
            USE_AZURE_LINUX_40=true
            USE_UBUNTU_2204=false
            USE_UBUNTU_2404=false
            shift
            ;;
        --azure-linux)
            USE_AZURE_LINUX_20=true
            USE_AZURE_LINUX_30=true
            USE_AZURE_LINUX_40=true
            USE_UBUNTU_2204=false
            USE_UBUNTU_2404=false
            shift
            ;;
        --no-azure-linux-20)
            USE_AZURE_LINUX_20=false
            shift
            ;;
        --no-azure-linux-30)
            USE_AZURE_LINUX_30=false
            shift
            ;;
        --no-azure-linux-40)
            USE_AZURE_LINUX_40=false
            shift
            ;;
        --no-azure-linux)
            USE_AZURE_LINUX_20=false
            USE_AZURE_LINUX_30=false
            USE_AZURE_LINUX_40=false
            shift
            ;;
        --ubuntu-2204)
            USE_AZURE_LINUX_20=false
            USE_AZURE_LINUX_30=false
            USE_AZURE_LINUX_40=false
            USE_UBUNTU_2204=true
            USE_UBUNTU_2404=false
            shift
            ;;
        --ubuntu-2404)
            USE_AZURE_LINUX_20=false
            USE_AZURE_LINUX_30=false
            USE_AZURE_LINUX_40=false
            USE_UBUNTU_2204=false
            USE_UBUNTU_2404=true
            shift
            ;;
        --ubuntu)
            USE_AZURE_LINUX_20=false
            USE_AZURE_LINUX_30=false
            USE_AZURE_LINUX_40=false
            USE_UBUNTU_2204=true
            USE_UBUNTU_2404=true
            shift
            ;;
        --no-ubuntu-2204)
            USE_UBUNTU_2204=false
            shift
            ;;
        --no-ubuntu-2404)
            USE_UBUNTU_2404=false
            shift
            ;;
        --no-ubuntu)
            USE_UBUNTU_2204=false
            USE_UBUNTU_2404=false
            shift
            ;;
        -s|--serve-unit-coverage)
            SERVE_UNIT_COVERAGE=true
            shift
            ;;
        -*)
            log_error "Unknown option: $1"
            print_usage
            exit 1
            ;;
        *)
            log_error "Unknown argument: $1"
            print_usage
            exit 1
            ;;
    esac
done

# Validate mutual exclusivity of -r and -g
if [[ "$GO_TEST_RUN_VALUE" != "all" && ${#GO_TEST_FILES[@]} -gt 0 ]]; then
    log_error "--go-test-run (-r) and --go-test-files (-g) are mutually incompatible."
    exit 1
fi

# If test files were specified, extract Test function names and build a -run regex
if [[ ${#GO_TEST_FILES[@]} -gt 0 ]]; then
    test_func_names=()
    for test_file in "${GO_TEST_FILES[@]}"; do
        if [[ ! -f "$test_file" ]]; then
            log_error "Test file not found: $test_file"
            exit 1
        fi
        while IFS= read -r func_name; do
            test_func_names+=("$func_name")
        done < <(grep -oP '^func \K(Test\w+)' "$test_file")
    done

    if [[ ${#test_func_names[@]} -eq 0 ]]; then
        log_error "No Test functions found in the specified files: ${GO_TEST_FILES[*]}"
        exit 1
    fi

    # Join test names with | to form a go test -run regex
    GO_TEST_RUN_VALUE=$(IFS='|'; echo "^(${test_func_names[*]})\$")
    log_info "Extracted ${#test_func_names[@]} test(s) from ${#GO_TEST_FILES[@]} file(s): $GO_TEST_RUN_VALUE"
fi

if [[ "$CONFIG_DIR" == "" ]]; then
    CONFIG_DIR="$SCRIPT_DIR_REAL/config"
fi

if [[ "$REPO_DIR" == "" ]]; then
    if [[ -d "$SCRIPT_DIR_SYM/toolkit" ]]; then
        REPO_DIR="$SCRIPT_DIR_SYM"
    else
        REPO_DIR="$SCRIPT_DIR_SYM/azure-linux-image-tools"
    fi
fi

if [[ "$TEST_DIR" == "" ]]; then
    TEST_DIR="$REPO_DIR/test"
fi

BASE_IMAGES_DIR="$TEST_DIR/base-images"

TOOLKIT_DIR="$REPO_DIR/toolkit"
TOOLS_DIR="$TOOLKIT_DIR/tools"
OSMODIFIER_BIN="$TOOLKIT_DIR/out/tools/osmodifier"
DOWNLOAD_TEST_UTILS_DIR="$TOOLS_DIR/internal/testutils/testrpms"
DOWNLOAD_TEST_UTILS_SCRIPT="$DOWNLOAD_TEST_UTILS_DIR/download-test-utils.sh"
VMTESTS_DIR="$REPO_DIR/test/vmtests"

if [[ "$API_COVERAGE_OUTPUT" == "" ]]; then
    API_COVERAGE_OUTPUT="$TOOLS_DIR/out/testResults/api.cov"
fi

API_COVERAGE_OUTPUT_TXT="${API_COVERAGE_OUTPUT%.cov}.txt"
API_COVERAGE_OUTPUT_FUNC="${API_COVERAGE_OUTPUT%.cov}.func"


if [[ "$LIB_COVERAGE_OUTPUT" == "" ]]; then
    LIB_COVERAGE_OUTPUT="$TOOLS_DIR/out/testResults/lib.cov"
fi

LIB_COVERAGE_OUTPUT_TXT="${LIB_COVERAGE_OUTPUT%.cov}.txt"
LIB_COVERAGE_OUTPUT_FUNC="${LIB_COVERAGE_OUTPUT%.cov}.func"

if [[ "$UNIT_COVERAGE_OUTPUT" == "" ]]; then
    UNIT_COVERAGE_OUTPUT="$TOOLS_DIR/out/testResults/unit.cov"
fi

UNIT_COVERAGE_OUTPUT_TXT="${UNIT_COVERAGE_OUTPUT%.cov}.txt"
UNIT_COVERAGE_OUTPUT_HTML="${UNIT_COVERAGE_OUTPUT%.cov}.html"
UNIT_IGNORE_SKIPPED_TESTS_FILE="$TOOLS_DIR/out/testResults/unit_ignored_skipped_tests.txt"

BUILD_IMAGECUSTOMIZER_OUTPUT="$TOOLS_DIR/out/testResults/build_imagecustomizer.log"
BUILD_IMAGECUSTOMIZER_IGNORE_SKIPPED_TESTS_FILE="$TOOLS_DIR/out/testResults/build_imagecustomizer_ignored_skipped_tests.txt"
BUILD_OSMODIFIER_OUTPUT="$TOOLS_DIR/out/testResults/build_osmodifier.log"
BUILD_OSMODIFIER_IGNORE_SKIPPED_TESTS_FILE="$TOOLS_DIR/out/testResults/build_osmodifier_ignored_skipped_tests.txt"
BUILD_CONTAINER_OUTPUT="$TOOLS_DIR/out/testResults/build_container.log"

main "$@"
