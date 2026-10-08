#!/usr/bin/env python3
"""Regenerate the small native app and XCUITest wrapper. No third-party generator."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
objects = {}


def uid(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


def obj(identity, isa, **fields):
    key = uid(identity)
    objects[key] = dict(isa=isa, **fields)
    return key


def encode(value, level=0):
    if isinstance(value, dict):
        return "{\n" + "".join("\t" * (level + 1) + json.dumps(k) + " = " + encode(v, level + 1) + ";\n" for k, v in value.items()) + "\t" * level + "}"
    if isinstance(value, list):
        return "(" + ", ".join(encode(x, level + 1) for x in value) + ")"
    return json.dumps(str(value))


def config(name, values):
    configs = [obj(name + mode, "XCBuildConfiguration", name=mode, buildSettings={**values, "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if mode == "Debug" else "-O", "ONLY_ACTIVE_ARCH": "YES" if mode == "Debug" else "NO", "ENABLE_HARDENED_RUNTIME": "NO" if mode == "Debug" else "YES", "CODE_SIGN_ENTITLEMENTS": values.get("CODE_SIGN_ENTITLEMENTS", "") if mode == "Debug" or name == "test" else ""}) for mode in ["Debug", "Release"]]
    return obj(name + "configs", "XCConfigurationList", buildConfigurations=configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")


def files(group, paths):
    refs = [obj(p, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=p, sourceTree="SOURCE_ROOT") for p in paths]
    obj(group, "PBXGroup", children=refs, name=group, sourceTree="<group>")
    return [obj("build" + p, "PBXBuildFile", fileRef=ref) for p, ref in zip(paths, refs)]


app_sources = files("App", [str(p.relative_to(ROOT)) for p in sorted((ROOT / "Sources/BiQuadMonitor").glob("*.swift"))])
test_sources = files("UITests", ["Tests/AppUITests/AppUITests.swift"])
app_product = obj("app-product", "PBXFileReference", explicitFileType="wrapper.application", path="BiQuad Monitor.app", sourceTree="BUILT_PRODUCTS_DIR")
test_product = obj("test-product", "PBXFileReference", explicitFileType="wrapper.cfbundle", path="AppUITests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
products = obj("Products", "PBXGroup", children=[app_product, test_product], name="Products", sourceTree="<group>")
main_group = obj("Root", "PBXGroup", children=[uid("App"), uid("UITests"), products], sourceTree="<group>")
package = obj("LocalPackage", "XCLocalSwiftPackageReference", relativePath=".")
libs = [obj(name, "XCSwiftPackageProductDependency", package=package, productName=name) for name in ["SignalCore", "SessionStore"]]
frameworks = [obj("link" + name, "PBXBuildFile", productRef=uid(name)) for name in ["SignalCore", "SessionStore"]]
base = {"MACOSX_DEPLOYMENT_TARGET": "13.0", "SWIFT_VERSION": "5.0", "SDKROOT": "macosx", "CODE_SIGN_IDENTITY": "-", "CODE_SIGN_STYLE": "Manual", "ENABLE_HARDENED_RUNTIME": "YES", "COMBINE_HIDPI_IMAGES": "YES", "ALWAYS_SEARCH_USER_PATHS": "NO"}
app_config = config("app", {**base, "PRODUCT_NAME": "BiQuad Monitor", "PRODUCT_BUNDLE_IDENTIFIER": "local.blackterminal.BiQuadMonitor", "INFOPLIST_FILE": "Resources/Info.plist", "CODE_SIGN_ENTITLEMENTS": "Resources/Development.entitlements"})
app = obj("app-target", "PBXNativeTarget", name="BiQuadMonitorApp", buildConfigurationList=app_config, productName="BiQuad Monitor", productReference=app_product, productType="com.apple.product-type.application", packageProductDependencies=libs, buildPhases=[obj("app-sources", "PBXSourcesBuildPhase", files=app_sources, buildActionMask=2147483647, runOnlyForDeploymentPostprocessing=0), obj("app-frameworks", "PBXFrameworksBuildPhase", files=frameworks, buildActionMask=2147483647, runOnlyForDeploymentPostprocessing=0)], buildRules=[], dependencies=[])
proxy = obj("proxy", "PBXContainerItemProxy", containerPortal=uid("project"), proxyType=1, remoteGlobalIDString=app, remoteInfo="BiQuadMonitor")
dependency = obj("dependency", "PBXTargetDependency", target=app, targetProxy=proxy)
test = obj("test-target", "PBXNativeTarget", name="AppUITests", productName="AppUITests", productReference=test_product, productType="com.apple.product-type.bundle.ui-testing", buildConfigurationList=config("test", {**base, "PRODUCT_NAME": "AppUITests", "PRODUCT_BUNDLE_IDENTIFIER": "local.blackterminal.BiQuadMonitor.UITests", "GENERATE_INFOPLIST_FILE": "YES", "TEST_TARGET_NAME": "BiQuadMonitorApp", "CODE_SIGN_ENTITLEMENTS": "Resources/Testing.entitlements"}), buildPhases=[obj("test-sources", "PBXSourcesBuildPhase", files=test_sources, buildActionMask=2147483647, runOnlyForDeploymentPostprocessing=0)], buildRules=[], dependencies=[dependency])
project = obj("project", "PBXProject", attributes={"LastUpgradeCheck": "1600", "TargetAttributes": {test: {"TestTargetID": app}}}, buildConfigurationList=config("project", base), compatibilityVersion="Xcode 14.0", developmentRegion="en", knownRegions=["en", "Base"], mainGroup=main_group, productRefGroup=products, projectDirPath="", projectRoot="", targets=[app, test], packageReferences=[package])
(ROOT / "BiQuadMonitor.xcodeproj/project.pbxproj").write_text("// !$*UTF8*$!\n" + encode(dict(archiveVersion=1, classes={}, objectVersion=56, objects=objects, rootObject=project)) + "\n")

def ref(target, name):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{name}" BlueprintName="{"BiQuadMonitorApp" if target == app else "AppUITests"}" ReferencedContainer="container:BiQuadMonitor.xcodeproj"/>'

scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.7">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref(app, "BiQuad Monitor.app")}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{ref(test, "AppUITests.xctest")}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="NO"><BuildableProductRunnable runnableDebuggingMode="0">{ref(app, "BiQuad Monitor.app")}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release"><BuildableProductRunnable runnableDebuggingMode="0">{ref(app, "BiQuad Monitor.app")}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>'''
(ROOT / "BiQuadMonitor.xcodeproj/xcshareddata/xcschemes/BiQuadMonitor.xcscheme").write_text(scheme + "\n")
