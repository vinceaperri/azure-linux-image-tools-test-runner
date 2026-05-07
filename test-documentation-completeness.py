#!/usr/bin/env python3
"""
Documentation tests for azure-linux-image-tools.

Validates that Go source definitions stay in sync with their corresponding Markdown documentation.
"""

import re
import sys
import unittest
from pathlib import Path


def parse_go_string_constants(content: str, type_name: str) -> set[str]:
    """Extract string constant values for the given Go type from source.

    Handles both explicit type declarations and implied types within const blocks.
    """
    values: set[str] = set()
    current_type: str | None = None

    explicit_re = re.compile(r'^\s*\w+\s+(\w+)\s*=\s*"([^"]+)"')
    implied_re = re.compile(r'^\s*\w+\s*=\s*"([^"]+)"')

    for line in content.split('\n'):
        explicit_match = explicit_re.match(line)
        if explicit_match:
            current_type, value = explicit_match.groups()
            if current_type == type_name:
                values.add(value)
            continue

        implied_match = implied_re.match(line)
        if implied_match and current_type == type_name:
            values.add(implied_match.group(1))

    return values


def parse_md_section_bullet_values(content: str, heading: str, level: int = 2) -> set[str]:
    """Extract backtick-quoted values from bullet items under a heading."""
    prefix = "#" * level
    match = re.search(rf"^{prefix} {re.escape(heading)}\b.*$", content, re.MULTILINE)
    if not match:
        raise ValueError(f"'{prefix} {heading}' section not found in markdown")

    rest = content[match.end():]
    next_h = re.search(rf"^{prefix} ", rest, re.MULTILINE)
    section = rest[:next_h.start()] if next_h else rest

    return set(re.findall(r"^- `([^`]+)`", section, re.MULTILINE))


def _assert_no_diff(tc: unittest.TestCase, items: list[str], noun: str, src: str, dst: str) -> None:
    """Fail the test if items is non-empty, with a formatted message."""
    if items:
        tc.fail(
            f"\n    {noun} in {src} but NOT in {dst}:\n"
            + "\n".join(f"        - {f}" for f in items)
        )


_config: dict[str, str] = {
    "repo_dir": "azure-linux-image-tools",
}

API_SUBDIR = "toolkit/tools/imagecustomizerapi"
DOC_SUBDIR = "docs/imagecustomizer/api/configuration"


class _DocSyncTest(unittest.TestCase):
    """Verify that Go string constants and their Markdown documentation stay in sync.

    Subclasses declare which Go source file, type, Markdown file, and heading
    to compare. Two tests are generated automatically:

    - test_all_go_values_documented: every constant in Go appears in the docs.
    - test_no_extra_values_in_docs: every value in the docs exists in Go.

    Example Go source (boottype.go)::

        const (
            BootTypeNone   BootType = ""
            BootTypeEfi    BootType = "efi"
            BootTypeLegacy BootType = "legacy"
        )

    Example Markdown (storage.md)::

        ## bootType [string]

        Specifies the boot system that the image supports.

        Supported options:

        - `legacy`: Support booting from BIOS firmware.

          When this option is specified, the partition layout must contain a partition with the
          `bios-grub` flag.

        - `efi`: Support booting from UEFI firmware.

          When this option is specified, the partition layout must contain a partition with the
          `esp` flag.

    Corresponding test class::

        class TestDoc_BootType(_DocSyncTest):
            noun = "Boot types"
            go_file = "boottype.go"
            go_type = "BootType"
            md_file = "storage.md"
            md_heading = "bootType"
            md_level = 2

    If "efi" were missing from storage.md, ``test_all_go_values_documented``
    would fail. If storage.md listed "bios" but boottype.go did not define it,
    ``test_no_extra_values_in_docs`` would fail.
    """

    noun: str
    go_file: str
    go_type: str
    go_include: set[str] = set()
    go_exclude: set[str] = set()
    md_file: str
    md_heading: str
    md_level: int

    def setUp(self) -> None:
        if type(self) is _DocSyncTest:
            self.skipTest("Abstract base class")

        if len(self.go_include) and len(self.go_exclude):
            raise ValueError("Cannot specify both go_include and go_exclude")

        self.go_path = f"{_config['repo_dir']}/{API_SUBDIR}/{self.go_file}"
        self.md_path = f"{_config['repo_dir']}/{DOC_SUBDIR}/{self.md_file}"
        go_content = Path(self.go_path).read_text()
        md_content = Path(self.md_path).read_text()
        self.go_values = parse_go_string_constants(go_content, self.go_type) - self.go_exclude
        if len(self.go_include):
            if len(self.go_include - self.go_values) > 0:
                raise ValueError(f"go_include values '{self.go_include - self.go_values}' not found in Go constants")
            self.go_values = self.go_include
        self.md_values = parse_md_section_bullet_values(md_content, self.md_heading, self.md_level)

    def test_all_go_values_documented(self) -> None:
        missing = sorted(self.go_values - self.md_values)
        _assert_no_diff(self, missing, self.noun, self.go_path, self.md_path)

    def test_no_extra_values_in_docs(self) -> None:
        extra = sorted(self.md_values - self.go_values)
        _assert_no_diff(self, extra, self.noun, self.md_path, self.go_path)


