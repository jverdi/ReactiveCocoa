import Foundation
import ReactiveSwift
import enum Result.NoError

extension Reactive where Base: NSObject {
	/// Create a signal which sends a `next` event at the end of every invocation
	/// of `selector` on the object.
	///
	/// It completes when the object deinitializes.
	///
	/// - note: Observers to the resulting signal should not call the method
	///         specified by the selector.
	///
	/// - parameters:
	///   - selector: The selector to observe.
	///
	/// - returns:
	///   A trigger signal.
	public func trigger(for selector: Selector) -> Signal<(), NoError> {
		return base.setupInterception(for: selector).map { _ in }
	}

	/// Create a signal which sends a `next` event, containing an array of bridged
	/// arguments, at the end of every invocation of `selector` on the object.
	///
	/// It completes when the object deinitializes.
	///
	/// - note: Observers to the resulting signal should not call the method
	///         specified by the selector.
	///
	/// - parameters:
	///   - selector: The selector to observe.
	///
	/// - returns:
	///   A signal that sends an array of bridged arguments.
	public func signal(for selector: Selector) -> Signal<[Any?], NoError> {
		return base.setupInterception(for: selector).map(unpackInvocation)
	}
}

extension NSObject {
	/// Setup the method interception.
	///
	/// - parameters:
	///   - object: The object to be intercepted.
	///   - selector: The selector of the method to be intercepted.
	///
	/// - returns:
	///   A signal that sends the corresponding `NSInvocation` after every
	///   invocation of the method.
	@nonobjc fileprivate func setupInterception(for selector: Selector) -> Signal<AnyObject, NoError> {
		guard let method = class_getInstanceMethod(objcClass, selector) else {
			fatalError("Selector `\(selector)` does not exist in class `\(String(describing: objcClass))`.")
		}

		let typeEncoding = method_getTypeEncoding(method)!
		assert(checkTypeEncoding(typeEncoding))

		return synchronized {
			let alias = selector.alias
			let interopAlias = selector.interopAlias

			if let state = associatedValue(forKey: alias.utf8Start) as! InterceptingState? {
				return state.signal
			}

			let subclass: AnyClass = swizzleClass(self)

			// FIXME: Compiler asks to handle a mysterious throw.
			try! ReactiveCocoa.synchronized(subclass) {
				let isSwizzled = objc_getAssociatedObject(subclass, AssociationKey.intercepted) as! Bool? ?? false

				let signatureCache: SignatureCache
				let selectorCache: SelectorCache

				if isSwizzled {
					signatureCache = objc_getAssociatedObject(subclass, AssociationKey.signatureCache) as! SignatureCache
					selectorCache = objc_getAssociatedObject(subclass, AssociationKey.selectorCache) as! SelectorCache
				} else {
					signatureCache = SignatureCache()
					selectorCache = SelectorCache()
				}

				selectorCache.allocate(selector)

				if signatureCache[selector] == nil {
					let signature = NSMethodSignature.signature(withObjCTypes: typeEncoding)
					signatureCache[selector] = signature
				}

				if !isSwizzled {
					objc_setAssociatedObject(subclass, AssociationKey.signatureCache, signatureCache, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
					objc_setAssociatedObject(subclass, AssociationKey.selectorCache, selectorCache, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
					objc_setAssociatedObject(subclass, AssociationKey.intercepted, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

					enableMessageForwarding(subclass, selectorCache)
					setupMethodSignatureCaching(subclass, signatureCache)
				}

				// If an immediate implementation of the selector is found in the
				// runtime subclass the first time the selector is intercepted,
				// preserve the implementation.
				//
				// Example: KVO setters if the instance is swizzled by KVO before RAC
				//          does.
				if !class_respondsToSelector(subclass, interopAlias) {
					let immediateMethod = class_getImmediateMethod(subclass, selector)

					let immediateImpl: IMP? = immediateMethod.flatMap {
						let immediateImpl = method_getImplementation($0)
						return immediateImpl.flatMap { $0 != _rac_objc_msgForward ? $0 : nil }
					}

					if let impl = immediateImpl {
						class_addMethod(subclass, interopAlias, impl, typeEncoding)
					}
				}
			}

			let state = InterceptingState(lifetime: reactive.lifetime)
			setAssociatedValue(state, forKey: alias.utf8Start)

			// Start forwarding the messages of the selector.
			_ = class_replaceMethod(subclass, selector, _rac_objc_msgForward, typeEncoding)
			
			return state.signal
		}
	}
}

/// Swizzle `realClass` to enable message forwarding for method interception.
///
/// - parameters:
///   - realClass: The runtime subclass to be swizzled.
private func enableMessageForwarding(_ realClass: AnyClass, _ selectorCache: SelectorCache) {
	let perceivedClass: AnyClass = class_getSuperclass(realClass)

	typealias ForwardInvocationImpl = @convention(block) (Unmanaged<NSObject>, AnyObject) -> Void
	let newForwardInvocation: ForwardInvocationImpl = { objectRef, invocation in
		let selector = invocation.selector!
		let alias = selectorCache[main: selector]
		let interopAlias = selectorCache[interop: selector]

		defer {
			if let state = objectRef.takeUnretainedValue().associatedValue(forKey: alias.utf8Start) as! InterceptingState? {
				state.observer.send(value: invocation)
			}
		}

		let method = class_getInstanceMethod(perceivedClass, selector)!
		let typeEncoding = method_getTypeEncoding(method)

		if class_respondsToSelector(realClass, interopAlias) {
			// RAC has preserved an immediate implementation found in the runtime
			// subclass that was supplied by an external party.
			//
			// As the KVO setter relies on the selector to work, it has to be invoked
			// by swapping in the preserved implementation and restore to the message
			// forwarder afterwards.
			//
			// However, the IMP cache would be thrashed due to the swapping.

			let interopImpl = class_getMethodImplementation(realClass, interopAlias)
			let previousImpl = class_replaceMethod(realClass, selector, interopImpl, typeEncoding)
			invocation.invoke()
			_ = class_replaceMethod(realClass, selector, previousImpl, typeEncoding)

			return
		}

		if let impl = method_getImplementation(method), impl != _rac_objc_msgForward {
			// The perceived class, or its ancestors, responds to the selector.
			//
			// The implementation is invoked through the selector alias, which
			// reflects the latest implementation of the selector in the perceived
			// class.

			if class_getMethodImplementation(realClass, alias) != impl {
				// Update the alias if and only if the implementation has changed, so as
				// to avoid thrashing the IMP cache.
				_ = class_replaceMethod(realClass, alias, impl, typeEncoding)
			}

			invocation.setSelector(alias)
			invocation.invoke()

			return
		}

		// Forward the invocation to the closest `forwardInvocation(_:)` in the
		// inheritance hierarchy, or the default handler returned by the runtime
		// if it finds no implementation.
		typealias SuperForwardInvocation = @convention(c) (Unmanaged<NSObject>, Selector, AnyObject) -> Void
		let impl = class_getMethodImplementation(perceivedClass, ObjCSelector.forwardInvocation)
		let forwardInvocation = unsafeBitCast(impl, to: SuperForwardInvocation.self)
		forwardInvocation(objectRef, ObjCSelector.forwardInvocation, invocation)
	}

	_ = class_replaceMethod(realClass,
	                        ObjCSelector.forwardInvocation,
	                        imp_implementationWithBlock(newForwardInvocation as Any),
	                        ObjCMethodEncoding.forwardInvocation)
}

/// Swizzle `realClass` to accelerate the method signature retrieval, using a
/// signature cache that covers all known intercepted selectors of `realClass`.
///
/// - parameters:
///   - realClass: The runtime subclass to be swizzled.
///   - signatureCache: The method signature cache.
private func setupMethodSignatureCaching(_ realClass: AnyClass, _ signatureCache: SignatureCache) {
	let perceivedClass: AnyClass = class_getSuperclass(realClass)

	let newMethodSignatureForSelector: @convention(block) (Unmanaged<NSObject>, Selector) -> AnyObject? = { objectRef, selector in
		if let signature = signatureCache[selector] {
			return signature
		}

		typealias SuperMethodSignatureForSelector = @convention(c) (Unmanaged<NSObject>, Selector, Selector) -> AnyObject?
		let impl = class_getMethodImplementation(perceivedClass, ObjCSelector.methodSignatureForSelector)
		let methodSignatureForSelector = unsafeBitCast(impl, to: SuperMethodSignatureForSelector.self)
		return methodSignatureForSelector(objectRef, ObjCSelector.methodSignatureForSelector, selector)
	}

	_ = class_replaceMethod(realClass,
	                        ObjCSelector.methodSignatureForSelector,
	                        imp_implementationWithBlock(newMethodSignatureForSelector as Any),
	                        ObjCMethodEncoding.methodSignatureForSelector)
}

/// The state of an intercepted method specific to an instance.
private final class InterceptingState {
	let (signal, observer) = Signal<AnyObject, NoError>.pipe()

	/// Initialize a state specific to an instance.
	///
	/// - parameters:
	///   - lifetime: The lifetime of the instance.
	init(lifetime: Lifetime) {
		lifetime.ended.observeCompleted(observer.sendCompleted)
	}
}

private final class SelectorCache {
	private var map: [Selector: (main: Selector, interop: Selector)] = [:]

	init() {}

	/// Cache the aliases of the specified selector in the cache.
	///
	/// - warning: Any invocation of this method must be synchronized against the
	///            runtime subclass.
	@discardableResult
	func allocate(_ selector: Selector) -> (main: Selector, interop: Selector) {
		if let pair = map[selector] {
			return pair
		}

		var copy = map
		let aliases = (selector.alias, selector.interopAlias)
		copy[selector] = aliases
		map = copy

		return aliases
	}

	/// Get the alias of the specified selector.
	///
	/// - parameters:
	///   - selector: The selector alias.
	subscript(main selector: Selector) -> Selector {
		if let (main, _) = map[selector] {
			return main
		}

		return selector.alias
	}

	/// Get the secondary alias of the specified selector.
	///
	/// - parameters:
	///   - selector: The selector alias.
	subscript(interop selector: Selector) -> Selector {
		if let (_, interop) = map[selector] {
			return interop
		}

		return selector.interopAlias
	}
}

// The signature cache for classes that have been swizzled for method
// interception.
//
// Read-copy-update is used here, since the cache has multiple readers but only
// one writer.
private final class SignatureCache {
	// `Dictionary` takes 8 bytes for the reference to its storage and does CoW.
	// So it should not encounter any corrupted, partially updated state.
	private var map: [Selector: AnyObject] = [:]

	init() {}

	/// Get or set the signature for the specified selector.
	///
	/// - warning: Any invocation of the setter must be synchronized against the
	///            runtime subclass.
	///
	/// - parameters:
	///   - selector: The method signature.
	subscript(selector: Selector) -> AnyObject? {
		get {
			return map[selector]
		}
		set {
			if map[selector] == nil {
				var newMap = map
				newMap[selector] = newValue
				map = newMap
			}
		}
	}
}

/// Assert that the method does not contain types that cannot be intercepted.
///
/// - parameters:
///   - types: The type encoding C string of the method.
///
/// - returns:
///   `true`.
private func checkTypeEncoding(_ types: UnsafePointer<CChar>) -> Bool {
	// Some types, including vector types, are not encoded. In these cases the
	// signature starts with the size of the argument frame.
	assert(types.pointee < Int8(UInt8(ascii: "1")) || types.pointee > Int8(UInt8(ascii: "9")),
	       "unknown method return type not supported in type encoding: \(String(cString: types))")

	assert(types.pointee != Int8(UInt8(ascii: "(")), "union method return type not supported")
	assert(types.pointee != Int8(UInt8(ascii: "{")), "struct method return type not supported")
	assert(types.pointee != Int8(UInt8(ascii: "[")), "array method return type not supported")

	assert(types.pointee != Int8(UInt8(ascii: "j")), "complex method return type not supported")

	return true
}

/// Extract the arguments of an `NSInvocation` as an array of objects.
///
/// - parameters:
///   - invocation: The `NSInvocation` to unpack.
///
/// - returns:
///   An array of objects.
private func unpackInvocation(_ invocation: AnyObject) -> [Any?] {
	let invocation = invocation as AnyObject
	let methodSignature = invocation.objcMethodSignature!
	let count = UInt(methodSignature.numberOfArguments!)

	var bridged = [Any?]()
	bridged.reserveCapacity(Int(count - 2))

	// Ignore `self` and `_cmd` at index 0 and 1.
	for position in 2 ..< count {
		let rawEncoding = methodSignature.argumentType(at: position)
		let encoding = ObjCTypeEncoding(rawValue: rawEncoding.pointee) ?? .undefined

		func extract<U>(_ type: U.Type) -> U {
			let pointer = UnsafeMutableRawPointer.allocate(bytes: MemoryLayout<U>.size,
			                                               alignedTo: MemoryLayout<U>.alignment)
			defer {
				pointer.deallocate(bytes: MemoryLayout<U>.size,
				                   alignedTo: MemoryLayout<U>.alignment)
			}

			invocation.copy(to: pointer, forArgumentAt: Int(position))
			return pointer.assumingMemoryBound(to: type).pointee
		}

		switch encoding {
		case .char:
			bridged.append(NSNumber(value: extract(CChar.self)))
		case .int:
			bridged.append(NSNumber(value: extract(CInt.self)))
		case .short:
			bridged.append(NSNumber(value: extract(CShort.self)))
		case .long:
			bridged.append(NSNumber(value: extract(CLong.self)))
		case .longLong:
			bridged.append(NSNumber(value: extract(CLongLong.self)))
		case .unsignedChar:
			bridged.append(NSNumber(value: extract(CUnsignedChar.self)))
		case .unsignedInt:
			bridged.append(NSNumber(value: extract(CUnsignedInt.self)))
		case .unsignedShort:
			bridged.append(NSNumber(value: extract(CUnsignedShort.self)))
		case .unsignedLong:
			bridged.append(NSNumber(value: extract(CUnsignedLong.self)))
		case .unsignedLongLong:
			bridged.append(NSNumber(value: extract(CUnsignedLongLong.self)))
		case .float:
			bridged.append(NSNumber(value: extract(CFloat.self)))
		case .double:
			bridged.append(NSNumber(value: extract(CDouble.self)))
		case .bool:
			bridged.append(NSNumber(value: extract(CBool.self)))
		case .object:
			bridged.append(extract((AnyObject?).self))
		case .type:
			bridged.append(extract((AnyClass?).self))
		case .selector:
			bridged.append(extract((Selector?).self))
		case .undefined:
			var size = 0, alignment = 0
			NSGetSizeAndAlignment(rawEncoding, &size, &alignment)
			let buffer = UnsafeMutableRawPointer.allocate(bytes: size, alignedTo: alignment)
			defer { buffer.deallocate(bytes: size, alignedTo: alignment) }

			invocation.copy(to: buffer, forArgumentAt: Int(position))
			bridged.append(NSValue(bytes: buffer, objCType: rawEncoding))
		}
	}

	return bridged
}
