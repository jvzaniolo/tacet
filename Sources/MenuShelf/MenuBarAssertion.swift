import Foundation
import ObjectiveC

/// Thin, fail-soft shim over MenuBarAgent's visibility restriction
/// ("assessment mode") in the private MenuBarClientCore framework.
///
/// Provenance (NOTES §11): written from the class and selector names only, as
/// listed from the framework's own Objective-C runtime on macOS 27.0.1 and as
/// described publicly (Thaw discussion #737, the Apache-2.0 BarNook/Ellipsis
/// docs). No third-party code was used.
///
///     MBAssessmentModeConfiguration -initWithAllowedSystemItems:allowedBundleIdentifiers:
///     MBAssessmentModeAssertion     -init
///                                   -activateWithConfiguration:completionHandler:
///                                   -invalidate
///
/// While an assertion is active, MenuBarAgent shows only the apps (bundle IDs)
/// and Apple items (integer codes) in its allow-list. The newest active
/// assertion wins.
enum MenuBarAssertionAPI {
    static let frameworkPath = "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore"

    private static let loaded: Bool = dlopen(frameworkPath, RTLD_NOW) != nil

    static let configurationClass: AnyClass? = loaded ? NSClassFromString("MBAssessmentModeConfiguration") : nil
    static let assertionClass: AnyClass? = loaded ? NSClassFromString("MBAssessmentModeAssertion") : nil

    static let initConfigSelector = NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:")
    static let activateSelector = NSSelectorFromString("activateWithConfiguration:completionHandler:")
    static let invalidateSelector = NSSelectorFromString("invalidate")

    /// Everything we call exists on this system.
    static var isAvailable: Bool {
        guard let config = configurationClass, let assertion = assertionClass else { return false }
        return class_getInstanceMethod(config, initConfigSelector) != nil
            && class_getInstanceMethod(assertion, activateSelector) != nil
            && class_getInstanceMethod(assertion, invalidateSelector) != nil
    }

    /// Apple items are allowed by integer code. 0–6 follow the public
    /// `AEMenuBarItem` constants in order (Battery, Bluetooth, Clock, Displays,
    /// Keyboard, Volume, Wi-Fi); 8 is Control Center. Unknown codes are
    /// ignored, so allow a generous range.
    static let allSystemItemCodes: [NSNumber] = (0...40).map { NSNumber(value: $0) }
}

/// One activation of the restriction. Keep it alive while it should apply;
/// `invalidate()` ends it.
final class MenuBarAssertion {
    private let object: NSObject
    let allowedBundleIDs: Set<String>
    private(set) var isInvalidated = false

    private typealias InitConfig = @convention(c) (AnyObject, Selector, NSArray, NSArray) -> Unmanaged<AnyObject>?
    /// The completion block's parameters aren't published. The block receives
    /// raw register values (logged, never dereferenced) so a wrong guess
    /// can't crash; see NOTES §11 for what was observed.
    typealias RawCompletion = @convention(block) (UInt, UInt) -> Void
    private typealias Activate = @convention(c) (AnyObject, Selector, AnyObject, RawCompletion) -> Void
    private typealias Invalidate = @convention(c) (AnyObject, Selector) -> Void

    init?(allowing bundleIDs: Set<String>, systemItems: [NSNumber] = MenuBarAssertionAPI.allSystemItemCodes) {
        guard MenuBarAssertionAPI.isAvailable,
              let configClass = MenuBarAssertionAPI.configurationClass as? NSObject.Type,
              let assertionClass = MenuBarAssertionAPI.assertionClass as? NSObject.Type,
              let initIMP = class_getMethodImplementation(configClass, MenuBarAssertionAPI.initConfigSelector) else { return nil }
        let initConfig = unsafeBitCast(initIMP, to: InitConfig.self)
        let rawConfig = configClass.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue()
        guard let config = initConfig(rawConfig, MenuBarAssertionAPI.initConfigSelector,
                                      systemItems as NSArray, Array(bundleIDs).sorted() as NSArray)?.takeRetainedValue() else { return nil }
        self.configuration = config
        self.object = assertionClass.init()
        self.allowedBundleIDs = bundleIDs
    }

    private let configuration: AnyObject

    /// Activates asynchronously. `completion(firstRaw, secondRaw)` is called by
    /// MenuBarAgent's client on its own queue.
    func activate(completion: @escaping (UInt, UInt) -> Void) {
        guard let imp = class_getMethodImplementation(type(of: object), MenuBarAssertionAPI.activateSelector) else { return }
        let activate = unsafeBitCast(imp, to: Activate.self)
        let block: RawCompletion = { a, b in completion(a, b) }
        activate(object, MenuBarAssertionAPI.activateSelector, configuration, block)
    }

    func invalidate() {
        guard !isInvalidated,
              let imp = class_getMethodImplementation(type(of: object), MenuBarAssertionAPI.invalidateSelector) else { return }
        isInvalidated = true
        unsafeBitCast(imp, to: Invalidate.self)(object, MenuBarAssertionAPI.invalidateSelector)
    }

    deinit { invalidate() }
}
