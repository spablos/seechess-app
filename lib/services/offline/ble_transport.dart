import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';

import 'transport.dart';

/// Bluetooth LE transport: no network of any kind required — the host
/// advertises a Seechess GATT service, the guest scans and connects.
///
/// Wire shape: the guest writes frames to the RX characteristic; the host
/// notifies frames on TX. A frame is a 4-byte little-endian length followed
/// by UTF-8 JSON, split into MTU-sized chunks (GATT preserves write/notify
/// ordering, so plain concatenation reassembles correctly).

final serviceUuid = UUID.fromString('5eec4e55-c4e5-4a45-9c1e-3b7a2d4f8c01');
final _rxUuid = UUID.fromString('5eec4e55-c4e5-4a45-9c1e-3b7a2d4f8c02');
final _txUuid = UUID.fromString('5eec4e55-c4e5-4a45-9c1e-3b7a2d4f8c03');

/// Accumulates chunked bytes and yields complete length-prefixed frames.
class FrameBuffer {
  final _bytes = BytesBuilder();

  static Uint8List encode(String json) {
    final payload = utf8Encode(json);
    final out = BytesBuilder();
    out.add([
      payload.length & 0xff,
      (payload.length >> 8) & 0xff,
      (payload.length >> 16) & 0xff,
      (payload.length >> 24) & 0xff,
    ]);
    out.add(payload);
    return out.toBytes();
  }

  static Uint8List utf8Encode(String s) => Uint8List.fromList(utf8.encode(s));

  List<String> add(Uint8List chunk) {
    _bytes.add(chunk);
    final out = <String>[];
    var data = _bytes.toBytes();
    while (data.length >= 4) {
      final len = data[0] | (data[1] << 8) | (data[2] << 16) | (data[3] << 24);
      if (data.length < 4 + len) break;
      out.add(utf8.decode(Uint8List.sublistView(data, 4, 4 + len)));
      data = Uint8List.sublistView(data, 4 + len);
    }
    _bytes.clear();
    _bytes.add(data);
    return out;
  }

  void reset() => _bytes.clear();
}

List<Uint8List> _chunks(Uint8List frame, int size) => [
  for (var i = 0; i < frame.length; i += size)
    Uint8List.sublistView(
      frame,
      i,
      i + size > frame.length ? frame.length : i + size,
    ),
];

// ----------------------------------------------------------------- host

class BleHostTransport extends HostTransport {
  BleHostTransport({required this.advertiseName});

  /// Shown in the guest's nearby list ("Seechess" prefix is implicit via
  /// the service UUID filter — advertise the player's name itself).
  final String advertiseName;

  final _pm = PeripheralManager();
  final _subs = <StreamSubscription>[];
  final _rx = FrameBuffer();
  Central? _central;
  bool _closed = false;

  // notifyCharacteristic matches by instance hashCode: the registered
  // objects must be the ones used for every later call
  final _rxChar = GATTCharacteristic.mutable(
    uuid: _rxUuid,
    properties: [
      GATTCharacteristicProperty.write,
      GATTCharacteristicProperty.writeWithoutResponse,
    ],
    permissions: [GATTCharacteristicPermission.write],
    descriptors: [],
  );
  final _txChar = GATTCharacteristic.mutable(
    uuid: _txUuid,
    properties: [GATTCharacteristicProperty.notify],
    permissions: [GATTCharacteristicPermission.read],
    descriptors: [],
  );

  /// 'advertising' | 'off' (Bluetooth powered off / unauthorized) |
  /// 'unsupported' — for the lobby's status row.
  String status = 'off';

