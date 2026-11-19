import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() => runApp(const MaterialApp(home: CallPage()));

enum CallState { idle, calling, ringing, inCall }

class CallPage extends StatefulWidget {
  const CallPage({super.key});
  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> {
  final _server = TextEditingController(text: const String.fromEnvironment('SERVER_URL', defaultValue: 'ws://192.168.1.10:8080'));
  final _myId = TextEditingController();
  final _peerId = TextEditingController();

  WebSocketChannel? _ws;
  bool _registered = false;
  CallState _state = CallState.idle;
  String _status = 'Not connected';
  bool _muted = false;

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  String? _remoteId; // who we are talking to / being called by
  Map<String, dynamic>? _pendingOffer;
  final List<RTCIceCandidate> _earlyIce = [];

  // Optional TURN relay (set at build time) so calls work across mobile networks.
  static const _turnUrl = String.fromEnvironment('TURN_URL');
  static const _turnUser = String.fromEnvironment('TURN_USER');
  static const _turnCred = String.fromEnvironment('TURN_CRED');
  static final Map<String, dynamic> _iceConfig = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      if (_turnUrl.isNotEmpty)
        {'urls': _turnUrl.split(','), 'username': _turnUser, 'credential': _turnCred},
    ],
  };

  // ---------- signaling ----------
  void _connect() {
    if (_myId.text.trim().isEmpty) return;
    _ws?.sink.close();
    final ws = WebSocketChannel.connect(Uri.parse(_server.text.trim()));
    _ws = ws;
    ws.sink.add(jsonEncode({'type': 'register', 'id': _myId.text.trim()}));
    ws.stream.listen(_onMessage, onError: (e) {
      setState(() { _registered = false; _status = 'Connection error: $e'; });
    }, onDone: () {
      if (mounted) setState(() { _registered = false; _status = 'Disconnected'; });
    });
  }

  void _send(Map<String, dynamic> m) => _ws?.sink.add(jsonEncode(m));

  Future<void> _onMessage(dynamic raw) async {
    final m = jsonDecode(raw as String) as Map<String, dynamic>;
    switch (m['type']) {
      case 'registered':
        setState(() { _registered = true; _status = 'Online as ${m['id']}'; });
        break;
      case 'unavailable':
        await _cleanup();
        setState(() => _status = '${m['from']} is not online');
        break;
      case 'offer': // incoming call
        if (_state != CallState.idle) {
          _send({'type': 'reject', 'to': m['from']});
          return;
        }
        _pendingOffer = m;
        _remoteId = m['from'];
        setState(() { _state = CallState.ringing; _status = 'Incoming call from ${m['from']}'; });
        break;
      case 'answer':
        await _pc?.setRemoteDescription(RTCSessionDescription(m['sdp'], 'answer'));
        await _flushIce();
        setState(() { _state = CallState.inCall; _status = 'In call with $_remoteId'; });
        break;
      case 'ice':
        final c = RTCIceCandidate(m['candidate'], m['sdpMid'], m['sdpMLineIndex']);
        if (_pc != null && await _pc!.getRemoteDescription() != null) {
          await _pc!.addCandidate(c);
        } else {
          _earlyIce.add(c);
        }
        break;
      case 'reject':
        await _cleanup();
        setState(() => _status = 'Call declined');
        break;
      case 'hangup':
        await _cleanup();
        setState(() => _status = 'Call ended by remote');
        break;
    }
  }

  Future<void> _flushIce() async {
    for (final c in _earlyIce) {
      await _pc?.addCandidate(c);
    }
    _earlyIce.clear();
  }

  // ---------- WebRTC ----------
  Future<void> _createPeer(String remoteId) async {
    if (!await Permission.microphone.request().isGranted) {
      throw Exception('Microphone permission denied');
    }
    _localStream = await navigator.mediaDevices
        .getUserMedia({'audio': true, 'video': false});
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
    // Remote audio plays automatically on Android once the track is received.
    _pc!.onConnectionState = (s) {
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          s == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _cleanup().then((_) => setState(() => _status = 'Connection lost'));
      }
    };
  }

  Future<void> _startCall() async {
    final to = _peerId.text.trim();
    if (to.isEmpty || !_registered) return;
    try {
      _remoteId = to;
      await _createPeer(to);
      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
      _send({'type': 'offer', 'to': to, 'sdp': offer.sdp});
      setState(() { _state = CallState.calling; _status = 'Calling $to...'; });
    } catch (e) {
      await _cleanup();
      setState(() => _status = 'Error: $e');
    }
  }

  Future<void> _accept() async {
    final offer = _pendingOffer!;
    try {
      await _createPeer(_remoteId!);
      await _pc!.setRemoteDescription(RTCSessionDescription(offer['sdp'], 'offer'));
      await _flushIce();
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);
      _send({'type': 'answer', 'to': _remoteId, 'sdp': answer.sdp});
      setState(() { _state = CallState.inCall; _status = 'In call with $_remoteId'; });
    } catch (e) {
      await _cleanup();
      setState(() => _status = 'Error: $e');
    }
  }

  void _decline() {
    _send({'type': 'reject', 'to': _remoteId});
    _cleanup().then((_) => setState(() => _status = 'Call declined'));
  }

  void _hangup() {
    _send({'type': 'hangup', 'to': _remoteId});
    _cleanup().then((_) => setState(() => _status = 'Call ended'));
  }

  void _toggleMute() {
    _muted = !_muted;
    for (final t in _localStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = !_muted;
    }
    setState(() {});
  }

  Future<void> _cleanup() async {
    await _pc?.close();
    _pc = null;
    for (final t in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
      await t.stop();
    }
    await _localStream?.dispose();
    _localStream = null;
    _pendingOffer = null;
    _remoteId = null;
    _muted = false;
    _earlyIce.clear();
    if (mounted) setState(() => _state = CallState.idle);
  }

  @override
  void dispose() {
    _cleanup();
    _ws?.sink.close();
    super.dispose();
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('POC In-App Call')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(children: [
          TextField(
            controller: _server,
            decoration: const InputDecoration(labelText: 'Server'),
            enabled: !_registered,
          ),
          TextField(
            controller: _myId,
            decoration: const InputDecoration(labelText: 'Your name / ID (e.g. alice)'),
            enabled: !_registered,
          ),
          const SizedBox(height: 8),
          ElevatedButton(
            onPressed: _registered ? null : _connect,
            child: const Text('Connect'),
          ),
          const Divider(height: 32),
          Text(_status, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          if (_state == CallState.idle) ...[
            TextField(
              controller: _peerId,
              decoration: const InputDecoration(labelText: 'Call who? (their ID, e.g. bob)'),
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _registered ? _startCall : null,
              icon: const Icon(Icons.call),
              label: const Text('Call'),
            ),
          ],
          if (_state == CallState.ringing)
            Row(children: [
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                  onPressed: _accept,
                  icon: const Icon(Icons.call),
                  label: const Text('Accept'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                  onPressed: _decline,
                  icon: const Icon(Icons.call_end),
                  label: const Text('Decline'),
                ),
              ),
            ]),
          if (_state == CallState.calling || _state == CallState.inCall)
            Row(children: [
              if (_state == CallState.inCall)
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _toggleMute,
                    icon: Icon(_muted ? Icons.mic_off : Icons.mic),
                    label: Text(_muted ? 'Unmute' : 'Mute'),
                  ),
                ),
              if (_state == CallState.inCall) const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                  onPressed: _hangup,
                  icon: const Icon(Icons.call_end),
                  label: const Text('Hang up'),
                ),
              ),
            ]),
        ]),
      ),
    );
  }
}
