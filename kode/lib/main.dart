import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dsp.dart';

const bg = Color(0xFF181B3A);
const panel = Color(0xFF262B5C);
const teal = Color(0xFF4DD0B8);
const outColors = [
  Color(0xFFF0A030), Color(0xFF2E86E8), Color(0xFFE03C3C), Color(0xFF6CC644),
  Color(0xFF9A6CF0), Color(0xFF8A6A4A), Color(0xFF2E86E8), Color(0xFFE03C3C)
];
const inColors = [Color(0xFFF0A030), Color(0xFFE03C3C), Color(0xFF6CC644), Color(0xFF9A6CF0)];
// Tanda * = nama diduga dari pola kode, belum terkonfirmasi.
const filterTypes = {
  0: 'Bypass', 1: 'Bworth-12dB', 2: 'Bessel-12dB*', 3: 'LR-12dB*', 4: 'Bworth-18dB',
  5: 'Bessel-18dB*', 6: 'LR-18dB*', 7: 'Bworth-24dB', 8: 'Bessel-24dB', 9: 'LR-24dB*'
};
const bandTypes = {0: 'PEQ', 1: 'LSEQ*', 2: 'HSEQ'};

// Nilai mentah meter = dBFS + 135. Bar mulai dari -80 dBFS supaya noise input terbuka tidak tampil.
const meterFloor = 55;

int lim(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);
double limd(double v, double lo, double hi) => v < lo ? lo : (v > hi ? hi : v);

extension ChUi on Ch {
  Color get color => input ? inColors[idx] : outColors[idx];
  String get short => input ? 'IN ${"ABCD"[idx]}' : 'OUT ${idx + 1}';
}

final allCh = [for (var i = 0; i < 4; i++) Ch.input(i), for (var i = 0; i < 8; i++) Ch.output(i)];

class Gate {
  int _t = 0;
  bool open([int ms = 50]) {
    final n = DateTime.now().millisecondsSinceEpoch;
    if (n - _t < ms) return false;
    _t = n;
    return true;
  }
}

void report(BuildContext c, bool ok) {
  if (!ok && c.mounted) {
    ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('DSP tidak membalas')));
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations(
      [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const DspApp());
}

class DspApp extends StatelessWidget {
  const DspApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'DSP Remote',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: bg,
          colorScheme: ColorScheme.fromSeed(seedColor: teal, brightness: Brightness.dark),
          sliderTheme: const SliderThemeData(
            trackHeight: 5,
            activeTrackColor: teal,
            thumbColor: Colors.white,
            thumbShape: RoundSliderThumbShape(enabledThumbRadius: 9),
            overlayShape: RoundSliderOverlayShape(overlayRadius: 16),
          ),
        ),
        home: const Home(),
      );
}

// ---------------- koneksi ----------------
class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  final ip = TextEditingController(text: '192.168.1.14');
  Dsp? dsp;
  DspState? st;
  String status = 'Belum terhubung';
  bool busy = false;

  Future<void> connect() async {
    if (busy) return;
    final had = dsp != null; // sudah pernah terhubung: layar mixer tetap tampil
    setState(() {
      busy = true;
      if (!had) status = 'Menghubungkan...';
    });
    final d = Dsp(ip.text.trim());
    DspState? s;
    String? err;
    try {
      await d.open();
      s = await d.readState();
    } catch (e) {
      err = 'Gagal: $e';
    }
    if (!mounted) {
      d.dispose();
      return;
    }
    if (s == null) {
      d.dispose();
      setState(() {
        busy = false;
        if (!had) status = err ?? 'DSP tidak membalas. Cek IP dan pastikan satu WiFi.';
      });
      if (had) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(err ?? 'Gagal menyambung ke DSP')));
      }
      return;
    }
    final old = dsp;
    setState(() {
      busy = false;
      dsp = d;
      st = s;
      status = 'Terhubung';
    });
    old?.dispose();
  }

  @override
  void dispose() {
    dsp?.dispose();
    ip.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = st, d = dsp;
    if (s == null || d == null) {
      return Scaffold(
        body: Center(
          child: SingleChildScrollView(
            child: SizedBox(
              width: 340,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('DSP Remote', style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 14),
                TextField(
                  controller: ip,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'IP DSP', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 10),
                FilledButton(
                    onPressed: busy ? null : connect,
                    child: Text(busy ? 'Menghubungkan...' : 'Hubungkan')),
                const SizedBox(height: 8),
                Text(status, textAlign: TextAlign.center),
              ]),
            ),
          ),
        ),
      );
    }
    return Mixer(key: ValueKey(s.hashCode), dsp: d, st: s, busy: busy, onRefresh: connect);
  }
}

// ---------------- layar utama ----------------
class Mixer extends StatefulWidget {
  const Mixer({super.key, required this.dsp, required this.st, required this.busy, required this.onRefresh});
  final Dsp dsp;
  final DspState st;
  final bool busy;
  final VoidCallback onRefresh;
  @override
  State<Mixer> createState() => _MixerState();
}

