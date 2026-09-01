import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/offline/ble_transport.dart';
import '../services/offline/hotspot.dart';
import '../services/offline/match_session.dart';
import 'match.dart';

/// Offline two-device match lobby (PRD §4): host or join over a tiny LAN —
/// same Wi-Fi, or one phone's Personal Hotspot mid-flight.
class OfflineLobbyScreen extends StatefulWidget {
  const OfflineLobbyScreen({super.key});

  @override
  State<OfflineLobbyScreen> createState() => _OfflineLobbyScreenState();
}

class _OfflineLobbyScreenState extends State<OfflineLobbyScreen> {
  final _name = TextEditingController();
  TimeControl _tc = const TimeControl(5, 0);
  int _color = 1; // 0 white, 1 random, 2 black

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      final saved = prefs.getString('player_name');
      if (saved != null && mounted) setState(() => _name.text = saved);
    });
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<String> _confirmedName() async {
    var name = _name.text.trim();
    if (name.isEmpty) name = 'Player';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('player_name', name);
    return name;
  }

  Future<void> _host() async {
    final name = await _confirmedName();
    final session = HostSession(
      name: name,
      tc: _tc,
      hostWhite: _color == 1 ? null : _color == 0,
    );
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => _HostWaitScreen(session: session)),
    );
  }

  Future<void> _join() async {
    final name = await _confirmedName();
    if (!mounted) return;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => JoinMatchScreen(myName: name)));
  }

  Future<void> _customTime() async {
    final minutes = TextEditingController(text: '${_tc.minutes}');
    final inc = TextEditingController(text: '${_tc.incrementSec}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Custom time'),
        content: Row(
          children: [
            Expanded(
              child: TextField(
                controller: minutes,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Minutes'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: inc,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Increment (s)'),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Set'),
          ),
        ],
      ),
    );
    if (ok == true) {
      final m = (int.tryParse(minutes.text) ?? 5).clamp(1, 180);
      final i = (int.tryParse(inc.text) ?? 0).clamp(0, 60);
      setState(() => _tc = TimeControl(m, i));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isPreset = TimeControl.presets.any(
      (p) =>
          p.$1.minutes == _tc.minutes && p.$1.incrementSec == _tc.incrementSec,
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Play offline')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Your name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),
            Text('Time control', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (tc, kind) in TimeControl.presets)
                  ChoiceChip(
                    label: Text('${tc.display} · $kind'),
                    selected:
                        _tc.minutes == tc.minutes &&
                        _tc.incrementSec == tc.incrementSec,
                    onSelected: (_) => setState(() => _tc = tc),
                  ),
                ChoiceChip(
                  label: Text(isPreset ? 'Custom…' : 'Custom ${_tc.display}'),
                  selected: !isPreset,
                  onSelected: (_) => _customTime(),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Text(
              'Your color (when hosting)',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('White')),
                ButtonSegment(value: 1, label: Text('Random')),
                ButtonSegment(value: 2, label: Text('Black')),
              ],
              selected: {_color},
              onSelectionChanged: (s) => setState(() => _color = s.first),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              icon: const Icon(Icons.wifi_tethering),
              label: const Text('Host a match'),
              onPressed: _host,
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Join a match'),
              onPressed: _join,
            ),
            const SizedBox(height: 24),
            Text(
              'Both phones must be on the same Wi-Fi. No internet needed — '
              'on a plane, one phone turns on its Personal Hotspot and the '
              'other joins it. Some airlines restrict hotspot use; check '
              'before you play mid-flight.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Host side: QR + address while waiting, then the start button.
class _HostWaitScreen extends StatefulWidget {
  const _HostWaitScreen({required this.session});
  final HostSession session;

  @override
  State<_HostWaitScreen> createState() => _HostWaitScreenState();
}

class _HostWaitScreenState extends State<_HostWaitScreen> {
  bool _entered = false;

  @override
  void initState() {
    super.initState();
    widget.session.start();
    widget.session.addListener(_onSession);
  }

  void _onSession() {
    if (!mounted) return;
    if (widget.session.started && !_entered) {
      _entered = true;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => MatchScreen(session: widget.session)),
      );
      return;
    }
    setState(() {});
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSession);
    // entering the match hands the session over; backing out ends it
    if (!_entered) widget.session.shutdown();
    super.dispose();
  }

  /// One quiet line: the host is also reachable over Bluetooth (or why
  /// not). Works with no network at all — worth saying exactly when the
  /// QR path is down.
  Widget _bleRow(ThemeData theme, HostSession session) {
    final status = session.bleStatus;
    if (status == null || status == 'unsupported') {
      return const SizedBox.shrink();
    }
    final advertising = status == 'advertising';
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            advertising ? Icons.bluetooth_audio : Icons.bluetooth_disabled,
            size: 18,
            color: advertising
                ? theme.colorScheme.primary
                : theme.colorScheme.outline,
          ),
          const SizedBox(width: 6),
          Text(
            advertising
                ? 'Also joinable nearby via Bluetooth'
                : 'Turn on Bluetooth to be joinable without Wi-Fi',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = widget.session;
    final address = session.address;
    return Scaffold(
      appBar: AppBar(title: const Text('Hosting')),
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (session.noNetwork) ...[
                Icon(Icons.wifi_off, size: 48, color: theme.colorScheme.error),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: Text(
                    'No network. Join a Wi-Fi network or turn on a hotspot '
                    'on either phone — internet is not needed, the two '
                    'phones just have to be on the same network.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                const SizedBox(height: 16),
                if (session.canHotspot)
                  FilledButton.icon(
                    icon: const Icon(Icons.wifi_tethering),
                    label: const Text('Start a hotspot'),
                    onPressed: () async {
                      final ok = await session.startHotspot();
                      if (!ok && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Couldn\'t start a hotspot — check that '
                              'location is allowed and tethering is off',
                            ),
                          ),
                        );
                      }
                    },
                  )
                else
                  FilledButton.icon(
                    icon: const Icon(Icons.refresh),
                    label: const Text('Check again'),
                    onPressed: session.recheckNetwork,
                  ),
                if (session.canHotspot)
                  TextButton(
                    onPressed: session.recheckNetwork,
                    child: const Text('I joined a network — check again'),
                  ),
                _bleRow(theme, session),
              ] else if (address == null)
                const CircularProgressIndicator()
              else ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: QrImageView(data: session.qrPayload!, size: 220),
                ),
                const SizedBox(height: 12),
                SelectableText(
                  address,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontFeatures: [const FontFeature.tabularFigures()],
                  ),
                ),
                if (session.hotspotSsid != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Hotspot "${session.hotspotSsid}" is on — scanning '
                      'the QR joins it automatically',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                _bleRow(theme, session),
                const SizedBox(height: 24),
                if (session.oppName == null) ...[
                  const CircularProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(
                    'Waiting for your opponent to scan…',
                    style: theme.textTheme.bodyMedium,
                  ),
                ] else ...[
                  Icon(
                    Icons.person,
                    size: 40,
                    color: theme.colorScheme.primary,
                  ),
                  Text(
                    '${session.oppName} joined',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    icon: const Icon(Icons.play_arrow),
                    label: Text('Start · ${session.timeControl.display}'),
                    onPressed: session.beginMatch,
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Guest side: scan the host's QR (or type the address), then wait for
/// start. Also the landing screen when a QR is scanned with the system
/// camera — the seechess:// deep link arrives with [address] prefilled.
class JoinMatchScreen extends StatefulWidget {
  const JoinMatchScreen({
    super.key,
    this.myName,
    this.address,
    this.hotspotSsid,
    this.hotspotPass,
  });

  /// Session display name; when null (deep-link entry) the saved one is
  /// used, defaulting to 'Player'.
  final String? myName;

  /// "ip:port" to connect to immediately, skipping the scanner.
  final String? address;

  /// When the QR carried hotspot credentials, join that network first.
  final String? hotspotSsid;
  final String? hotspotPass;

  @override
  State<JoinMatchScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinMatchScreen> {
  final _address = TextEditingController();
  GuestSession? _session;
  bool _entered = false;
  String _myName = 'Player';

  /// Live list of Seechess hosts advertising over Bluetooth nearby.
  BleScanner? _scanner;

  @override
  void initState() {
    super.initState();
    _resolveNameThenAutoConnect();
    if (widget.address == null) {
      final scanner = BleScanner();
      _scanner = scanner;
      unawaited(scanner.start());
    }
  }

  Future<void> _resolveNameThenAutoConnect() async {
    var name = widget.myName;
    if (name == null) {
      final prefs = await SharedPreferences.getInstance();
      name = prefs.getString('player_name');
    }
    if (name != null && name.trim().isNotEmpty) _myName = name.trim();
    final address = widget.address;
    if (address != null && address.contains(':') && mounted) {
      await _joinHotspotIfAny(widget.hotspotSsid, widget.hotspotPass);
      if (mounted) _connect(address);
    }
  }

  bool _joiningHotspot = false;

  /// The QR named the host's hotspot: hop onto it before dialing. Failure
  /// is non-fatal — connect() retries and shows the unreachable hint.
  Future<void> _joinHotspotIfAny(String? ssid, String? pass) async {
    if (ssid == null || pass == null) return;
    setState(() => _joiningHotspot = true);
    await Hotspot.guestJoin(ssid, pass);
    if (mounted) setState(() => _joiningHotspot = false);
  }

  @override
  void dispose() {
    unawaited(_scanner?.stop());
    _session?.removeListener(_onSession);
    if (!_entered) _session?.shutdown();
    _address.dispose();
    super.dispose();
  }

  void _connect(String address) {
    if (_session != null) return;
    _adopt(GuestSession(name: _myName, hostAddress: address));
  }

  void _connectBle(NearbyHost host) {
    if (_session != null) return;
    unawaited(_scanner?.stop()); // scanning fights the connection
    _adopt(
      GuestSession(
        name: _myName,
        transport: BleGuestTransport(
          peripheral: host.peripheral,
          hostName: host.name,
        ),
      ),
    );
  }

  void _adopt(GuestSession session) {
    _session = session;
    session.addListener(_onSession);
    unawaited(session.connect());
    setState(() {});
  }

  void _onSession() {
    if (!mounted) return;
    final session = _session!;
    if (session.started && !_entered) {
      _entered = true;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => MatchScreen(session: session)),
      );
      return;
    }
    setState(() {});
  }

  void _onScan(BarcodeCapture capture) {
    if (_session != null || _joiningHotspot) return;
    for (final code in capture.barcodes) {
      final raw = code.rawValue;
      if (raw == null || !raw.startsWith('seechess://')) continue;
      final uri = Uri.tryParse(raw);
      if (uri == null || uri.host.isEmpty || !uri.hasPort) continue;
      final ssid = uri.queryParameters['ssid'];
      final pass = uri.queryParameters['pass'];
      final address = '${uri.host}:${uri.port}';
      if (ssid != null && pass != null) {
        _joinHotspotIfAny(ssid, pass).then((_) {
          if (mounted) _connect(address);
        });
      } else {
        _connect(address);
      }
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = _session;
    return Scaffold(
      appBar: AppBar(title: const Text('Join a match')),
      body: SafeArea(
        // deep-link entry connects directly — never build the scanner (and
        // its camera prompt) for a frame while the session spins up
        child: session != null || widget.address != null || _joiningHotspot
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(
                      _joiningHotspot
                          ? 'Joining the host\'s hotspot…'
                          : session == null
                          ? 'Connecting…'
                          : session.connected
                          ? (session.oppName == null
                                ? 'Connected — waiting…'
                                : 'Waiting for ${session.oppName} to start…')
                          : 'Connecting to ${session.hostAddress}…',
                      style: theme.textTheme.titleMedium,
                    ),
                    if (session != null &&
                        !session.connected &&
                        session.struggling) ...[
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 40),
                        child: Text(
                          'Can\'t reach the host at ${session.hostAddress}. '
                          'Check that both phones are on the same Wi-Fi or '
                          'hotspot — still trying…',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              )
            : Column(
                children: [
                  Expanded(child: MobileScanner(onDetect: _onScan)),
                  if (_scanner != null)
                    ValueListenableBuilder<List<NearbyHost>>(
                      valueListenable: _scanner!.hosts,
                      builder: (context, hosts, _) => Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final h in hosts)
                            ListTile(
                              dense: true,
                              leading: Icon(
                                Icons.bluetooth_audio,
                                color: theme.colorScheme.primary,
                              ),
                              title: Text(h.name),
                              subtitle: const Text('Nearby via Bluetooth'),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => _connectBle(h),
                            ),
                          if (hosts.isEmpty)
                            // never leave the Bluetooth path invisible:
                            // say we're looking, or why we can't
                            ValueListenableBuilder<String>(
                              valueListenable: _scanner!.status,
                              builder: (context, status, _) {
                                if (status == 'unsupported') {
                                  return const SizedBox.shrink();
                                }
                                final scanning = status == 'scanning';
                                return ListTile(
                                  dense: true,
                                  leading: scanning
                                      ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : Icon(
                                          Icons.bluetooth_disabled,
                                          color: theme.colorScheme.outline,
                                        ),
                                  title: Text(
                                    scanning
                                        ? 'Looking for nearby hosts '
                                              'via Bluetooth…'
                                        : 'Bluetooth is off or not allowed '
                                              '— tap to fix',
                                    style: theme.textTheme.bodySmall,
                                  ),
                                  onTap: scanning
                                      ? null
                                      : _scanner!.openSettings,
                                );
                              },
                            ),
                        ],
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _address,
                            keyboardType: TextInputType.url,
                            autocorrect: false,
                            decoration: const InputDecoration(
                              labelText: 'Or type the address',
                              hintText: '172.20.10.1:52000',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () {
                            final a = _address.text.trim();
                            if (a.contains(':')) _connect(a);
                          },
                          child: const Text('Join'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
