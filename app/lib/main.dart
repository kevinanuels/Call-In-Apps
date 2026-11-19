import 'dart:async';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const kServerUrl =
    String.fromEnvironment('SERVER_URL', defaultValue: 'ws://139.190.99.158:8080');
const _turnUrl = String.fromEnvironment('TURN_URL');
const _turnUser = String.fromEnvironment('TURN_USER');
const _turnCred = String.fromEnvironment('TURN_CRED');
const kRingTimeout = Duration(seconds: 45);

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

  // call
  CallState state = CallState.idle;
  String? peerId;
  String statusText = '';
  bool muted = false;
  Duration duration = Duration.zero;
  bool _callPageOpen = false;

  // one-shot message for the home page (dialog if alert, snackbar otherwise)
  String? notice;
  bool noticeIsAlert = false;

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  Map<String, dynamic>? _pendingOffer;
  final List<RTCIceCandidate> _earlyIce = [];
  Timer? _ringTimeout;
  Timer? _ticker;
  final AudioPlayer _tone = AudioPlayer();

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
    connecting = true;
    error = null;
    notifyListeners();
    _ws?.sink.close();
    final ch = WebSocketChannel.connect(Uri.parse(kServerUrl));
    _ws = ch;
    ch.ready.then((_) {
      if (_ws == ch) _send({'type': 'register', 'id': myId});
    }).catchError((e) {
      if (_ws == ch) {
        connecting = false;
        registered = false;
        error = 'Cannot reach the server. Check your internet and try again.';
        notifyListeners();
      }
    });
    ch.stream.listen(_onMessage, onError: (_) {}, onDone: () {
      if (_ws != ch) return;
      _ping?.cancel();
      registered = false;
      connecting = false;
      if (error == null) error = 'Disconnected from server.';
      if (state != CallState.idle) _finish('Connection lost', alert: true);
      notifyListeners();
    });
  }

  void disconnect() {
    _ping?.cancel();
    final ch = _ws;
    _ws = null;
    ch?.sink.close();
    registered = false;
    connecting = false;
    error = null;
    notifyListeners();
  }

  void _send(Map<String, dynamic> m) => _ws?.sink.add(jsonEncode(m));

  Future<void> _onMessage(dynamic raw) async {
    final m = jsonDecode(raw as String) as Map<String, dynamic>;
    final from = m['from'] as String?;
    switch (m['type']) {
      case 'registered':
        registered = true;
        connecting = false;
        error = null;
        _ping?.cancel();
        _ping = Timer.periodic(const Duration(seconds: 25), (_) => _send({'type': 'ping'}));
        notifyListeners();
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
        peerId = from;
        state = CallState.incoming;
        statusText = 'Incoming call';
        muted = false;
        duration = Duration.zero;
        _send({'type': 'ringing', 'to': from});
        _playTone('ring.wav');
        _openCallPage();
        notifyListeners();
        break;
      case 'ringing':
        if (state == CallState.calling && from == peerId) {
          state = CallState.ringing;
          statusText = 'Ringing…';
          _playTone('ringback.wav');
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
    _send({'type': 'reject', 'to': peerId});
    _finish('Call declined');
  }

  void hangup() {
    if (state == CallState.idle || state == CallState.ended) return;
    _send({'type': 'hangup', 'to': peerId});
    _finish('Call ended');
  }

  void toggleMute() {
    muted = !muted;
    for (final t in _localStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = !muted;
    }
    notifyListeners();
  }

  void _onConnected() {
    state = CallState.connected;
    statusText = 'Connected';
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
    _pc!.onConnectionState = (s) {
      if (state == CallState.connected &&
          (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
              s == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected)) {
        _finish('Connection lost', alert: true);
      }
    };
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
  Future<void> _playTone(String asset) async {
    try {
      await _tone.stop();
      await _tone.setReleaseMode(ReleaseMode.loop);
      await _tone.play(AssetSource(asset));
    } catch (_) {}
  }

  Future<void> _stopTone() async {
    try {
      await _tone.stop();
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
    statusText = wasConnected ? '$reason · ${formatDuration(d)}' : reason;
    notifyListeners();
    await _stopTone();
    await _teardown();
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

void main() => runApp(MaterialApp(
      navigatorKey: navigatorKey,
      title: 'In-App Call',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const HomePage(),
    ));

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
  }

  @override
  void dispose() {
    ctrl.removeListener(_onCtrl);
    super.dispose();
  }

  void _onCtrl() {
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
                if (!ctrl.registered) ...[
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
                      leading: const Icon(Icons.circle, color: Colors.green, size: 14),
                      title: const Text('Connected'),
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
              ]),
            ),
          ),
        );
      },
    );
  }

  bool _canCall() {
    final p = _peer.text.trim().toLowerCase();
    return emailRe.hasMatch(p) && p != ctrl.myId && ctrl.state == CallState.idle;
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
                Text(ctrl.statusText, style: const TextStyle(color: Colors.white70, fontSize: 16)),
                const SizedBox(height: 8),
                Text(
                  connected ? formatDuration(ctrl.duration) : '',
                  style: const TextStyle(
                      color: Colors.white, fontSize: 40, fontWeight: FontWeight.w300),
                ),
                const Spacer(flex: 3),
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