class _MixerState extends State<Mixer> with WidgetsBindingObserver {
  int page = 0;
  Ch sel = const Ch.output(0);
  late bool online = widget.dsp.online;
  StreamSubscription<bool>? _sub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sub = widget.dsp.onlineStream.listen((v) {
      if (!mounted) return;
      final back = v && !online;
      setState(() => online = v);
      // DSP menjawab lagi setelah terputus: baca ulang status (bisa jadi DSP restart)
      if (back) widget.onRefresh();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      // keamanan: generator jangan dibiarkan menyala saat app di background
      widget.dsp.genStop();
    } else if (state == AppLifecycleState.resumed) {
      setState(() {});
      widget.dsp.ping().then((ok) {
        if (!ok && mounted) widget.onRefresh();
      });
    }
  }

  static const icons = [Icons.tune, Icons.graphic_eq, Icons.schedule, Icons.compress, Icons.call_split, Icons.waves];
  static const labels = ['Gain', 'EQ', 'Delay', 'Comp&Gate', 'Matrix', 'Generator'];

  @override
  Widget build(BuildContext context) {
    final d = widget.dsp, s = widget.st;
    final Widget body = switch (page) {
      0 => GainPage(dsp: d, st: s, sel: sel, onSel: (c) => setState(() => sel = c)),
      1 => EqPage(dsp: d, st: s, sel: sel, onSel: (c) => setState(() => sel = c)),
      2 => DelayPage(dsp: d, st: s),
      3 => CompPage(dsp: d, st: s),
      4 => MatrixPage(dsp: d, st: s),
      _ => GenPage(dsp: d, st: s),
    };
    return Scaffold(
      body: SafeArea(
        child: Row(children: [
          Container(
            width: 66,
            color: panel,
            child: Column(children: [
              Expanded(
                child: ListView(children: [
                  for (var i = 0; i < 6; i++)
                    InkWell(
                      onTap: () => setState(() => page = i),
                      child: Container(
                        color: page == i ? bg : null,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Column(children: [
                          Icon(icons[i], color: page == i ? teal : Colors.white70),
                          Text(labels[i],
                              style: TextStyle(fontSize: 10, color: page == i ? teal : Colors.white70)),
                        ]),
                      ),
                    ),
                ]),
              ),
              Tooltip(
                message: online ? 'Terhubung' : 'Terputus',
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(Icons.circle, size: 12, color: online ? Colors.greenAccent : Colors.redAccent),
                ),
              ),
              if (widget.busy)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                )
              else
                IconButton(
                    tooltip: 'Baca ulang dari DSP',
                    onPressed: widget.onRefresh,
                    icon: const Icon(Icons.refresh)),
              IconButton(
                  tooltip: 'Store to device',
                  onPressed: () => storeDialog(context, d, s),
                  icon: const Icon(Icons.save_outlined)),
            ]),
          ),
          Expanded(
            child: Column(children: [
              if (!online)
                Container(
                  width: double.infinity,
                  color: Colors.red.shade800,
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: const Text('DSP tidak terhubung, mencoba menyambung ulang...',
                      textAlign: TextAlign.center, style: TextStyle(fontSize: 12)),
                ),
              Expanded(child: body),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ---------------- Store to device ----------------
Future<void> storeDialog(BuildContext context, Dsp dsp, DspState st) async {
  var slot = 1;
  final name = TextEditingController(text: (st.presets[slot] ?? '').trim());
  final go = await showDialog<bool>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setS) => AlertDialog(
        title: const Text('Store to device'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Setting yang aktif sekarang disimpan ke slot preset di DSP. Isi lama slot itu akan tertimpa.',
                style: TextStyle(color: Colors.amber)),
            const SizedBox(height: 10),
            DropdownButton<int>(
              value: slot,
              isExpanded: true,
              items: [
                for (var i = 0; i < 32; i++)
                  DropdownMenuItem(value: i, child: Text('Slot $i: ${(st.presets[i] ?? '').trim()}')),
              ],
              onChanged: (v) {
                if (v == null) return;
                setS(() {
                  slot = v;
                  name.text = (st.presets[v] ?? '').trim();
                });
              },
            ),
            TextField(
              controller: name,
              maxLength: 15,
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[ -~]'))],
              decoration: const InputDecoration(labelText: 'Nama preset'),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Simpan')),
        ],
      ),
    ),
  );
  final nm = name.text.trim();
  name.dispose();
  if (go != true || nm.isEmpty) return;
  final ok = await dsp.send(storeCmd(slot, nm), retries: 3);
  if (ok) st.presets[slot] = nm;
  if (context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(ok ? 'Tersimpan ke slot $slot ($nm)' : 'DSP tidak membalas, belum tersimpan')));
  }
}

// ---------------- halaman Gain ----------------
class GainPage extends StatelessWidget {
  const GainPage({super.key, required this.dsp, required this.st, required this.sel, required this.onSel});
  final Dsp dsp;
  final DspState st;
  final Ch sel;
  final ValueChanged<Ch> onSel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(6),
      child: ListView(scrollDirection: Axis.horizontal, children: [
        for (final c in allCh) ...[
          if (!c.input && c.idx == 0) const VerticalDivider(width: 14),
          Strip(
              key: ValueKey(c.key),
              ch: c,
              st: st,
              dsp: dsp,
              selected: c.key == sel.key,
              onSelect: () => onSel(c)),
        ]
      ]),
    );
  }
}

