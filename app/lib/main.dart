import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'updater.dart';

const kServerUrl =
    String.fromEnvironment('SERVER_URL', defaultValue: 'wss://apps.eyenithing.site');
const _turnUrl = String.fromEnvironment('TURN_URL');
const _turnUser = String.fromEnvironment('TURN_USER');
const _turnCred = String.fromEnvironment('TURN_CRED');
// Set false (--dart-define=DIAG=false) to hide the grey diagnostics line.
const kDiag = bool.fromEnvironment('DIAG', defaultValue: true);
const kRingTimeout = Duration(seconds: 45);
// How long a connected call may stay in "Reconnecting…" before it fails.
const kReconnectTimeout = Duration(seconds: 60);

final navigatorKey = GlobalKey<NavigatorState>();
final emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

enum CallState { idle, calling, ringing, incoming, connected, ended }

class CallController extends ChangeNotifier {
  // connection
  WebSocketChannel? _ws;
  Timer? _ping;
  bool registered = false;
  bool connecting = false;
  String? myId;
  String? error;
  bool _wantConnected = false;
  bool _everRegistered = false;
  int _retry = 0;
  Timer? _retryTimer;
  DateTime _lastRx = DateTime.now();
  bool get signalLost => _everRegistered && _wantConnected && !registered;

  // call
  CallState state = CallState.idle;
  String? peerId;
  String statusText = '';
  bool muted = false;
  Duration duration = Duration.zero;
  bool _callPageOpen = false;
  bool isCaller = false;
  bool speakerOn = true;
  String? toneError;
  String _pcState = '-';
  String _iceState = '-';
  int _restarts = 0;
  String get debugLine =>
      'sig:${registered ? "up" : "down"} pc:$_pcState ice:$_iceState restarts:$_restarts';
  bool reconnecting = false; // media path lost, trying to recover
  bool poorConnection = false; // media flowing but quality is bad
  Timer? _reconDeadline;
  Timer? _restartTimer;
  Timer? _statsTimer;
  int _badStreak = 0;
  int _goodStreak = 0;
  num _lastRecv = 0;
  num _lastLost = 0;

  String get displayStatus => state == CallState.connected
      ? (reconnecting ? 'Reconnecting…' : (poorConnection ? 'Poor connection' : 'Connected'))
      : statusText;

  // one-shot message for the home page (dialog if alert, snackbar otherwise)
  String? notice;
  bool noticeIsAlert = false;

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  Map<String, dynamic>? _pendingOffer;
  final List<RTCIceCandidate> _earlyIce = [];
  Timer? _ringTimeout;
  Timer? _ticker;
  static const _tones = MethodChannel('poc_call/tones');
  static const _bg = MethodChannel('poc_call/background');

  // Background support (foreground service + notifications)
  bool foreground = true; // app visible? set from lifecycle observer
  bool askBackgroundSetup = false;
  bool _serviceStarted = false;

  Future<T?> bgInvoke<T>(String method, [Map<String, dynamic>? args]) async {
    try {
      return await _bg.invokeMethod<T>(method, args);
    } catch (_) {
      return null;
    }
  }

  String get _idleServiceText => registered ? 'Connected · ready for calls' : 'Reconnecting…';

  Future<void> _serviceIdle() async {
    if (!_serviceStarted) return;
    await bgInvoke('startService', {'text': _idleServiceText, 'inCall': false});
  }

  Future<void> _checkBackgroundSetup() async {
    final done = await bgInvoke<bool>('getFlag', {'key': 'bg_onboarded'});
    if (done != true) {
      askBackgroundSetup = true;
      notifyListeners();
    }
  }

  Future<void> markBackgroundOnboarded() => bgInvoke('setFlag', {'key': 'bg_onboarded', 'value': true});