class TestDoc_CustomizePreviewFeature(_DocSyncTest):
    noun = "Customize preview features"
    go_file = "previewfeaturetype.go"
    go_type = "PreviewFeature"
    go_exclude = {"inject-files"} # Only for inject-files configuration, not customize configuration.
    md_file = "config.md"
    md_heading = "previewFeatures"
    md_level = 2


class TestDoc_InjectFilesPreviewFeature(_DocSyncTest):
    noun = "Inject-files preview features"
    go_file = "previewfeaturetype.go"
    go_type = "PreviewFeature"
    go_include = {"inject-files"} # Only for inject-files configuration, not customize configuration.
    md_file = "injectFilesConfig.md"
    md_heading = "previewFeatures"
    md_level = 2


class TestDoc_ImageFormatType(_DocSyncTest):
    noun = "Image format types"
    go_file = "imageFormatType.go"
    go_type = "ImageFormatType"
    md_file = "outputImage.md"
    md_heading = "format"
    md_level = 2


class TestDoc_BootType(_DocSyncTest):
    noun = "Boot types"
    go_file = "boottype.go"
    go_type = "BootType"
    md_file = "storage.md"
    md_heading = "bootType"
    md_level = 2


class TestDoc_FileSystemType(_DocSyncTest):
    noun = "File system types"
    go_file = "filesystemtype.go"
    go_type = "FileSystemType"
    md_file = "filesystem.md"
    md_heading = "type"
    md_level = 2


class TestDoc_PartitionType(_DocSyncTest):
    noun = "Partition types"
    go_file = "partitiontype.go"
    go_type = "PartitionType"
    md_file = "partition.md"
    md_heading = "type"
    md_level = 2


class TestDoc_SELinuxMode(_DocSyncTest):
    noun = "SELinux modes"
    go_file = "selinuxmode.go"
    go_type = "SELinuxMode"
    md_file = "selinux.md"
    md_heading = "mode"
    md_level = 2


class TestDoc_UkiMode(_DocSyncTest):
    noun = "UKI modes"
    go_file = "ukimode.go"
    go_type = "UkiMode"
    md_file = "uki.md"
    md_heading = "mode"
    md_level = 2


class TestDoc_MountIdentifierType(_DocSyncTest):
    noun = "Mount ID types"
    go_file = "mountidentifiertype.go"
    go_type = "MountIdentifierType"
    md_file = "mountpoint.md"
    md_heading = "idType"
    md_level = 2


class TestDoc_PasswordType(_DocSyncTest):
    noun = "Password types"
    go_file = "passwordtype.go"
    go_type = "PasswordType"
    md_file = "password.md"
    md_heading = "type"
    md_level = 2


class TestDoc_ResetBootLoaderType(_DocSyncTest):
    noun = "Reset bootloader types"
    go_file = "bootloaderresettype.go"
    go_type = "ResetBootLoaderType"
    md_file = "bootloader.md"
    md_heading = "resetType"
    md_level = 2


class TestDoc_OutputArtifactsItemType(_DocSyncTest):
    noun = "Output artifact item types"
    go_file = "outputartifactsitemtype.go"
    go_type = "OutputArtifactsItemType"
    go_exclude = {"uki-addons"} # Not a user-specified value, only used internally to distinguish UKI
    md_file = "outputArtifacts.md"
    md_heading = "items"
    md_level = 2


class TestDoc_CorruptionOption(_DocSyncTest):
    noun = "Corruption options"
    go_file = "corruptionoption.go"
    go_type = "CorruptionOption"
    md_file = "verity.md"
    md_heading = "corruptionOption"
    md_level = 2


class TestDoc_ReinitializeVerityType(_DocSyncTest):
    noun = "Reinitialize verity types"
    go_file = "reinitializeveritytype.go"
    go_type = "ReinitializeVerityType"
    md_file = "storage.md"
    md_heading = "reinitializeVerity"
    md_level = 2


class TestDoc_ResetPartitionsUuidsType(_DocSyncTest):
    noun = "Reset partition UUID types"
    go_file = "resetpartitionuuidtype.go"
    go_type = "ResetPartitionsUuidsType"
    md_file = "storage.md"
    md_heading = "resetPartitionsUuidsType"
    md_level = 2


class TestDoc_ModuleLoadMode(_DocSyncTest):
    noun = "Module load modes"
    go_file = "moduleLoadMode.go"
    go_type = "ModuleLoadMode"
    md_file = "module.md"
    md_heading = "loadMode"
    md_level = 2


class TestDoc_KdumpBootFilesType(_DocSyncTest):
    noun = "Kdump boot files types"
    go_file = "kdumpbootfilestype.go"
    go_type = "KdumpBootFilesType"
    md_file = "kdumpbootfiles.md"
    md_heading = "kdumpBootFiles"
    md_level = 1


if __name__ == "__main__":
    argv = sys.argv[:]
    if len(argv) > 1 and argv[1] == "--repo-dir":
        if len(argv) < 3:
            print(f"Error: Usage: {argv[0]} --repo-dir PATH [unittest args ...]", file=sys.stderr)
            sys.exit(1)

        _config["repo_dir"] = argv[2]
        del argv[1:3]

    unittest.main(argv=argv)