class Strip extends StatefulWidget {
  const Strip(
      {super.key,
      required this.ch,
      required this.st,
      required this.dsp,
      required this.selected,
      required this.onSelect});
  final Ch ch;
  final DspState st;
  final Dsp dsp;
  final bool selected;
  final VoidCallback onSelect;
  @override
  State<Strip> createState() => _StripState();
}

class _StripState extends State<Strip> {
  late double gain = limd((widget.st.gain[widget.ch.key] ?? 0).toDouble(), -80, 12);
  late bool mute = widget.st.mute[widget.ch.key] ?? false;
  late bool pol = widget.st.pol[widget.ch.key] ?? false;
  final gate = Gate();

  Future<void> _toggle(bool isMute) async {
    final v = !(isMute ? mute : pol);
    setState(() {
      if (isMute) {
        mute = v;
        widget.st.mute[widget.ch.key] = v;
      } else {
        pol = v;
        widget.st.pol[widget.ch.key] = v;
      }
    });
    final ok = await widget.dsp.send(isMute ? muteCmd(widget.ch, v) : polCmd(widget.ch, v));
    if (mounted) report(context, ok);
  }

  Widget _tog(IconData i, bool on, Color col, VoidCallback f) => InkWell(
        onTap: f,
        child: Container(
          height: 36,
          margin: const EdgeInsets.fromLTRB(6, 3, 6, 3),
          decoration: BoxDecoration(
              color: on ? col : Colors.black26, borderRadius: BorderRadius.circular(6)),
          alignment: Alignment.center,
          child: Icon(i, size: 20, color: on ? Colors.black : Colors.white70),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final ch = widget.ch;
    return Container(
      width: 72,
      margin: const EdgeInsets.symmetric(horizontal: 3),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: widget.selected ? teal : Colors.transparent, width: 2),
      ),
      child: Column(children: [
        GestureDetector(
          onTap: widget.onSelect,
          child: Container(
            height: 28,
            width: double.infinity,
            color: ch.color,
            alignment: Alignment.center,
            child: Text(ch.short,
                style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 12)),
          ),
        ),
        Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Text('${gain.round()} dB', style: const TextStyle(fontSize: 12))),
        Expanded(
          child: Row(children: [
            Expanded(
              child: RotatedBox(
            quarterTurns: 3,
            child: Slider(
              min: -80,
              max: 12,
              divisions: 92,
              value: gain,
              onChanged: (v) {
                setState(() => gain = v);
                widget.st.gain[ch.key] = v.round();
                if (gate.open()) widget.dsp.send(gainCmd(ch, v.round()), retries: 1);
              },
              onChangeEnd: (v) async {
                final ok = await widget.dsp.send(gainCmd(ch, v.round()));
                if (mounted) report(context, ok);
              },
            ),
          ),
            ),
            MeterBar(dsp: widget.dsp, index: ch.input ? ch.idx : 4 + ch.idx),
          ]),
        ),
        _tog(Icons.contrast, pol, teal, () => _toggle(false)),
        _tog(Icons.volume_off, mute, Colors.amber, () => _toggle(true)),
      ]),
    );
  }
}

// ---------------- halaman Delay ----------------
class DelayPage extends StatelessWidget {
  const DelayPage({super.key, required this.dsp, required this.st});
  final Dsp dsp;
  final DspState st;

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.all(12), children: [
      const Text('Delay (ms)'),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final c in allCh)
          Container(
            width: 92,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(color: panel, borderRadius: BorderRadius.circular(8)),
            child: Column(children: [
              Container(height: 5, color: c.color),
              const SizedBox(height: 6),
              Text(c.short),
              const SizedBox(height: 4),
              NumBox(
                w: 70,
                text: '${st.delay[c.key] ?? 0}',
                onSubmit: (t) async {
                  final v = int.tryParse(t);
                  if (v == null) return;
                  final n = lim(v, 0, 1000);
                  st.delay[c.key] = n;
                  final ok = await dsp.send(delayCmd(c, n));
                  if (context.mounted) report(context, ok);
                },
              ),
              const SizedBox(height: 8),
            ]),
          ),
      ]),
    ]);
  }
}

