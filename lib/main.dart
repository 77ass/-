import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

void main() => runApp(const LanBridgeApp());

const _port = 8765;
const _discoveryPort = 37654;
const _service = 'lanbridge/1';

class LanBridgeApp extends StatelessWidget {
  const LanBridgeApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'LanBridge',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.light,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF087DFA)),
          scaffoldBackgroundColor: const Color(0xFFF5F5F7),
          cardTheme: CardThemeData(
            color: Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          ),
        ),
        darkTheme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0A84FF), brightness: Brightness.dark),
          cardTheme: CardThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
        ),
        home: const HomePage(),
      );
}

class Peer {
  Peer({required this.name, required this.host, required this.port, required this.id, required this.lastSeen});
  final String name;
  final InternetAddress host;
  final int port;
  final String id;
  DateTime lastSeen;
}

class TransferItem {
  TransferItem(this.name, this.size, this.direction, {this.progress = 0, this.status = '准备中'});
  final String name;
  final int size;
  final String direction;
  double progress;
  String status;
  String? detail;
}

class LanService {
  LanService({required this.deviceName, required this.onPeers, required this.onIncoming});
  final String deviceName;
  final void Function(List<Peer>) onPeers;
  final Future<bool> Function(String name, int size) onIncoming;
  final Map<String, Peer> _peers = {};
  RawDatagramSocket? _udp;
  HttpServer? _http;
  Timer? _announce;
  final String _id = '${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(1 << 20)}';

  Future<void> start() async {
    _http = await HttpServer.bind(InternetAddress.anyIPv4, _port, shared: true);
    _http!.listen(_handleRequest);
    _udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, _discoveryPort, reuseAddress: true, reusePort: false);
    _udp!.broadcastEnabled = true;
    _udp!.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = _udp!.receive();
      if (datagram == null) return;
      try {
        final data = jsonDecode(utf8.decode(datagram.data)) as Map<String, dynamic>;
        if (data['service'] != _service || data['id'] == _id) return;
        final id = data['id']?.toString();
        final name = data['name']?.toString();
        final port = data['port'];
        if (id == null || name == null || port is! int) return;
        _peers[id] = Peer(name: name, host: datagram.address, port: port, id: id, lastSeen: DateTime.now());
        _expirePeers();
        onPeers(_peers.values.toList()..sort((a, b) => a.name.compareTo(b.name)));
      } catch (_) {}
    });
    _announce = Timer.periodic(const Duration(seconds: 3), (_) => _broadcast());
    _broadcast();
  }

  void _broadcast() {
    final bytes = utf8.encode(jsonEncode({'service': _service, 'id': _id, 'name': deviceName, 'port': _port}));
    _udp?.send(bytes, InternetAddress('255.255.255.255'), _discoveryPort);
    _expirePeers();
    onPeers(_peers.values.toList()..sort((a, b) => a.name.compareTo(b.name)));
  }

  void _expirePeers() {
    _peers.removeWhere((_, peer) => DateTime.now().difference(peer.lastSeen) > const Duration(seconds: 12));
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (request.method != 'POST' || request.uri.path != '/upload') {
      request.response.statusCode = HttpStatus.notFound;
      request.response.write('LanBridge local transfer service');
      await request.response.close();
      return;
    }
    final name = request.uri.queryParameters['name'] ?? 'received_file';
    final size = int.tryParse(request.headers.value('content-length') ?? '') ?? 0;
    final accepted = await onIncoming(name, size);
    if (!accepted) {
      request.response.statusCode = HttpStatus.forbidden;
      request.response.write('Transfer declined');
      await request.response.close();
      return;
    }
    try {
      final directory = await getApplicationDocumentsDirectory();
      final safeName = _safeFileName(name);
      final target = File('${directory.path}${Platform.pathSeparator}$safeName');
      final out = target.openWrite();
      await request.cast<List<int>>().pipe(out);
      request.response.statusCode = HttpStatus.ok;
      request.response.write('OK');
      await request.response.close();
    } catch (e) {
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write('Save failed');
      await request.response.close();
    }
  }

  Future<void> sendFile(Peer peer, PlatformFile file, void Function(double) onProgress) async {
    if (file.path == null) throw Exception('当前平台未提供文件路径，请选择本地文件。');
    final source = File(file.path!);
    final request = await HttpClient().postUrl(Uri(
      scheme: 'http', host: peer.host.address, port: peer.port, path: '/upload',
      queryParameters: {'name': file.name},
    ));
    request.headers.contentType = ContentType.binary;
    request.contentLength = await source.length();
    var sent = 0;
    final total = await source.length();
    await for (final chunk in source.openRead()) {
      request.add(chunk);
      sent += chunk.length;
      onProgress(total == 0 ? 1 : sent / total);
    }
    final response = await request.close();
    final body = await utf8.decoder.bind(response).join();
    if (response.statusCode != HttpStatus.ok) throw Exception('对方拒绝或接收失败：$body');
  }

  Future<void> dispose() async {
    _announce?.cancel();
    _udp?.close();
    await _http?.close(force: true);
  }
}

