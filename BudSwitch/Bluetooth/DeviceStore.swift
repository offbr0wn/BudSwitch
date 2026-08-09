import Foundation

/// The chosen device address, persisted across launches.
///
/// Addresses are stored in `IOBluetoothDevice.addressString` form — dash-separated and
/// lowercase, e.g. `aa-bb-cc-dd-ee-ff`.
enum DeviceStore {
    private enum Key {
        static let address = "selectedDeviceAddress"
        static let name = "selectedDeviceName"
    }

    static var address: String? {
        get { UserDefaults.standard.string(forKey: Key.address) }
        set { UserDefaults.standard.set(newValue, forKey: Key.address) }
    }

    static var name: String? {
        get { UserDefaults.standard.string(forKey: Key.name) }
        set { UserDefaults.standard.set(newValue, forKey: Key.name) }
    }

    static func select(address: String, name: String) {
        self.address = address
        self.name = name
        Log.app.log("selected device \(name, privacy: .public) \(address, privacy: .public)")
    }
}
