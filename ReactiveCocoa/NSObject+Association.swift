import ReactiveSwift

internal struct AssociationKey {
	private static let contiguous = UnsafeMutablePointer<UInt8>.allocate(capacity: 6)

	/// Nullable. `true` indicates the runtime subclass has already been prepared for method
	/// interception.
	static let intercepted = contiguous

	/// Holds the method signature cache of the runtime subclass.
	static let signatureCache = contiguous + 1

	/// Holds the method selector cache of the runtime subclass.
	static let selectorCache = contiguous + 2

	/// Nullable. Exists only in runtime subclasses generated by external parties.
	/// `true` indicates the runtime subclass has already been swizzled.
	static let runtimeSubclassed = contiguous + 3

	/// Holds the `Lifetime` of the object.
	static let lifetime = contiguous + 4

	/// Holds the `Lifetime.Token` of the object.
	static let lifetimeToken = contiguous + 5
}

extension Reactive where Base: NSObject {
	/// Retrieve the associated value for the specified key. If the value does not
	/// exist, `initial` would be called and the returned value would be
	/// associated subsequently.
	///
	/// - parameters:
	///   - key: An optional key to differentiate different values.
	///   - initial: The action that supples an initial value.
	///
	/// - returns:
	///   The associated value for the specified key.
	internal func associatedValue<T>(forKey key: StaticString = #function, initial: (Base) -> T) -> T {
		var value = base.associatedValue(forKey: key.utf8Start) as! T?
		if value == nil {
			value = initial(base)
			base.setAssociatedValue(value, forKey: key.utf8Start)
		}
		return value!
	}
}

extension NSObject {
	/// Retrieve the associated value for the specified key.
	///
	/// - parameters:
	///   - key: The key.
	///
	/// - returns:
	///   The associated value, or `nil` if no value is associated with the key.
	@nonobjc internal func associatedValue(forKey key: UnsafeRawPointer) -> Any? {
		return objc_getAssociatedObject(self, key)
	}

	/// Set the associated value for the specified key.
	///
	/// - parameters:
	///   - value: The value to be associated.
	///   - key: The key.
	///   - weak: `true` if the value should be weakly referenced. `false`
	///           otherwise.
	@nonobjc internal func setAssociatedValue(_ value: Any?, forKey key: UnsafeRawPointer, weak: Bool = false) {
		objc_setAssociatedObject(self, key, value, weak ? .OBJC_ASSOCIATION_ASSIGN : .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
	}
}