  static final Map<String, dynamic> _iceConfig = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      if (_turnUrl.isNotEmpty)
        {'urls': _turnUrl.split(','), 'username': _turnUser, 'credential': _turnCred},
    ],
  };

  // ---------- connection ----------
  void connect(String email) {
    myId = email.trim().toLowerCase();
    _wantConnected = true;
    _everRegistered = false;
    _retry = 0;
    error = null;
    _open();
  }

  void _open() {
    _retryTimer?.cancel();
    connecting = true;
    notifyListeners();
    _ws?.sink.close();
    final ch = WebSocketChannel.connect(Uri.parse(kServerUrl));
    _ws = ch;
    _lastRx = DateTime.now();
    ch.ready.then((_) {
      if (_ws == ch) _send({'type': 'register', 'id': myId});
    }).catchError((_) => _onSocketLost(ch));
    ch.stream.listen(_onMessage,
        onError: (_) => _onSocketLost(ch), onDone: () => _onSocketLost(ch));
  }

  // Signaling socket dropped: keep any connected call alive (audio is peer-to-peer)
  // and reconnect in the background with backoff.
  void _onSocketLost(WebSocketChannel ch) {
    if (_ws != ch) return;
    _ws = null;
    _ping?.cancel();
    registered = false;
    connecting = false;
    if (_serviceStarted) bgInvoke('updateText', {'text': 'Reconnecting…'});
    if (state == CallState.calling || state == CallState.ringing || state == CallState.incoming) {
      _finish('Call failed: lost connection to the server', alert: true);
    }
    if (!_wantConnected) {
      notifyListeners();
      return;
    }
    if (!_everRegistered) {
      _wantConnected = false;
      error = 'Cannot reach the server. Check your internet and try again.';
      notifyListeners();
      return;
    }
    _retry++;
    final delay = state == CallState.connected
        ? const Duration(seconds: 1) // in a call: retry fast, signaling is needed to recover
        : Duration(seconds: _retry < 5 ? 1 << (_retry - 1) : 10); // 1,2,4,8,10…
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      if (_wantConnected && _ws == null) _open();
    });
    notifyListeners();
  }

  void disconnect() {
    _wantConnected = false;
    _everRegistered = false;
    _retryTimer?.cancel();
    _ping?.cancel();
    final ch = _ws;
    _ws = null;
    ch?.sink.close();
    registered = false;
    connecting = false;
    error = null;
    _serviceStarted = false;
    bgInvoke('stopService');
    notifyListeners();
  }

  void _send(Map<String, dynamic> m) => _ws?.sink.add(jsonEncode(m));

  Future<void> _onMessage(dynamic raw) async {
    _lastRx = DateTime.now();
    final m = jsonDecode(raw as String) as Map<String, dynamic>;
    final from = m['from'] as String?;
    switch (m['type']) {
      case 'registered':
        registered = true;
        connecting = false;
        error = null;
        _everRegistered = true;
        _retry = 0;
        if (!_serviceStarted) {
          _serviceStarted = true;
          bgInvoke('startService', {'text': 'Connected · ready for calls', 'inCall': false});
          _checkBackgroundSetup();
        } else {
          bgInvoke('updateText', {
            'text': state == CallState.connected ? 'In call with $peerId' : 'Connected · ready for calls'
          });
        }
        _ping?.cancel();
        _ping = Timer.periodic(const Duration(seconds: 4), (_) {
          final ch = _ws;
          if (ch == null) return;
          if (DateTime.now().difference(_lastRx) > const Duration(seconds: 10)) {
            ch.sink.close(); // server silent: treat as dead and reconnect
            _onSocketLost(ch);
            return;
          }
          _send({'type': 'ping'});
        });
        if (reconnecting) _tryRestartIce(); // signaling is back: renegotiate media now
        notifyListeners();
        break;
      case 'pong':
        break;
      case 'unavailable':
        if (state == CallState.calling || state == CallState.ringing) {
          _finish('$peerId is offline', alert: true);
        }
        break;
      case 'offer':
        if (state != CallState.idle) {
          _send({'type': 'busy', 'to': from});
          return;
        }
        _pendingOffer = m;
        isCaller = false;
        speakerOn = true;
        peerId = from;
        state = CallState.incoming;
        statusText = 'Incoming call';
        muted = false;
        duration = Duration.zero;
        _send({'type': 'ringing', 'to': from});
        _playTone('ring');
        if (!foreground) bgInvoke('showIncoming', {'caller': from});
        _openCallPage();
        notifyListeners();
        break;
      case 'ringing':
        if (state == CallState.calling && from == peerId) {
          state = CallState.ringing;
          statusText = 'Ringing…';
          _playTone('ringback');
          notifyListeners();
        }
        break;
      case 'answer':
        if (from != peerId || _pc == null) return;
        _ringTimeout?.cancel();
        await _stopTone();
        await _pc!.setRemoteDescription(RTCSessionDescription(m['sdp'], 'answer'));
        await _flushIce();
        _onConnected();
        break;
      case 'ice':
        if (from != peerId) return;
        final c = RTCIceCandidate(m['candidate'], m['sdpMid'], m['sdpMLineIndex']);
        if (_pc != null && await _pc!.getRemoteDescription() != null) {
          await _pc!.addCandidate(c);
        } else {
          _earlyIce.add(c);
        }
        break;
      case 'reoffer':
        if (from != peerId || _pc == null) return;
        try {
          await _pc!.setRemoteDescription(RTCSessionDescription(m['sdp'], 'offer'));
          final a = await _pc!.createAnswer();
          await _pc!.setLocalDescription(a);
          _send({'type': 'reanswer', 'to': peerId, 'sdp': a.sdp});
        } catch (_) {}
        break;
      case 'reanswer':
        if (from != peerId || _pc == null) return;
        try {
          if (_pc!.signalingState == RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
            await _pc!.setRemoteDescription(RTCSessionDescription(m['sdp'], 'answer'));
          }
        } catch (_) {}
        break;
      case 'reject':
        if (from == peerId) _finish('$peerId declined the call', alert: true);
        break;
      case 'busy':
        if (from == peerId) _finish('$peerId is busy on another call', alert: true);
        break;
      case 'hangup':
        if (from != peerId) return;
        if (state == CallState.incoming) {
          _finish('Missed call from $peerId', alert: true);
        } else {
          _finish('Call ended');
        }
        break;
    }
  }

  Future<void> _flushIce() async {
    for (final c in _earlyIce) {
      await _pc?.addCandidate(c);
    }
    _earlyIce.clear();
  }

  // ---------- call actions ----------
  Future<void> call(String email) async {
    final to = email.trim().toLowerCase();
    if (!registered || state != CallState.idle || to.isEmpty) return;
    peerId = to;
    isCaller = true;
    speakerOn = true;
    state = CallState.calling;
    statusText = 'Calling…';
    muted = false;
    duration = Duration.zero;
    _openCallPage();
    notifyListeners();
    try {
      await _createPeer(to);
      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
      _send({'type': 'offer', 'to': to, 'sdp': offer.sdp});
      _ringTimeout = Timer(kRingTimeout, () {
        if (state == CallState.calling || state == CallState.ringing) {
          _send({'type': 'hangup', 'to': peerId});
          _finish('No answer from $peerId', alert: true);
        }
      });
    } catch (e) {
      _finish('Could not start call: $e', alert: true);
    }
  }

  Future<void> accept() async {
    if (state != CallState.incoming) return;
    final offer = _pendingOffer!;
    bgInvoke('cancelIncoming');
    await _stopTone();
    try {
      await _createPeer(peerId!);
      await _pc!.setRemoteDescription(RTCSessionDescription(offer['sdp'], 'offer'));
      await _flushIce();
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);
      _send({'type': 'answer', 'to': peerId, 'sdp': answer.sdp});
      _onConnected();
    } catch (e) {
      _send({'type': 'hangup', 'to': peerId});
      _finish('Could not answer: $e', alert: true);
    }
  }

  void decline() {
    if (state != CallState.incoming) return;
    bgInvoke('cancelIncoming');
    _send({'type': 'reject', 'to': peerId});
    _finish('Call declined');
  }

  void hangup() {
    if (state == CallState.idle || state == CallState.ended) return;
    _send({'type': 'hangup', 'to': peerId});
    _finish('Call ended');
  }

  Future<void> toggleSpeaker() async {
    speakerOn = !speakerOn;
    try {
      await Helper.setSpeakerphoneOn(speakerOn);
    } catch (_) {}
    notifyListeners();
  }

  void toggleMute() {
    muted = !muted;
    for (final t in _localStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = !muted;
    }
    notifyListeners();
  }

  void _onConnected() {
    bgInvoke('cancelIncoming');
    if (_serviceStarted) bgInvoke('startService', {'text': 'In call with $peerId', 'inCall': true});
    state = CallState.connected;
    statusText = 'Connected';
    reconnecting = false;
    poorConnection = false;
    _startStats();
    duration = Duration.zero;
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      duration += const Duration(seconds: 1);
      notifyListeners();
    });
    notifyListeners();
  }

  // ---------- WebRTC ----------
  Future<void> _createPeer(String remoteId) async {
    _localStream = await navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});
    _pc = await createPeerConnection(_iceConfig);
    for (final t in _localStream!.getAudioTracks()) {
      await _pc!.addTrack(t, _localStream!);
    }
    _pc!.onIceCandidate = (c) {
      if (c.candidate == null) return;
      _send({
        'type': 'ice',
        'to': remoteId,
        'candidate': c.candidate,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
      });
    };
    try {
      await Helper.setSpeakerphoneOn(speakerOn);
    } catch (_) {}
    final thisPc = _pc;
    _pc!.onConnectionState = (s) {
      if (_pc != thisPc) return;
      _pcState = s.name.replaceFirst('RTCPeerConnectionState', '');
      notifyListeners();
      if (state != CallState.connected) return;
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _recovered();
      } else if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          s == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _startReconnecting();
      }
    };
    // Also watch ICE state directly: some Android builds report it more reliably.
    _pc!.onIceConnectionState = (s) {
      if (_pc != thisPc) return;
      _iceState = s.name.replaceFirst('RTCIceConnectionState', '');
      notifyListeners();
      if (state != CallState.connected) return;
      if (s == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          s == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        _recovered();
      } else if (s == RTCIceConnectionState.RTCIceConnectionStateFailed ||
          s == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        _startReconnecting();
      }
    };
  }

  // ---------- resilience: reconnect + quality ----------
  void _startReconnecting() {
    if (reconnecting || state != CallState.connected) return;
    reconnecting = true;
    poorConnection = false;
    _reconDeadline?.cancel();
    _reconDeadline = Timer(kReconnectTimeout, () {
      if (!reconnecting) return;
      _send({'type': 'hangup', 'to': peerId});
      _finish('Call failed: connection lost', alert: true);
    });
    _restartTimer?.cancel();
    _restartTimer = Timer.periodic(const Duration(seconds: 3), (_) => _tryRestartIce());
    final ch = _ws;
    if (ch != null && DateTime.now().difference(_lastRx) > const Duration(seconds: 3)) {
      ch.sink.close(); // same outage probably killed signaling too: reconnect it now
      _onSocketLost(ch);
    }
    _tryRestartIce();
    notifyListeners();
  }

  void _recovered() {
    if (!reconnecting) return;
    reconnecting = false;
    _badStreak = 0;
    _goodStreak = 0;
    _reconDeadline?.cancel();
    _restartTimer?.cancel();
    notifyListeners();
  }

  // Only the caller renegotiates (ICE restart), which avoids offer collisions.
  Future<void> _tryRestartIce() async {
    final pc = _pc;
    if (!isCaller || pc == null || !registered || state != CallState.connected) return;
    try {
      if (pc.signalingState == RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
        final ld = await pc.getLocalDescription(); // previous reoffer unanswered: resend it
        if (ld != null) _send({'type': 'reoffer', 'to': peerId, 'sdp': ld.sdp});
        return;
      }
      try {
        await pc.restartIce();
      } catch (_) {}
      // IceRestart constraint is a fallback in case restartIce() is unavailable.
      final offer = await pc.createOffer({
        'mandatory': {'IceRestart': true},
      });
      await pc.setLocalDescription(offer);
      _restarts++;
      _send({'type': 'reoffer', 'to': peerId, 'sdp': offer.sdp});
      notifyListeners();
    } catch (_) {}
  }

  void _startStats() {
    _statsTimer?.cancel();
    _badStreak = 0;
    _goodStreak = 0;
    _lastRecv = 0;
    _lastLost = 0;
    _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) => _sampleStats());
  }

  Future<void> _sampleStats() async {
    final pc = _pc;
    if (pc == null || state != CallState.connected || reconnecting) return;
    try {
      final reports = await pc.getStats();
      num recv = 0, lost = 0, rtt = 0, jitter = 0;
      var hasInbound = false;
      for (final r in reports) {
        final v = r.values;
        if (r.type == 'inbound-rtp' && ('${v['kind']}' == 'audio' || '${v['mediaType']}' == 'audio')) {
          hasInbound = true;
          recv = num.tryParse('${v['packetsReceived']}') ?? 0;
          lost = num.tryParse('${v['packetsLost']}') ?? 0;
          jitter = num.tryParse('${v['jitter']}') ?? 0;
        } else if (r.type == 'candidate-pair' &&
            ('${v['nominated']}' == 'true' || '${v['state']}' == 'succeeded')) {
          final t = num.tryParse('${v['currentRoundTripTime']}');
          if (t != null) rtt = t;
        }
      }
      if (!hasInbound) return;
      final dRecv = recv - _lastRecv;
      final dLost = (lost - _lastLost) > 0 ? (lost - _lastLost) : 0;
      _lastRecv = recv;
      _lastLost = lost;
      final total = dRecv + dLost;
      final loss = total > 0 ? dLost / total : 0;
      final bad = dRecv <= 0 || loss > 0.08 || rtt > 0.4 || jitter > 0.1;
      if (bad) {
        _badStreak++;
        _goodStreak = 0;
      } else {
        _goodStreak++;
        _badStreak = 0;
      }
      if (!poorConnection && _badStreak >= 2) {
        poorConnection = true;
        notifyListeners();
      } else if (poorConnection && _goodStreak >= 2) {
        poorConnection = false;
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> _teardown() async {
    final pc = _pc;
    final stream = _localStream;
    _pc = null;
    _localStream = null;
    _pendingOffer = null;
    _earlyIce.clear();
    try {
      await pc?.close();
      for (final t in stream?.getTracks() ?? <MediaStreamTrack>[]) {
        await t.stop();
      }
      await stream?.dispose();
    } catch (_) {}
  }

  // ---------- tones ----------
  // Native tones (see native/MainActivity.kt): system ringback / default ringtone.
  Future<void> _playTone(String kind) async {
    try {
      toneError = null;
      await _tones.invokeMethod(kind == 'ring' ? 'startRing' : 'startRingback');
    } catch (e) {
      toneError = 'Tone error: $e';
      notifyListeners();
    }
  }

  Future<void> _stopTone() async {
    try {
      await _tones.invokeMethod('stop');
    } catch (_) {}
  }

  // ---------- finishing ----------
  Future<void> _finish(String reason, {bool alert = false}) async {
    if (state == CallState.idle || state == CallState.ended) return;
    final wasConnected = state == CallState.connected;
    final d = duration;
    state = CallState.ended; // set first so repeated events are ignored
    _ringTimeout?.cancel();
    _ticker?.cancel();
    _reconDeadline?.cancel();
    _restartTimer?.cancel();
    _statsTimer?.cancel();
    reconnecting = false;
    poorConnection = false;
    statusText = wasConnected ? '$reason · ${formatDuration(d)}' : reason;
    notifyListeners();
    await _stopTone();
    bgInvoke('cancelIncoming');
    await _teardown();
    _serviceIdle();
    await Future.delayed(const Duration(milliseconds: 1500));
    state = CallState.idle;
    peerId = null;
    muted = false;
    if (_callPageOpen) {
      navigatorKey.currentState?.popUntil((r) => r.isFirst);
      _callPageOpen = false;
    }
    notice = wasConnected ? 'Call ended · ${formatDuration(d)}' : reason;
    noticeIsAlert = alert;
    notifyListeners();
  }

  void _openCallPage() {
    if (_callPageOpen) return;
    _callPageOpen = true;
    navigatorKey.currentState?.push(MaterialPageRoute(builder: (_) => const CallPage()));
  }

  void clearNotice() => notice = null;
}

String formatDuration(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final h = d.inHours;
  final m = two(d.inMinutes.remainder(60));
  final s = two(d.inSeconds.remainder(60));
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

final ctrl = CallController();

class _Lifecycle with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    ctrl.foreground = s == AppLifecycleState.resumed;
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  WidgetsBinding.instance.addObserver(_Lifecycle());
  runApp(MaterialApp(
    navigatorKey: navigatorKey,
    title: 'In-App Call',
    theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
    home: const HomePage(),
  ));
}

// ======================= Page 1: login + dial =======================
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _email = TextEditingController();
  final _peer = TextEditingController();

  @override
  void initState() {
    super.initState();
    ctrl.addListener(_onCtrl);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkUpdate(silent: true));
  }

  bool _updating = false;

  Future<void> _checkUpdate({bool silent = false}) async {
    if (_updating) return;
    final u = await checkForUpdate();
    if (!mounted) return;
    if (u == null) {
      if (!silent) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('You have the latest version (v$kAppVersion).')));
      }
      return;
    }
    if (ctrl.state != CallState.idle) return; // never interrupt a call
    final go = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        icon: const Icon(Icons.system_update),
        title: const Text('Update available'),
        content: Text('Version ${u.version} is available (you have v$kAppVersion).'
            '${u.notes.isNotEmpty ? '\n\n${u.notes}' : ''}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Later')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Update')),
        ],
      ),
    );
    if (go == true && mounted) await _runUpdate(u);
  }

  Future<void> _runUpdate(UpdateInfo u) async {
    _updating = true;
    final progress = ValueNotifier<double>(0);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('Downloading update…'),
          content: ValueListenableBuilder<double>(
            valueListenable: progress,
            builder: (_, v, __) => Column(mainAxisSize: MainAxisSize.min, children: [
              LinearProgressIndicator(value: v > 0 ? v : null),
              const SizedBox(height: 12),
              Text('${(v * 100).toStringAsFixed(0)}%'),
            ]),
          ),
        ),
      ),
    );
    String? msg;
    try {
      final path = await downloadApk(u, (v) => progress.value = v);
      if (mounted) Navigator.of(context, rootNavigator: true).pop(); // close progress dialog
      final r = await installApk(path);
      if (r == 'needs_permission') {
        msg = 'Allow "Install unknown apps" for this app in the settings that just opened, '
            'then come back and tap Check for updates again.';
      }
    } catch (e) {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      msg = 'Update failed: $e';
    } finally {
      _updating = false;
    }
    if (msg != null && mounted) {
      showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Update'),
          content: Text(msg!),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
        ),
      );
    }
  }

  @override
  void dispose() {
    ctrl.removeListener(_onCtrl);
    super.dispose();
  }

  void _onCtrl() {
    if (ctrl.askBackgroundSetup && mounted) {
      ctrl.askBackgroundSetup = false;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        await showDialog<void>(context: context, builder: (_) => const BackgroundSetupDialog());
        await ctrl.markBackgroundOnboarded();
      });
    }
    final msg = ctrl.notice;
    if (msg == null || !mounted) return;
    final alert = ctrl.noticeIsAlert;
    ctrl.clearNotice();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (alert) {
        showDialog<void>(
          context: context,
          builder: (_) => AlertDialog(
            icon: const Icon(Icons.phone_missed),
            title: const Text('Call'),
            content: Text(msg),
            actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        final myOk = emailRe.hasMatch(_email.text.trim());
        return Scaffold(
          appBar: AppBar(title: const Text('In-App Call')),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: ListView(children: [
                if (!ctrl.registered && !ctrl.signalLost) ...[
                  const SizedBox(height: 24),
                  const Icon(Icons.call, size: 64, color: Colors.teal),
                  const SizedBox(height: 16),
                  Text('Sign in with your email',
                      textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    enabled: !ctrl.connecting,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Your email',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.email_outlined),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: (myOk && !ctrl.connecting) ? () => ctrl.connect(_email.text) : null,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(ctrl.connecting ? 'Connecting…' : 'Connect'),
                    ),
                  ),
                  if (ctrl.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(ctrl.error!,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ),
                ] else ...[
                  Card(
                    child: ListTile(
                      leading: Icon(Icons.circle,
                          color: ctrl.registered ? Colors.green : Colors.amber, size: 14),
                      title: Text(ctrl.registered ? 'Connected' : 'Reconnecting…'),
                      subtitle: Text(ctrl.myId ?? ''),
                      trailing: TextButton(onPressed: ctrl.disconnect, child: const Text('Disconnect')),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text('Who do you want to call?', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _peer,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: "Their email",
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _canCall() ? () => ctrl.call(_peer.text) : null,
                    icon: const Icon(Icons.call),
                    label: const Padding(padding: EdgeInsets.all(12), child: Text('Call')),
                  ),
                  if (_peer.text.trim().toLowerCase() == ctrl.myId)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text("You can't call yourself.", textAlign: TextAlign.center),
                    ),
                ],
                const SizedBox(height: 32),
                Center(
                  child: TextButton.icon(
                    onPressed: () => _checkUpdate(),
                    icon: const Icon(Icons.system_update_alt, size: 18),
                    label: const Text('Check for updates'),
                  ),
                ),
                if (ctrl.registered)
                  Center(
                    child: TextButton.icon(
                      onPressed: () => showDialog<void>(
                          context: context, builder: (_) => const BackgroundSetupDialog()),
                      icon: const Icon(Icons.notifications_active_outlined, size: 18),
                      label: const Text('Background & notification settings'),
                    ),
                  ),
                Center(child: Text('v$kAppVersion', style: const TextStyle(color: Colors.grey))),
              ]),
            ),
          ),
        );
      },
    );
  }

  bool _canCall() {
    final p = _peer.text.trim().toLowerCase();
    return ctrl.registered && emailRe.hasMatch(p) && p != ctrl.myId && ctrl.state == CallState.idle;
  }
}

