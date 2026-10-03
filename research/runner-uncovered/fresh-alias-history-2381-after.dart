class FavoriteDevice {final String fingerprint, ip, alias; final int port; const FavoriteDevice(this.fingerprint,this.ip,this.port,this.alias);}
class Device {final String fingerprint; final String? ip;final int port; const Device(this.fingerprint,this.ip,this.port);}
extension Lookup<T> on Iterable<T> {T? firstWhereOrNull(bool Function(T) p) {for(final e in this){if(p(e)) return e;}return null;}}

extension FavoriteDevicesExt on Iterable<FavoriteDevice> {
  /// Returns the favorite device with the given [device] or null if not found.
  FavoriteDevice? findDevice(Device device) {
    return firstWhereOrNull((e) => e.fingerprint == device.fingerprint && e.ip == device.ip && e.port == device.port) ??
        firstWhereOrNull((e) => e.fingerprint == device.fingerprint);
  }

  /// Returns true if the list contains the given [device].
  bool containsDevice(Device device) {
    return any((e) => e.fingerprint == device.fingerprint);
  }
}void main() {
 final favorites=[FavoriteDevice('same-cert','10.0.20.2',53317,'Home LAN'),FavoriteDevice('same-cert','100.95.193.205',53317,'NetBird LAN')];
 final actual=favorites.findDevice(Device('same-cert','100.95.193.205',53317));
 print('Display endpoint 100.95.193.205: ${actual?.alias}');
 if(actual?.alias!='NetBird LAN') throw StateError('Displayed IP matched the wrong favorite');
 if(favorites.findDevice(Device('same-cert','10.0.20.2',53317))?.alias!='Home LAN') throw StateError('Home alias lost');
 if(favorites.findDevice(Device('same-cert','10.0.20.99',53317))?.alias!='Home LAN') throw StateError('Roaming identity fallback lost');
 if(favorites.findDevice(Device('other-cert','100.95.193.205',53317))!=null) throw StateError('Different fingerprint incorrectly matched');
 print('PASS exact endpoint, primary endpoint, roaming fallback, unknown certificate');
}