// ---------------- halaman EQ ----------------
Rect plotRect(Size s) => Rect.fromLTWH(30, 6, s.width - 38, s.height - 22);
double fx(double f, Rect r) => r.left + math.log(f / 20) / math.log(1000) * r.width;
double fy(double db, Rect r) => r.top + (18 - db) / 36 * r.height;

double _mag(double b0, double b1, double b2, double a0, double a1, double a2, double w) {
  final c1 = math.cos(w), s1 = math.sin(w), c2 = math.cos(2 * w), s2 = math.sin(2 * w);
  final nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2);
  final dr = a0 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2);
  return math.sqrt((nr * nr + ni * ni) / (dr * dr + di * di));
}

double _bw(int type, int fc, double f, bool hp) {
  const orders = {1: 2, 2: 2, 3: 2, 4: 3, 5: 3, 6: 3, 7: 4, 8: 4, 9: 4};
  final n = orders[type] ?? 0;
  if (n == 0) return 0;
  final r = hp ? fc / f : f / fc;
  return -10 * math.log(1 + math.pow(r, 2 * n)) / math.ln10;
}

double responseDb(EqCh e, double f) {
  var db = 0.0;
  final w = 2 * math.pi * f / 48000;
  for (final b in e.bands) {
    if (b.db.abs() < 0.05) continue;
    final a = math.pow(10, b.db / 40).toDouble();
    final w0 = 2 * math.pi * b.hz / 48000;
    final cw = math.cos(w0);
    double m;
    if (b.type == 1 || b.type == 2) {
      final al = math.sin(w0) / 2 * math.sqrt(2);
      final sa = 2 * math.sqrt(a) * al;
      if (b.type == 2) {
        m = _mag(a * ((a + 1) + (a - 1) * cw + sa), -2 * a * ((a - 1) + (a + 1) * cw),
            a * ((a + 1) + (a - 1) * cw - sa), (a + 1) - (a - 1) * cw + sa,
            2 * ((a - 1) - (a + 1) * cw), (a + 1) - (a - 1) * cw - sa, w);
      } else {
        m = _mag(a * ((a + 1) - (a - 1) * cw + sa), 2 * a * ((a - 1) - (a + 1) * cw),
            a * ((a + 1) - (a - 1) * cw - sa), (a + 1) + (a - 1) * cw + sa,
            -2 * ((a - 1) + (a + 1) * cw), (a + 1) + (a - 1) * cw - sa, w);
      }
    } else {
      final al = math.sin(w0) / (2 * b.q);
      m = _mag(1 + al * a, -2 * cw, 1 - al * a, 1 + al / a, -2 * cw, 1 - al / a, w);
    }
    db += 20 * math.log(m) / math.ln10;
  }
  return db + _bw(e.hpType, e.hpHz, f, true) + _bw(e.lpType, e.lpHz, f, false);
}

class EqPainter extends CustomPainter {
  EqPainter(this.e, this.drag);
  final EqCh e;
  final int? drag;

  void _text(Canvas c, String s, Offset o, {double size = 9, bool center = false}) {
    final tp = TextPainter(
        text: TextSpan(text: s, style: TextStyle(color: Colors.white54, fontSize: size)),
        textDirection: TextDirection.ltr)
      ..layout();
    tp.paint(c, center ? o - Offset(tp.width / 2, tp.height / 2) : o);
  }

