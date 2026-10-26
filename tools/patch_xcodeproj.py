import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PBX = ROOT / "Driveby.xcodeproj" / "project.pbxproj"

LINT_ID = "D1B0A0010000000000000001"
LINT_PHASE = f'''		{LINT_ID} /* Privacy Lint */ = {{
			isa = PBXShellScriptBuildPhase;
			alwaysOutOfDate = 1;
			buildActionMask = 2147483647;
			files = (
			);
			inputFileListPaths = (
			);
			inputPaths = (
			);
			name = "Privacy Lint";
			outputFileListPaths = (
			);
			outputPaths = (
			);
			runOnlyForDeploymentPostprocessing = 0;
			shellPath = /bin/sh;
			shellScript = "sh \\"${{SRCROOT}}/Scripts/privacy_lint.sh\\"\\n";
			showEnvVarsInLog = 0;
		}};
'''


def main():
    s = PBX.read_text()
    orig = s

    s = s.replace("IPHONEOS_DEPLOYMENT_TARGET = 26.0;", "IPHONEOS_DEPLOYMENT_TARGET = 17.0;")
    for key in ("SWIFT_APPROACHABLE_CONCURRENCY", "SWIFT_DEFAULT_ACTOR_ISOLATION", "SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY"):
        s = re.sub(rf"\n\t+{key} = [^;]+;", "", s)
    s = s.replace('TARGETED_DEVICE_FAMILY = "1,2";', "TARGETED_DEVICE_FAMILY = 1;")

    additions = {
        "INFOPLIST_FILE": '"Driveby-Info.plist"',
        "INFOPLIST_KEY_CFBundleDisplayName": "Driveby",
        "INFOPLIST_KEY_LSApplicationCategoryType": '"public.app-category.navigation"',
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
    }
    def add_settings(m):
        block = m.group(0)
        for k, v in additions.items():
            if re.search(rf"(?<![A-Z_]){k} =", block):
                block = re.sub(rf"(?<![A-Z_]){k} = [^;]+;", f"{k} = {v};", block)
            else:
                block = block.replace("ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;",
                                      f"ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;\n\t\t\t\t{k} = {v};", 1)
        return block
    s = re.sub(r"buildSettings = \{\n\t+ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;.*?\n\t+\};", add_settings, s, flags=re.S)

    if LINT_ID not in s:
        s = s.replace("/* Begin PBXSourcesBuildPhase section */",
                      "/* Begin PBXShellScriptBuildPhase section */\n" + LINT_PHASE +
                      "/* End PBXShellScriptBuildPhase section */\n\n/* Begin PBXSourcesBuildPhase section */")
        s = re.sub(r"(isa = PBXNativeTarget;.*?buildPhases = \(\n)", rf"\g<1>\t\t\t\t{LINT_ID} /* Privacy Lint */,\n", s, count=1, flags=re.S)

    if s != orig:
        PBX.write_text(s)
        print("patched", PBX)
    else:
        print("already patched")


if __name__ == "__main__":
    sys.exit(main())