// ======================= Page 2: calling screen =======================
class CallPage extends StatelessWidget {
  const CallPage({super.key});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: ListenableBuilder(
        listenable: ctrl,
        builder: (context, _) {
          final s = ctrl.state;
          final connected = s == CallState.connected;
          return Scaffold(
            backgroundColor: const Color(0xFF12201F),
            body: SafeArea(
              child: Column(children: [
                const Spacer(flex: 2),
                const CircleAvatar(
                  radius: 52,
                  backgroundColor: Colors.teal,
                  child: Icon(Icons.person, size: 64, color: Colors.white),
                ),
                const SizedBox(height: 24),
                Text(ctrl.peerId ?? '',
                    style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  if (connected && (ctrl.reconnecting || ctrl.poorConnection)) ...[
                    Icon(ctrl.reconnecting ? Icons.wifi_off : Icons.network_check,
                        color: Colors.amber, size: 20),
                    const SizedBox(width: 8),
                  ],
                  Text(ctrl.displayStatus,
                      style: TextStyle(
                          color: (connected && (ctrl.reconnecting || ctrl.poorConnection))
                              ? Colors.amber
                              : Colors.white70,
                          fontSize: 16)),
                ]),
                const SizedBox(height: 8),
                Text(
                  connected ? formatDuration(ctrl.duration) : '',
                  style: const TextStyle(
                      color: Colors.white, fontSize: 40, fontWeight: FontWeight.w300),
                ),
                const Spacer(flex: 3),
                if (kDiag)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Text(
                    '${ctrl.debugLine}${ctrl.toneError != null ? '\n${ctrl.toneError}' : ''}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 48),
                  child: s == CallState.incoming
                      ? Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                          _RoundButton(
                              icon: Icons.call_end, label: 'Decline', color: Colors.red, onTap: ctrl.decline),
                          _RoundButton(
                              icon: Icons.call, label: 'Accept', color: Colors.green, onTap: ctrl.accept),
                        ])
                      : Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                          _RoundButton(
                            icon: ctrl.muted ? Icons.mic_off : Icons.mic,
                            label: ctrl.muted ? 'Unmute' : 'Mute',
                            color: ctrl.muted ? Colors.white : Colors.white24,
                            iconColor: ctrl.muted ? Colors.black : Colors.white,
                            onTap: connected ? ctrl.toggleMute : null,
                          ),
                          _RoundButton(
                            icon: ctrl.speakerOn ? Icons.volume_up : Icons.hearing,
                            label: ctrl.speakerOn ? 'Speaker' : 'Earpiece',
                            color: ctrl.speakerOn ? Colors.white : Colors.white24,
                            iconColor: ctrl.speakerOn ? Colors.black : Colors.white,
                            onTap: s == CallState.ended ? null : ctrl.toggleSpeaker,
                          ),
                          _RoundButton(
                            icon: Icons.call_end,
                            label: 'Hang up',
                            color: Colors.red,
                            onTap: s == CallState.ended ? null : ctrl.hangup,
                          ),
                        ]),
                ),
              ]),
            ),
          );
        },
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final Color iconColor;
  final VoidCallback? onTap;
  const _RoundButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.iconColor = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Opacity(
        opacity: onTap == null ? 0.4 : 1,
        child: Material(
          color: color,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Padding(padding: const EdgeInsets.all(20), child: Icon(icon, color: iconColor, size: 32)),
          ),
        ),
      ),
      const SizedBox(height: 8),
      Text(label, style: const TextStyle(color: Colors.white70)),
    ]);
  }
}