  @override
  void paint(Canvas c, Size s) {
    final r = plotRect(s);
    c.drawRect(r, Paint()..color = const Color(0xFF0E1026));
    final grid = Paint()
      ..color = Colors.white12
      ..strokeWidth = 1;
    for (final f in [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]) {
      final x = fx(f.toDouble(), r);
      c.drawLine(Offset(x, r.top), Offset(x, r.bottom), grid);
      _text(c, f >= 1000 ? '${f ~/ 1000}k' : '$f', Offset(x - 8, r.bottom + 3));
    }
    for (var db = -18; db <= 18; db += 6) {
      final y = fy(db.toDouble(), r);
      c.drawLine(Offset(r.left, y), Offset(r.right, y),
          db == 0 ? (Paint()..color = Colors.white38) : grid);
      _text(c, '$db', Offset(4, y - 5));
    }
    final path = Path();
    for (var i = 0; i <= 240; i++) {
      final f = 20 * math.pow(1000, i / 240).toDouble();
      final x = r.left + r.width * i / 240;
      final y = fy(limd(responseDb(e, f), -18, 18), r);
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    c.drawPath(
        path,
        Paint()
          ..color = const Color(0xFF8BE04E)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
    for (var i = 0; i < e.bands.length; i++) {
      final b = e.bands[i];
      final o = Offset(fx(limd(b.hz.toDouble(), 20, 20000), r), fy(limd(b.db, -18, 18), r));
      c.drawCircle(o, 9, Paint()..color = i == drag ? teal : panel);
      c.drawCircle(
          o,
          9,
          Paint()
            ..color = Colors.white70
            ..style = PaintingStyle.stroke);
      _text(c, '${i + 1}', o, size: 9, center: true);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => true;
}

class EqPage extends StatefulWidget {
  const EqPage({super.key, required this.dsp, required this.st, required this.sel, required this.onSel});
  final Dsp dsp;
  final DspState st;
  final Ch sel;
  final ValueChanged<Ch> onSel;
  @override
  State<EqPage> createState() => _EqPageState();
}

class _EqPageState extends State<EqPage> {
  final gate = Gate();
  int? drag;

  EqCh? get eq => widget.st.eq[widget.sel.key];

  Future<void> _send(int i, {bool force = false}) async {
    final b = eq!.bands[i];
    if (!force && !gate.open()) return;
    final ok = await widget.dsp.send(bandCmd(widget.sel, i, b.db, b.q, b.hz), retries: force ? 3 : 1);
    if (force && mounted) report(context, ok);
  }

  void _set(int i, {double? db, double? q, int? hz, bool force = false}) {
    final e = eq!, b = e.bands[i];
    setState(() => e.bands[i] = Band(
        limd(db ?? b.db, -12, 12), limd(q ?? b.q, 0.3, 15), lim(hz ?? b.hz, 20, 20000), b.type));
    _send(i, force: force);
  }

  Future<void> _cmd(List<int> c) async {
    final ok = await widget.dsp.send(c);
    if (mounted) report(context, ok);
  }

  Widget _typeDrop(int cur, void Function(int) on) {
    final items = {...filterTypes.keys, cur}.toList()..sort();
    return DropdownButton<int>(
      value: cur,
      isDense: true,
      underline: const SizedBox(),
      items: [
        for (final t in items) DropdownMenuItem(value: t, child: Text(filterTypes[t] ?? 'Tipe $t'))
      ],
      onChanged: (v) {
        if (v != null) on(v);
      },
    );
  }

  int _nearest(Offset p, Size s, EqCh e) {
    final r = plotRect(s);
    var best = -1;
    var bd = 30.0;
    for (var i = 0; i < e.bands.length; i++) {
      final b = e.bands[i];
      final d = (Offset(fx(limd(b.hz.toDouble(), 20, 20000), r), fy(limd(b.db, -18, 18), r)) - p).distance;
      if (d < bd) {
        bd = d;
        best = i;
      }
    }
    return best;
  }

  @override
  Widget build(BuildContext context) {
    final e = eq;
    final c = widget.sel;
    return Column(children: [
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(children: [
          DropdownButton<String>(
            value: c.key,
            isDense: true,
            underline: const SizedBox(),
            items: [for (final x in allCh) DropdownMenuItem(value: x.key, child: Text(x.name))],
            onChanged: (k) {
              if (k != null) widget.onSel(allCh.firstWhere((x) => x.key == k));
            },
          ),
          if (e != null) ...[
            const SizedBox(width: 14),
            const Text('HP '),
            _typeDrop(e.hpType, (t) {
              setState(() => e.hpType = t);
              _cmd(hpTypeCmd(c, t));
            }),
            NumBox(
                w: 62,
                text: '${e.hpHz}',
                onSubmit: (t) {
                  final v = int.tryParse(t);
                  if (v == null) return;
                  setState(() => e.hpHz = lim(v, 20, 20000));
                  _cmd(hpFreqCmd(c, e.hpHz));
                }),
            const SizedBox(width: 14),
            const Text('LP '),
            _typeDrop(e.lpType, (t) {
              setState(() => e.lpType = t);
              _cmd(lpTypeCmd(c, t));
            }),
            NumBox(
                w: 62,
                text: '${e.lpHz}',
                onSubmit: (t) {
                  final v = int.tryParse(t);
                  if (v == null) return;
                  setState(() => e.lpHz = lim(v, 20, 20000));
                  _cmd(lpFreqCmd(c, e.lpHz));
                }),
          ],
        ]),
      ),
      if (e == null)
        const Expanded(child: Center(child: Text('Data EQ tidak tersedia')))
      else ...[
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: LayoutBuilder(builder: (ctx, box) {
              final size = Size(box.maxWidth, box.maxHeight);
              return Listener(
                onPointerDown: (ev) {
                  final i = _nearest(ev.localPosition, size, e);
                  if (i >= 0) setState(() => drag = i);
                },
                onPointerMove: (ev) {
                  final i = drag;
                  if (i == null) return;
                  final r = plotRect(size);
                  final hz = 20 * math.pow(1000, (ev.localPosition.dx - r.left) / r.width).toDouble();
                  final db = 18 - (ev.localPosition.dy - r.top) / r.height * 36;
                  _set(i, hz: hz.round(), db: db);
                },
                onPointerUp: (_) {
                  final i = drag;
                  if (i == null) return;
                  setState(() => drag = null);
                  _send(i, force: true);
                },
                onPointerCancel: (_) => setState(() => drag = null),
                child: CustomPaint(size: size, painter: EqPainter(e, drag)),
              );
            }),
          ),
        ),
        SizedBox(
          height: 204,
          child: ListView(scrollDirection: Axis.horizontal, children: [
            for (var i = 0; i < e.bands.length; i++) _bandCol(i, e),
          ]),
        ),
      ],
    ]);
  }

  void _setType(int i, int t) {
    final e = eq!, b = e.bands[i];
    setState(() => e.bands[i] = Band(b.db, b.q, b.hz, t));
    _cmd(bandTypeCmd(widget.sel, i, t));
  }

  Widget _bandCol(int i, EqCh e) {
    final b = e.bands[i];
    return SizedBox(
      width: 60,
      child: Column(children: [
        Text('${b.db >= 0 ? "+" : ""}${b.db.toStringAsFixed(1)}', style: const TextStyle(fontSize: 10)),
        SizedBox(
          height: 78,
          child: RotatedBox(
            quarterTurns: 3,
            child: Slider(
              min: -12,
              max: 12,
              divisions: 240,
              value: limd(b.db, -12, 12),
              onChanged: (v) => _set(i, db: v),
              onChangeEnd: (v) => _set(i, db: v, force: true),
            ),
          ),
        ),
        NumBox(
            w: 54,
            text: '${b.hz}',
            onSubmit: (t) {
              final v = int.tryParse(t);
              if (v != null) _set(i, hz: v, force: true);
            }),
        const SizedBox(height: 4),
        NumBox(
            w: 54,
            text: b.q.toStringAsFixed(1),
            onSubmit: (t) {
              final v = double.tryParse(t.replaceAll(',', '.'));
              if (v != null) _set(i, q: v, force: true);
            }),
        DropdownButton<int>(
          value: b.type,
          isDense: true,
          underline: const SizedBox(),
          style: const TextStyle(fontSize: 11),
          items: [
            for (final t in {...bandTypes.keys, b.type}.toList()..sort())
              DropdownMenuItem(value: t, child: Text(bandTypes[t] ?? 'Tipe $t'))
          ],
          onChanged: (t) {
            if (t != null) _setType(i, t);
          },
        ),
      ]),
    );
  }
}

// ---------------- kotak angka kecil ----------------
class NumBox extends StatefulWidget {
  const NumBox({super.key, required this.text, required this.onSubmit, this.w = 60});
  final String text;
  final ValueChanged<String> onSubmit;
  final double w;
  @override
  State<NumBox> createState() => _NumBoxState();
}

class _NumBoxState extends State<NumBox> {
  late final c = TextEditingController(text: widget.text);