  @override
  Future<void> start() async {
    _subs.add(_pm.stateChanged.listen((e) => _onState(e.state)));
    _subs.add(
      _pm.characteristicWriteRequested.listen((e) async {
        await _pm.respondWriteRequest(e.request);
        if (e.characteristic.uuid != _rxUuid) return;
        for (final msg in _rx.add(e.request.value)) {
          onMessage?.call(msg);
        }
      }),
    );
    _subs.add(
      _pm.characteristicNotifyStateChanged.listen((e) {
        if (e.characteristic.uuid != _txUuid) return;
        if (e.state) {
          _central = e.central;
          _rx.reset();
        } else if (_central?.uuid == e.central.uuid) {
          _central = null;
          onPeerLost?.call();
        }
      }),
    );
    // Android reports disconnects here rather than via notify-state
    try {
      _subs.add(
        _pm.connectionStateChanged.listen((e) {
          if (e.state == ConnectionState.disconnected &&
              _central?.uuid == e.central.uuid) {
            _central = null;
            onPeerLost?.call();
          }
        }),
      );
    } on UnsupportedError {
      // iOS/macOS: notify-state unsubscribe covers it
    }
    await _onState(_pm.state);
  }

  Future<void> _onState(BluetoothLowEnergyState state) async {
    if (_closed) return;
    if (state == BluetoothLowEnergyState.unauthorized) {
      try {
        await _pm.authorize();
        return; // a state change follows
      } catch (_) {}
    }
    if (state == BluetoothLowEnergyState.unsupported) {
      status = 'unsupported';
      onChanged?.call();
      return;
    }
    if (state != BluetoothLowEnergyState.poweredOn) {
      status = 'off';
      onChanged?.call();
      return;
    }
    try {
      await _pm.removeAllServices();
      await _pm.addService(
        GATTService(
          uuid: serviceUuid,
          isPrimary: true,
          includedServices: [],
          characteristics: [_rxChar, _txChar],
        ),
      );
      await _pm.startAdvertising(
        Advertisement(name: advertiseName, serviceUUIDs: [serviceUuid]),
      );
      status = 'advertising';
    } catch (e) {
      debugPrint('BLE host: $e');
      status = 'off';
    }
    onChanged?.call();
  }

  /// Serialized so chunk order is never interleaved between two sends.
  Future<void> _sendQueue = Future.value();

  @override
  void send(String json) {
    final central = _central;
    if (central == null) return;
    _sendQueue = _sendQueue.then((_) async {
      try {
        final max = await _pm.getMaximumNotifyLength(central);
        final frame = FrameBuffer.encode(json);
        for (final chunk in _chunks(frame, max < 20 ? 20 : max)) {
          await _pm.notifyCharacteristic(central, _txChar, value: chunk);
        }
      } catch (e) {
        debugPrint('BLE host send: $e');
      }
    });
  }

  @override
  Future<void> close() async {
    _closed = true;
    for (final s in _subs) {
      await s.cancel();
    }
    try {
      await _pm.stopAdvertising();
      await _pm.removeAllServices();
    } catch (_) {}
  }
}

// ---------------------------------------------------------------- guest

class BleGuestTransport extends GuestTransport {
  BleGuestTransport({required this.peripheral, required this.hostName});

  final Peripheral peripheral;
  final String hostName;

  final _cm = CentralManager();
  final _subs = <StreamSubscription>[];
  final _rx = FrameBuffer();
  GATTCharacteristic? _writeChar;
  bool _up = false;
  bool _closed = false;

  @override
  String get label => hostName;