// ======================= Background setup dialog =======================
class BackgroundSetupDialog extends StatefulWidget {
  const BackgroundSetupDialog({super.key});
  @override
  State<BackgroundSetupDialog> createState() => _BackgroundSetupDialogState();
}

class _BackgroundSetupDialogState extends State<BackgroundSetupDialog> with WidgetsBindingObserver {
  Map<dynamic, dynamic> _st = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _refresh(); // came back from a settings screen
  }

  Future<void> _refresh() async {
    final st = await ctrl.bgInvoke<Map<dynamic, dynamic>>('status');
    if (mounted && st != null) setState(() => _st = st);
  }

  Widget _row(String title, String why, bool? ok, Future<void> Function() action) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(ok == true ? Icons.check_circle : Icons.radio_button_unchecked,
          color: ok == true ? Colors.green : Colors.grey),
      title: Text(title),
      subtitle: Text(why),
      onTap: ok == true ? null : () async { await action(); await _refresh(); },
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Receive calls in background'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('To ring when the app is closed or the screen is off, allow these:'),
          const SizedBox(height: 8),
          _row('Notifications', 'Shows "connected" and incoming calls', _st['notifications'] as bool?, () async {
            final granted = await ctrl.bgInvoke<bool>('requestNotifPermission');
            if (granted != true) await ctrl.bgInvoke('openNotificationSettings');
          }),
          _row('Unrestricted battery', 'Stops Android from pausing the app', _st['battery'] as bool?,
              () => ctrl.bgInvoke('openBatterySettings')),
          _row('Calls on lock screen', 'Wakes the screen for incoming calls (Android 14+)',
              _st['fullScreen'] as bool?, () => ctrl.bgInvoke('openFullScreenSettings')),
          const SizedBox(height: 8),
          const Text("Note: don't swipe the app away from recent apps; that closes the connection.",
              style: TextStyle(fontSize: 12, color: Colors.grey)),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
    );
  }
}