  @override
  void didUpdateWidget(NumBox old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text && c.text != widget.text) c.text = widget.text;
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: widget.w,
        height: 32,
        child: TextField(
          controller: c,
          textAlign: TextAlign.center,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: const TextStyle(fontSize: 12),
          decoration: const InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.symmetric(vertical: 7),
              border: OutlineInputBorder()),
          onSubmitted: widget.onSubmit,
        ),
      );
}

// ---------------- level meter ----------------
class MeterBar extends StatelessWidget {
  const MeterBar({super.key, required this.dsp, required this.index});
  final Dsp dsp;
  final int index;

  @override
  Widget build(BuildContext context) => StreamBuilder<List<int>>(
        stream: dsp.meters,
        builder: (context, snap) {
          final v = snap.data == null ? 32 : snap.data![index];
          final f = limd((v - meterFloor) / (135 - meterFloor), 0, 1);
          return Container(
            width: 8,
            margin: const EdgeInsets.only(right: 4, top: 4, bottom: 4),
            color: Colors.black38,
            alignment: Alignment.bottomCenter,
            child: FractionallySizedBox(
                heightFactor: f, child: const ColoredBox(color: Color(0xFF6CC644), child: SizedBox.expand())),
          );
        },
      );
}

// ---------------- Comp & Gate ----------------
class CompPage extends StatefulWidget {
  const CompPage({super.key, required this.dsp, required this.st});
  final Dsp dsp;
  final DspState st;
  @override
  State<CompPage> createState() => _CompPageState();
}

class _CompPageState extends State<CompPage> {
  Ch g = const Ch.input(0), c = const Ch.output(0);
  final gate = Gate();

  void _push(List<int> cmd, bool end) {
    if (!end && !gate.open()) return;
    final f = widget.dsp.send(cmd, retries: end ? 3 : 1);
    if (end) f.then((ok) => report(context, ok));
  }