  @override
  Future<void> connect() async {
    _subs.add(
      _cm.characteristicNotified.listen((e) {
        if (e.characteristic.uuid != _txUuid) return;
        for (final msg in _rx.add(e.value)) {
          onMessage?.call(msg);
        }
      }),
    );
    _subs.add(
      _cm.connectionStateChanged.listen((e) {
        if (e.peripheral.uuid == peripheral.uuid &&
            e.state == ConnectionState.disconnected &&
            _up) {
          _up = false;
          onLink?.call(false);
        }
      }),
    );
    final began = DateTime.now();
    while (!_closed) {
      if (!_up) {
        try {
          await _cm.connect(peripheral);
          try {
            await _cm.requestMTU(peripheral, mtu: 517);
          } catch (_) {} // Android-only nicety
          final services = await _cm.discoverGATT(peripheral);
          final svc = services.firstWhere((s) => s.uuid == serviceUuid);
          _writeChar = svc.characteristics.firstWhere((c) => c.uuid == _rxUuid);
          final tx = svc.characteristics.firstWhere((c) => c.uuid == _txUuid);
          _rx.reset();
          await _cm.setCharacteristicNotifyState(peripheral, tx, state: true);
          _up = true;
          onLink?.call(true);
        } catch (e) {
          debugPrint('BLE guest connect: $e');
          if (_closed) return;
          if (DateTime.now().difference(began) > const Duration(seconds: 12)) {
            onStruggling?.call();
          }
          onLink?.call(false);
        }
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  Future<void> _sendQueue = Future.value();

  @override
  void send(String json) {
    if (!_up) return;
    _sendQueue = _sendQueue.then((_) async {
      final char = _writeChar;
      if (!_up || char == null) return;
      try {
        final max = await _cm.getMaximumWriteLength(
          peripheral,
          type: GATTCharacteristicWriteType.withResponse,
        );
        final frame = FrameBuffer.encode(json);
        for (final chunk in _chunks(frame, max < 20 ? 20 : max)) {
          await _cm.writeCharacteristic(
            peripheral,
            char,
            value: chunk,
            type: GATTCharacteristicWriteType.withResponse,
          );
        }
      } catch (e) {
        debugPrint('BLE guest send: $e');
      }
    });
  }

  @override
  Future<void> close() async {
    _closed = true;
    for (final s in _subs) {
      await s.cancel();
    }
    try {
      await _cm.disconnect(peripheral);
    } catch (_) {}
  }
}

// -------------------------------------------------------------- scanner

/// A nearby Seechess host, as seen by the join screen.
class NearbyHost {
  NearbyHost(this.peripheral, this.name);
  final Peripheral peripheral;
  final String name;
}

/// Scans for Seechess hosts and keeps a live de-duplicated list.
class BleScanner {
  final _cm = CentralManager();
  final _subs = <StreamSubscription>[];
  final _seen = <String, NearbyHost>{};

  final hosts = ValueNotifier<List<NearbyHost>>([]);

  /// 'scanning' | 'off' | 'unsupported'
  final status = ValueNotifier<String>('off');

  Future<void> start() async {
    _subs.add(_cm.stateChanged.listen((e) => _onState(e.state)));
    _subs.add(
      _cm.discovered.listen((e) {
        String? name;
        try {
          name = e.advertisement.name;
        } catch (_) {} // platforms without adv names
        final key = e.peripheral.uuid.toString();
        if (_seen[key]?.name == (name ?? _seen[key]?.name)) {
          if (_seen.containsKey(key)) return; // nothing new
        }
        _seen[key] = NearbyHost(e.peripheral, name ?? 'Seechess host');
        hosts.value = _seen.values.toList();
      }),
    );
    await _onState(_cm.state);
  }

  Future<void> _onState(BluetoothLowEnergyState state) async {
    if (state == BluetoothLowEnergyState.unauthorized) {
      try {
        await _cm.authorize();
        return;
      } catch (_) {}
    }
    if (state == BluetoothLowEnergyState.unsupported) {
      status.value = 'unsupported';
      return;
    }
    if (state != BluetoothLowEnergyState.poweredOn) {
      status.value = 'off';
      return;
    }
    try {
      await _cm.startDiscovery(serviceUUIDs: [serviceUuid]);
      status.value = 'scanning';
    } catch (e) {
      debugPrint('BLE scan: $e');
      status.value = 'off';
    }
  }

  /// The system page where the user can grant Bluetooth permission.
  Future<void> openSettings() async {
    try {
      await _cm.showAppSettings();
    } catch (_) {}
  }

  Future<void> stop() async {
    for (final s in _subs) {
      await s.cancel();
    }
    try {
      await _cm.stopDiscovery();
    } catch (_) {}
  }
}
