#!/usr/bin/env python3
"""Regenerate the checked-in Xcode project using only Python's standard library."""
from pathlib import Path
import hashlib
import json
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "EmberPad.xcodeproj"
objects = {}


def oid(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()


def add(object_key, isa, **fields):
    key = oid(object_key)
    objects[key] = {"isa": isa, **fields}
    return key


def serialize(value, level=0):
    if isinstance(value, dict):
        return "{\n" + "".join("\t" * (level + 1) + json.dumps(k) + " = " + serialize(v, level + 1) + ";\n" for k, v in value.items()) + "\t" * level + "}"
    if isinstance(value, list):
        return "(\n" + "".join("\t" * (level + 1) + serialize(v, level + 1) + ",\n" for v in value) + "\t" * level + ")"
    return json.dumps(str(value))


def configs(name, settings, base=None):
    ids = []
    for mode in ("Debug", "Release"):
        fields = {"buildSettings": {**settings, "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if mode == "Debug" else "-O"}, "name": mode}
        if base:
            fields["baseConfigurationReference"] = base
        ids.append(add(name + mode, "XCBuildConfiguration", **fields))
    return add(name + "configs", "XCConfigurationList", buildConfigurations=ids, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")


config_ref = add("xcconfig", "PBXFileReference", lastKnownFileType="text.xcconfig", path="Config/Shared.xcconfig", sourceTree="<group>")
package_ref = add("package", "XCLocalSwiftPackageReference", relativePath="EmberSyncKit")
product_ids, source_groups, targets = [], [], []
for name, folder, platform in (("EmberPad", "Apps/EmberPad", "ios"), ("EmberPad Companion", "Apps/Companion", "mac")):
    source_ids, child_ids = [], []
    for path in sorted((ROOT / folder).glob("*")):
        if path.suffix not in (".swift", ".plist"):
            continue
        ref = add(str(path.relative_to(ROOT)), "PBXFileReference", lastKnownFileType="sourcecode.swift" if path.suffix == ".swift" else "text.plist.xml", path=path.name, sourceTree="<group>")
        child_ids.append(ref)
        if path.suffix == ".swift":
            source_ids.append(add(str(path.relative_to(ROOT)) + "build", "PBXBuildFile", fileRef=ref))
    source_groups.append(add(folder, "PBXGroup", children=child_ids, path=folder, sourceTree="<group>"))
    product = add(name + ".app", "PBXFileReference", explicitFileType="wrapper.application", includeInIndex=0, path=name + ".app", sourceTree="BUILT_PRODUCTS_DIR")
    product_ids.append(product)
    dependency = add(name + "dependency", "XCSwiftPackageProductDependency", package=package_ref, productName="EmberSyncKit")
    framework = add(name + "framework", "PBXBuildFile", productRef=dependency)
    phases = [add(name + "sources", "PBXSourcesBuildPhase", buildActionMask=2147483647, files=source_ids, runOnlyForDeploymentPostprocessing=0),
              add(name + "frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[framework], runOnlyForDeploymentPostprocessing=0),
              add(name + "resources", "PBXResourcesBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)]
    settings = {"PRODUCT_NAME": name, "PRODUCT_MODULE_NAME": "EmberPad" if platform == "ios" else "EmberPadCompanion", "INFOPLIST_FILE": folder + "/Info.plist"}
    if platform == "ios":
        settings.update(SDKROOT="iphoneos", IPHONEOS_DEPLOYMENT_TARGET="17.5", TARGETED_DEVICE_FAMILY="2", SUPPORTED_PLATFORMS="iphoneos iphonesimulator", SUPPORTS_MACCATALYST="NO", SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD="NO")
    else:
        settings.update(SDKROOT="macosx", MACOSX_DEPLOYMENT_TARGET="14.0", SUPPORTED_PLATFORMS="macosx", ENABLE_APP_SANDBOX="NO", ENABLE_HARDENED_RUNTIME="NO")
    target = add(name, "PBXNativeTarget", buildConfigurationList=configs(name, settings, config_ref), buildPhases=phases, buildRules=[], dependencies=[], name=name, packageProductDependencies=[dependency], productName=name, productReference=product, productType="com.apple.product-type.application")
    targets.append(target)

targets.append(add("resign", "PBXAggregateTarget", buildConfigurationList=configs("resign", {}), buildPhases=[], dependencies=[], name="resign", productName="resign"))
products = add("products", "PBXGroup", children=product_ids, name="Products", sourceTree="<group>")
resign = add("resign-files", "PBXFileReference", lastKnownFileType="folder", path="resign", sourceTree="<group>")
package_folder = add("package-files", "PBXFileReference", lastKnownFileType="folder", path="EmberSyncKit", sourceTree="<group>")
main = add("main", "PBXGroup", children=[config_ref, *source_groups, package_folder, resign, products], sourceTree="<group>")
root = add("project", "PBXProject", attributes={"BuildIndependentTargetsInParallel": "YES", "LastUpgradeCheck": "2660"}, buildConfigurationList=configs("project", {"CLANG_ENABLE_MODULES": "YES", "SWIFT_VERSION": "5.0", "DEBUG_INFORMATION_FORMAT": "dwarf"}), compatibilityVersion="Xcode 14.0", developmentRegion="en", hasScannedForEncodings=0, knownRegions=["en", "Base"], mainGroup=main, packageReferences=[package_ref], productRefGroup=products, projectDirPath="", projectRoot="", targets=targets)
PROJECT.mkdir(exist_ok=True)
(PROJECT / "project.pbxproj").write_text("// !$*UTF8*$!\n" + serialize({"archiveVersion": 1, "classes": {}, "objectVersion": 56, "objects": objects, "rootObject": root}) + "\n")
schemes = PROJECT / "xcshareddata/xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
for name, target in zip(("EmberPad", "EmberPad Companion"), targets):
    scheme = ET.Element("Scheme", LastUpgradeVersion="2660", version="1.3")
    build = ET.SubElement(scheme, "BuildAction", parallelizeBuildables="YES", buildImplicitDependencies="YES")
    entry = ET.SubElement(ET.SubElement(build, "BuildActionEntries"), "BuildActionEntry", buildForTesting="YES", buildForRunning="YES", buildForProfiling="YES", buildForArchiving="YES", buildForAnalyzing="YES")

    def buildable(parent):
        return ET.SubElement(parent, "BuildableReference", BuildableIdentifier="primary", BlueprintIdentifier=target, BuildableName=name + ".app", BlueprintName=name, ReferencedContainer="container:EmberPad.xcodeproj")

    buildable(entry)
    ET.SubElement(scheme, "TestAction", buildConfiguration="Debug", shouldUseLaunchSchemeArgsEnv="YES")
    launch = ET.SubElement(scheme, "LaunchAction", buildConfiguration="Debug", selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB", selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB", launchStyle="0", useCustomWorkingDirectory="NO", ignoresPersistentStateOnLaunch="NO", debugDocumentVersioning="YES", allowLocationSimulation="YES")
    buildable(ET.SubElement(launch, "BuildableProductRunnable", runnableDebuggingMode="0"))
    profile = ET.SubElement(scheme, "ProfileAction", buildConfiguration="Release", shouldUseLaunchSchemeArgsEnv="YES", savedToolIdentifier="", useCustomWorkingDirectory="NO", debugDocumentVersioning="YES")
    buildable(ET.SubElement(profile, "BuildableProductRunnable", runnableDebuggingMode="0"))
    ET.SubElement(scheme, "AnalyzeAction", buildConfiguration="Debug")
    ET.SubElement(scheme, "ArchiveAction", buildConfiguration="Release", revealArchiveInOrganizer="YES")
    ET.indent(scheme)
    ET.ElementTree(scheme).write(schemes / (name + ".xcscheme"), encoding="UTF-8", xml_declaration=True)
print("Generated EmberPad.xcodeproj and shared app schemes")