  Widget _row(String name, int raw, int lo, int hi, String text, void Function(int, bool) on) => Row(children: [
        SizedBox(width: 70, child: Text(name, style: const TextStyle(fontSize: 12))),
        Expanded(
          child: Slider(
            min: lo.toDouble(),
            max: hi.toDouble(),
            divisions: hi - lo,
            value: limd(raw.toDouble(), lo.toDouble(), hi.toDouble()),
            onChanged: (v) => on(v.round(), false),
            onChangeEnd: (v) => on(v.round(), true),
          ),
        ),
        SizedBox(width: 78, child: Text(text, textAlign: TextAlign.end, style: const TextStyle(fontSize: 12))),
      ]);

  Widget _card(String title, List<Widget> kids) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: panel, borderRadius: BorderRadius.circular(8)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          ...kids,
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final a = widget.st.gate.putIfAbsent(g.key, () => [1, 0, 0, 0, 0]);
    final b = widget.st.comp.putIfAbsent(c.key, () => [1, 0, 0, 0, 0, 68, 0]);
    return ListView(padding: const EdgeInsets.all(10), children: [
      _card('Noise Gate (input)', [
        Wrap(spacing: 6, children: [
          for (var i = 0; i < 4; i++)
            ChoiceChip(
                label: Text(Ch.input(i).short),
                selected: g.idx == i,
                onSelected: (_) => setState(() => g = Ch.input(i))),
        ]),
        _row('Level', a[1], 0, 96, '${a[1] - 135} dB',
            (v, end) { setState(() => a[1] = v); _push(gateCmd(g, 2, v), end); }),
        _row('Attack', a[2], 0, 250, '${a[2] * 2} ms',
            (v, end) { setState(() => a[2] = v); _push(gateCmd(g, 3, v), end); }),
        _row('Hold', a[3], 0, 250, '${a[3] * 2} ms',
            (v, end) { setState(() => a[3] = v); _push(gateCmd(g, 4, v), end); }),
        _row('Release', a[4], 0, 250, '${a[4] * 8} ms',
            (v, end) { setState(() => a[4] = v); _push(gateCmd(g, 5, v), end); }),
      ]),
      _card('Compressor (output)', [
        Wrap(spacing: 6, children: [
          for (var i = 0; i < 8; i++)
            ChoiceChip(
                label: Text(Ch.output(i).short),
                selected: c.idx == i,
                onSelected: (_) => setState(() => c = Ch.output(i))),
        ]),
        Wrap(spacing: 6, children: [
          for (var i = 0; i < 3; i++)
            ChoiceChip(
                label: Text(const ['Hard', 'Medium', 'Soft'][i]),
                selected: b[6] == i,
                onSelected: (_) {
                  setState(() => b[6] = i);
                  _push(compCmd(c, 7, i), true);
                }),
        ]),
        _row('Threshold', b[1], 0, 155, '${b[1] - 135} dB',
            (v, end) { setState(() => b[1] = v); _push(compCmd(c, 2, v), end); }),
        _row('Ratio', b[2], 0, 100, '${(1 + b[2] * 0.04).toStringAsFixed(2)} : 1',
            (v, end) { setState(() => b[2] = v); _push(compCmd(c, 3, v), end); }),
        _row('Attack', b[3], 0, 250, '${b[3] * 2} ms',
            (v, end) { setState(() => b[3] = v); _push(compCmd(c, 4, v), end); }),
        _row('Release', b[4], 0, 250, '${b[4] * 8} ms',
            (v, end) { setState(() => b[4] = v); _push(compCmd(c, 5, v), end); }),
        _row('Level', b[5], 68, 92, '${b[5] - 80} dB',
            (v, end) { setState(() => b[5] = v); _push(compCmd(c, 6, v), end); }),
      ]),
    ]);
  }
}

// ---------------- Matrix ----------------
class MatrixPage extends StatefulWidget {
  const MatrixPage({super.key, required this.dsp, required this.st});
  final Dsp dsp;
  final DspState st;
  @override
  State<MatrixPage> createState() => _MatrixPageState();
}

class _MatrixPageState extends State<MatrixPage> {
  Future<void> _toggle(int i, int o) async {
    final k = 'in${i}out$o';
    final v = !(widget.st.matrix[k] ?? false);
    setState(() => widget.st.matrix[k] = v);
    final ok = await widget.dsp.send(matrixCmd(i, o, v));
    if (mounted) report(context, ok);
  }

  Widget _cell(int i, int o) {
    final on = widget.st.matrix['in${i}out$o'] ?? false;
    return InkWell(
      onTap: () => _toggle(i, o),
      child: Container(
        width: 44,
        height: 40,
        margin: const EdgeInsets.all(4),
        decoration: BoxDecoration(color: on ? teal : Colors.black26, borderRadius: BorderRadius.circular(6)),
        alignment: Alignment.center,
        child: on ? const Icon(Icons.close, size: 20, color: Colors.black) : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.all(10), children: [
      const Text('Matrix: ketuk kotak untuk menyambung atau memutus input ke output'),
      const SizedBox(height: 8),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Column(children: [
          Row(children: [
            const SizedBox(width: 56),
            for (var o = 0; o < 8; o++)
              SizedBox(width: 52, child: Center(child: Text('OUT ${o + 1}', style: const TextStyle(fontSize: 11)))),
          ]),
          for (var i = 0; i < 4; i++)
            Row(children: [
              SizedBox(width: 56, child: Text(Ch.input(i).short, style: TextStyle(fontSize: 12, color: Ch.input(i).color))),
              for (var o = 0; o < 8; o++) _cell(i, o),
            ]),
        ]),
      ),
    ]);
  }
}