String _safeFileName(String name) {
  final leaf = name.split(RegExp(r'[/\\]')).last.trim();
  final cleaned = leaf.replaceAll(RegExp(r'[<>:"|?*\x00-\x1F]'), '_');
  return cleaned.isEmpty ? 'received_file' : cleaned;
}

String _sizeLabel(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final List<Peer> _peers = [];
  final List<TransferItem> _history = [];
  LanService? _service;
  String _status = '正在启动局域网服务…';
  bool _running = false;
  bool _askBeforeReceive = true;

  @override
  void initState() {
    super.initState();
    _startService();
  }

  Future<void> _startService() async {
    try {
      final name = Platform.isWindows ? 'Windows 电脑' : Platform.isAndroid ? 'Android 设备' : Platform.isIOS ? 'iPhone' : 'LanBridge 设备';
      _service = LanService(deviceName: name, onPeers: (found) {
        if (mounted) setState(() { _peers..clear()..addAll(found); });
      }, onIncoming: _approveIncoming);
      await _service!.start();
      if (mounted) setState(() { _running = true; _status = '正在搜索同一 Wi-Fi 下的设备'; });
    } catch (e) {
      if (mounted) setState(() => _status = '启动失败：$e');
    }
  }

  Future<bool> _approveIncoming(String name, int size) async {
    if (!_askBeforeReceive || !mounted) return true;
    final result = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('接收文件？'),
      content: Text('对方想发送文件：\n$name\n${_sizeLabel(size)}\n\n第一版会保存到应用的文档目录。'),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('拒绝')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('接收')],
    ));
    return result ?? false;
  }

  Future<void> _pickAndSend() async {
    if (_peers.isEmpty) {
      _message('暂时没有发现设备。请确认两台设备连接同一 Wi-Fi，且网络没有开启 AP 隔离。');
      return;
    }
    final selected = await FilePicker.platform.pickFiles(allowMultiple: true, withData: false);
    if (selected == null || selected.files.isEmpty) return;
    if (!mounted) return;
    final peer = await showModalBottomSheet<Peer>(context: context, showDragHandle: true, builder: (context) => SafeArea(child: ListView(shrinkWrap: true, children: [const ListTile(title: Text('发送到哪台设备？')), ..._peers.map((p) => ListTile(leading: const Icon(CupertinoIcons.device_laptop), title: Text(p.name), subtitle: Text(p.host.address), onTap: () => Navigator.pop(context, p))]))));
    if (peer == null) return;
    for (final file in selected.files) {
      final item = TransferItem(file.name, file.size, '发送');
      setState(() => _history.insert(0, item));
      try {
        await _service!.sendFile(peer, file, (progress) { if (mounted) setState(() { item.progress = progress; item.status = '发送中 ${(progress * 100).toStringAsFixed(0)}%'; }); });
        if (mounted) setState(() { item.progress = 1; item.status = '已发送'; });
      } catch (e) {
        if (mounted) setState(() { item.status = '失败'; item.detail = e.toString(); });
      }
    }
  }

  void _message(String text) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text))); }

  @override
  void dispose() { _service?.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('LanBridge', style: TextStyle(fontWeight: FontWeight.w700)), centerTitle: false, actions: [IconButton(tooltip: '设置', onPressed: _settings, icon: const Icon(CupertinoIcons.gearshape))]),
      body: SafeArea(child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
        Card(child: Padding(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Container(width: 48, height: 48, decoration: BoxDecoration(color: colors.primaryContainer, borderRadius: BorderRadius.circular(15)), child: Icon(CupertinoIcons.arrow_left_arrow_right, color: colors.primary, size: 25)), const SizedBox(width: 14), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('局域网文件传输', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700)), const SizedBox(height: 4), Row(children: [Container(width: 7, height: 7, decoration: BoxDecoration(color: _running ? Colors.green : Colors.orange, shape: BoxShape.circle)), const SizedBox(width: 6), Expanded(child: Text(_status, style: Theme.of(context).textTheme.bodySmall))])]))]),
          const SizedBox(height: 20), SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: _pickAndSend, icon: const Icon(CupertinoIcons.paperplane_fill), label: const Padding(padding: EdgeInsets.symmetric(vertical: 13), child: Text('选择文件并发送')))),
          const SizedBox(height: 8), const Text('文件类型不限 · 同一 Wi-Fi · 设备间直接传输', style: TextStyle(fontSize: 12, color: Colors.grey)),
        ]))),
        const SizedBox(height: 20),
        Row(children: [const Text('附近设备', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)), const Spacer(), Text('${_peers.length} 台', style: TextStyle(color: colors.secondary))]),
        const SizedBox(height: 8),
        Card(child: _peers.isEmpty ? const Padding(padding: EdgeInsets.symmetric(vertical: 26, horizontal: 18), child: Column(children: [Icon(CupertinoIcons.wifi, size: 30, color: Colors.grey), SizedBox(height: 10), Text('正在寻找附近设备…', style: TextStyle(fontWeight: FontWeight.w600)), SizedBox(height: 4), Text('请让对方也打开 LanBridge，并连接同一 Wi-Fi。', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey, fontSize: 13))])) : Column(children: _peers.map((p) => ListTile(leading: CircleAvatar(backgroundColor: colors.secondaryContainer, child: Icon(CupertinoIcons.device_desktop, color: colors.onSecondaryContainer)), title: Text(p.name), subtitle: Text(p.host.address), trailing: const Icon(CupertinoIcons.chevron_right), onTap: _pickAndSend)).toList())),
        const SizedBox(height: 20),
        const Text('传输记录', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Card(child: _history.isEmpty ? const Padding(padding: EdgeInsets.all(20), child: Text('文件传输记录会显示在这里。', style: TextStyle(color: Colors.grey))) : Column(children: _history.take(12).map((item) => ListTile(leading: const Icon(CupertinoIcons.doc), title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis), subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('${item.direction} · ${_sizeLabel(item.size)} · ${item.status}'), if (item.status.contains('中')) Padding(padding: const EdgeInsets.only(top: 5), child: LinearProgressIndicator(value: item.progress)), if (item.detail != null) Text(item.detail!, style: const TextStyle(color: Colors.red, fontSize: 11))]), trailing: Icon(item.status == '已发送' ? CupertinoIcons.checkmark_circle_fill : item.status == '失败' ? CupertinoIcons.exclamationmark_circle : CupertinoIcons.arrow_up_right, color: item.status == '已发送' ? Colors.green : null))).toList())),
        const SizedBox(height: 14),
        const Center(child: Text('LanBridge · 仅在本地网络传输', style: TextStyle(color: Colors.grey, fontSize: 12))),
      ])),
    );
  }

  Future<void> _settings() async {
    await showModalBottomSheet<void>(context: context, showDragHandle: true, builder: (context) => StatefulBuilder(builder: (context, setSheetState) => SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(20, 8, 20, 30), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('设置', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)), const SizedBox(height: 12), SwitchListTile(value: _askBeforeReceive, title: const Text('接收前询问'), subtitle: const Text('避免附近设备未经确认发送文件'), onChanged: (v) { setState(() => _askBeforeReceive = v); setSheetState(() {}); }), const Divider(), const ListTile(leading: Icon(CupertinoIcons.folder), title: Text('保存位置'), subtitle: Text('当前 MVP 保存到应用文档目录；自选文件夹功能将在后续版本完善。')), const ListTile(leading: Icon(CupertinoIcons.lock_shield), title: Text('隐私与安全'), subtitle: Text('仅限可信 Wi-Fi 使用。当前 MVP 尚未实现传输加密。'))]))));
  }
}
