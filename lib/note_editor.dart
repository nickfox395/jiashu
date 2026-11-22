import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'data.dart';
import 'package:crypto/crypto.dart';
import 'protocol.dart';

enum _Tool { pen, white, text }

class _Mark {
  final _Tool tool;
  final List<Offset> points;
  final String text;
  _Mark(this.tool, Offset start, [this.text = '']) : points = [start];
}

class _PagePainter extends CustomPainter {
  static const sheet = Size(480, 546);
  final ui.Image image;
  final List<_Mark> marks;
  _PagePainter(this.image, this.marks);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / sheet.width, size.height / sheet.height);
    canvas.clipRect(Offset.zero & sheet);
    canvas.drawColor(Colors.white, BlendMode.src);
    paintImage(
      canvas: canvas,
      rect: Offset.zero & sheet,
      image: image,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
    );
    for (final mark in marks) {
      final start = mark.points.first;
      if (mark.tool == _Tool.text) {
        final painter = TextPainter(
          text: TextSpan(
            text: mark.text,
            style: const TextStyle(color: Colors.black, fontSize: 18),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: (sheet.width - start.dx).clamp(1, sheet.width));
        painter.paint(canvas, start);
        painter.dispose();
      } else {
        final brush = Paint()
          ..color = mark.tool == _Tool.white ? Colors.white : Colors.black
          ..strokeWidth = mark.tool == _Tool.white ? 16 : 2.5
          ..strokeCap = StrokeCap.round;
        canvas.drawCircle(start, brush.strokeWidth / 2, brush);
        for (var i = 1; i < mark.points.length; i++) {
          canvas.drawLine(mark.points[i - 1], mark.points[i], brush);
        }
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PagePainter oldDelegate) => true;
}

class NoteEditor extends StatefulWidget {
  final Store store;
  final Message note;
  final int pageIndex;
  const NoteEditor({
    super.key,
    required this.store,
    required this.note,
    required this.pageIndex,
  });
  @override
  State<NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<NoteEditor> {
  ui.Image? image;
  String? originalMd5, predecessor;
  final marks = <_Mark>[];
  var tool = _Tool.pen, busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() => error = null);
    try {
      final url = widget.note.images[widget.pageIndex];
      final local = await widget.store.localPage(widget.note, widget.pageIndex);
      final bytes =
          local?.bytes ??
          await http
              .readBytes(Uri.parse(url))
              .timeout(const Duration(seconds: 25));
      final codec = await ui.instantiateImageCodec(bytes);
      try {
        final frame = await codec.getNextFrame();
        if (!mounted) {
          frame.image.dispose();
          return;
        }
        setState(() {
          image = frame.image;
          originalMd5 = md5.convert(bytes).toString();
          predecessor = local?.revision;
        });
      } finally {
        codec.dispose();
      }
    } catch (_) {
      if (mounted) setState(() => error = '页面加载失败，请检查网络后重试');
    }
  }

  @override
  void dispose() {
    image?.dispose();
    super.dispose();
  }

  Future<void> addText(Offset at) async {
    var value = '';
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('在此处添加文字'),
        content: TextField(
          autofocus: true,
          maxLines: 4,
          onChanged: (v) => value = v,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, value),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (mounted && result != null && result.trim().isNotEmpty) {
      setState(() => marks.add(_Mark(_Tool.text, at, result)));
    }
  }

  Future<void> save() async {
    if (busy || image == null || marks.isEmpty) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final recorder = ui.PictureRecorder();
      _PagePainter(
        image!,
        marks,
      ).paint(Canvas(recorder), const Size(1920, 2184));
      final picture = recorder.endRecording();
      try {
        final result = await picture.toImage(1920, 2184);
        try {
          final bytes = await result.toByteData(format: ui.ImageByteFormat.png);
          if (bytes == null) throw const ApiFailure('无法生成页面');
          await widget.store.queuePage(
            widget.note,
            widget.pageIndex,
            originalMd5!,
            predecessor,
            bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
          );
        } finally {
          result.dispose();
        }
      } finally {
        picture.dispose();
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is ApiFailure ? e.message : '本机保存失败，请检查手机存储空间后重试',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Scaffold(
      appBar: AppBar(
        title: Text('编辑正文 · 第 ${widget.pageIndex + 1} 页'),
        actions: [
          TextButton(
            onPressed: !busy && marks.isNotEmpty ? save : null,
            child: Text(busy ? '保存中…' : '保存'),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (error != null)
              Padding(padding: const EdgeInsets.all(8), child: Text(error!)),
            Expanded(
              child: Center(
                child: image == null
                    ? error == null
                          ? const CircularProgressIndicator()
                          : TextButton(
                              onPressed: load,
                              child: const Text('重新加载'),
                            )
                    : AspectRatio(
                        aspectRatio: 480 / 546,
                        child: LayoutBuilder(
                          builder: (context, box) {
                            Offset point(Offset p) => p * (480 / box.maxWidth);
                            return GestureDetector(
                              onTapUp: busy
                                  ? null
                                  : (d) {
                                      final at = point(d.localPosition);
                                      if (tool == _Tool.text) {
                                        addText(at);
                                      } else {
                                        setState(
                                          () => marks.add(_Mark(tool, at)),
                                        );
                                      }
                                    },
                              onPanStart: busy || tool == _Tool.text
                                  ? null
                                  : (d) => setState(
                                      () => marks.add(
                                        _Mark(tool, point(d.localPosition)),
                                      ),
                                    ),
                              onPanUpdate: busy || tool == _Tool.text
                                  ? null
                                  : (d) => setState(
                                      () => marks.last.points.add(
                                        point(d.localPosition),
                                      ),
                                    ),
                              child: CustomPaint(
                                painter: _PagePainter(image!, marks),
                                size: Size.infinite,
                              ),
                            );
                          },
                        ),
                      ),
              ),
            ),
            if (image != null) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SegmentedButton<_Tool>(
                    segments: const [
                      ButtonSegment(value: _Tool.pen, label: Text('画笔')),
                      ButtonSegment(value: _Tool.white, label: Text('涂白')),
                      ButtonSegment(value: _Tool.text, label: Text('文字')),
                    ],
                    selected: {tool},
                    onSelectionChanged: busy
                        ? null
                        : (values) => setState(() => tool = values.single),
                  ),
                  IconButton(
                    tooltip: '撤销',
                    onPressed: marks.isEmpty || busy
                        ? null
                        : () => setState(() => marks.removeLast()),
                    icon: const Icon(Icons.undo),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.all(10),
                child: Text(
                  tool == _Tool.text
                      ? '点页面选择文字位置。保存后，本页原笔迹与修改会合为一张图片。'
                      : '在页面上拖动修改。保存后，本页原笔迹与修改会合为一张图片。',
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