// ---------------- Signal Generator ----------------
class GenPage extends StatefulWidget {
  const GenPage({super.key, required this.dsp, required this.st});
  final Dsp dsp;
  final DspState st;
  @override
  State<GenPage> createState() => _GenPageState();
}

class _GenPageState extends State<GenPage> {
  double level = -60;
  int freq = 1000;
  int type = 0;
  final gate = Gate();

  bool get on => widget.dsp.genOn;

  @override
  void dispose() {
    // keluar dari halaman ini (atau app ditutup) = generator dimatikan
    widget.dsp.genStop();
    super.dispose();
  }

  Future<void> _on(bool v) async {
    if (v) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Nyalakan generator?'),
          content: const Text(
              'Suara akan keluar di output yang dipilih. Turunkan volume amp ke minimum atau lepas speaker dulu.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Batal')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Nyalakan')),
          ],
        ),
      );
      if (ok != true) return;
      await widget.dsp.send(genLevelCmd(level.round()));
      await widget.dsp.send(genFreqCmd(freq));
      await widget.dsp.send(genTypeCmd(type));
      await widget.dsp.send(genOutputsCmd(widget.st.genOut));
    }
    if (!mounted) return;
    setState(() => widget.dsp.genOn = v);
    final r = await widget.dsp.send(genMuteCmd(!v));
    if (!r && !v) {
      // perintah mati belum terkonfirmasi: anggap masih menyala supaya genStop() tetap mencoba
      widget.dsp.genOn = true;
    }
    if (mounted) {
      setState(() {});
      report(context, r);
    }
  }

  @override
  Widget build(BuildContext context) {
    final out = widget.st.genOut;
    return ListView(padding: const EdgeInsets.all(12), children: [
      const Text('Signal Generator. Turunkan volume amp atau lepas speaker sebelum menyalakan.',
          style: TextStyle(color: Colors.amber)),
      const SizedBox(height: 8),
      Row(children: [
        const Text('Status: '),
        Switch(value: on, onChanged: _on),
        Text(on ? 'NYALA' : 'mati'),
      ]),
      Row(children: [
        const SizedBox(width: 70, child: Text('Level')),
        Expanded(
          child: Slider(
            min: -80,
            max: -20,
            divisions: 60,
            value: limd(level, -80, -20),
            onChanged: (v) {
              setState(() => level = v);
              if (gate.open()) widget.dsp.send(genLevelCmd(v.round()), retries: 1);
            },
            onChangeEnd: (v) => widget.dsp.send(genLevelCmd(v.round())),
          ),
        ),
        SizedBox(width: 60, child: Text('${level.round()} dB', textAlign: TextAlign.end)),
      ]),
      Row(children: [
        const SizedBox(width: 70, child: Text('Frekuensi')),
        NumBox(
            w: 80,
            text: '$freq',
            onSubmit: (t) {
              final v = int.tryParse(t);
              if (v == null) return;
              setState(() => freq = lim(v, 20, 20000));
              widget.dsp.send(genFreqCmd(freq));
            }),
        const Text('  Hz'),
        const SizedBox(width: 20),
        DropdownButton<int>(
          value: type,
          isDense: true,
          items: const [
            DropdownMenuItem(value: 0, child: Text('Sine')),
            DropdownMenuItem(value: 1, child: Text('Tipe 1')),
            DropdownMenuItem(value: 2, child: Text('Tipe 2')),
            DropdownMenuItem(value: 3, child: Text('Tipe 3')),
          ],
          onChanged: (v) {
            if (v == null) return;
            setState(() => type = v);
            widget.dsp.send(genTypeCmd(v));
          },
        ),
      ]),
      const SizedBox(height: 8),
      const Text('Output'),
      Wrap(spacing: 6, children: [
        FilterChip(
          label: const Text('All'),
          selected: out.every((x) => x),
          onSelected: (v) {
            setState(() {
              for (var i = 0; i < 8; i++) {
                out[i] = v;
              }
            });
            widget.dsp.send(genOutputsCmd(out));
          },
        ),
        for (var i = 0; i < 8; i++)
          FilterChip(
            label: Text('Out ${i + 1}'),
            selected: out[i],
            onSelected: (v) {
              setState(() => out[i] = v);
              widget.dsp.send(genOutputsCmd(out));
            },
          ),
      ]),
    ]);
  }
}
