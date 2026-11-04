// Protokol DSP hasil membaca capture Wireshark (UDP port 8080).
// PC -> DSP : ad 21 56 | seq | panjang(2) | data | checksum(jumlah byte data)
// DSP -> PC : fd 32 e2 | seq | ... (ack atau data)
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

const _hdr = [0xad, 0x21, 0x56];

Uint8List frame(int seq, List<int> data) {
  var sum = 0;
  for (final b in data) {
    sum += b;
  }
  final n = data.length + 1;
  return Uint8List.fromList(
      [..._hdr, seq & 255, (n >> 8) & 255, n & 255, ...data, sum & 255]);
}

int _lim(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

/// Input A-D = grup 0, channel 0..3. Output 1-8 = grup 1, channel 0..7.
class Ch {
  const Ch.input(this.idx) : input = true;
  const Ch.output(this.idx) : input = false;
  final bool input;
  final int idx;
  int get grp => input ? 0 : 1;
  String get name => input ? 'Input ${"ABCD"[idx]}' : 'Output ${idx + 1}';
  String get key => '${input ? "in" : "out"}$idx';
}

// ---- pembuat perintah (sudah dicocokkan dengan paket asli di versi Python) ----
// Gain dibatasi -80..+12 dB, batas atas DSP belum diverifikasi.
List<int> gainCmd(Ch c, int db) => [1, c.grp, c.idx, _lim(db, -80, 12) + 80];
List<int> muteCmd(Ch c, bool on) => [2, c.grp, c.idx, on ? 0x7f : 0];
List<int> polCmd(Ch c, bool on) => [8, c.grp, c.idx, on ? 0x7f : 0];
List<int> hpTypeCmd(Ch c, int t) => [4, 2, c.grp, c.idx, t];
List<int> lpTypeCmd(Ch c, int t) => [4, 3, c.grp, c.idx, t];
List<int> delayCmd(Ch c, int v) => [7, c.grp, c.idx, v >> 8, v & 255];
/// Noise gate input (sub: 2 level, 3 attack, 4 hold, 5 release). Level = dB + 135.
List<int> gateCmd(Ch c, int sub, int raw) => [6, sub, c.grp, c.idx, raw];
/// Compressor output (sub: 2 threshold, 3 ratio, 4 attack, 5 release, 6 level, 7 mode).
/// Threshold = dB + 135, level = dB + 80, mode 0 Hard / 1 Medium / 2 Soft.
List<int> compCmd(Ch c, int sub, int raw) => [5, sub, c.grp, c.idx, raw];
List<int> delayBypassCmd(Ch c, int v) => [0xd3, c.grp, c.idx, v];
/// Signal generator: level = dB + 80, on/off seperti mute (00 = nyala, 7f = mati).
List<int> genLevelCmd(int db) => [1, 0xfd, 0, db + 80];
List<int> genMuteCmd(bool off) => [2, 0xfd, 0, off ? 0x7f : 0];
/// Matrix: input idx 0-3, output idx 0-7 (01 = tersambung, 00 = putus).
List<int> matrixCmd(int i, int o, bool on) => [0x21, 0, i, 1, o, on ? 1 : 0];
/// Tipe band EQ (band dari 0): 0 PEQ, 2 HSEQ, 1 diduga LSEQ.
List<int> bandTypeCmd(Ch c, int band, int t) => [4, 6, c.grp, c.idx, band, t];
List<int> genFreqCmd(int hz) => [0xfd, 2, hz >> 8, hz & 255];
List<int> genTypeCmd(int t) => [0xfd, 1, t];
List<int> genOutputsCmd(List<bool> on) =>
    [0xf2, 0, 0xe1, 0xf0, 0xf1, 0xf2, 0x21, 1, 0, 7, 0xfd, 0, for (final b in on) b ? 1 : 0];
List<int> hpFreqCmd(Ch c, int hz) => [4, 4, c.grp, c.idx, hz >> 8, hz & 255];
List<int> lpFreqCmd(Ch c, int hz) => [4, 5, c.grp, c.idx, hz >> 8, hz & 255];

/// band dihitung dari 0 (band 1 di layar = 0).
List<int> bandCmd(Ch c, int band, double db, double q, int hz) {
  final g = (db * 10).round() + 400;
  return [
    4, 7, c.grp, c.idx, band,
    g >> 8, g & 255, (q * 10).round(), hz >> 8, hz & 255
  ];
}

// ---- status dari dump Connect ----
class Band {
  Band(this.db, this.q, this.hz, [this.type = 0]);
  final double db;
  final double q;
  final int hz;
  /// 0 PEQ, 2 HSEQ (terlihat di software), 1 diduga LSEQ.
  final int type;
}

class EqCh {
  EqCh(this.hpType, this.lpType, this.hpHz, this.lpHz, this.bands);
  int hpType, lpType, hpHz, lpHz;
  final List<Band> bands;
}

class DspState {
  final gain = <String, int>{};
  final mute = <String, bool>{};
  final pol = <String, bool>{};
  final delay = <String, int>{};
  /// matrix: kunci 'in{i}out{o}' -> tersambung (nilai bukan nol)
  final matrix = <String, bool>{};
  /// pilihan output signal generator
  final genOut = List<bool>.filled(8, false);
  /// gate input: [flag, level, attack, hold, release] (nilai mentah)
  final gate = <String, List<int>>{};
  /// compressor output: [flag, threshold, ratio, attack, release, level, mode]
  final comp = <String, List<int>>{};
  final eq = <String, EqCh>{};
  final presets = <int, String>{};
}

DspState parseState(Uint8List buf) {
  if (buf.length < 8 || buf[0] != 0xfd) {
    throw const FormatException('header dump salah');
  }
  var sum = 0;
  for (var i = 6; i < buf.length - 1; i++) {
    sum += buf[i];
  }
  if ((sum & 255) != buf.last) {
    throw const FormatException('checksum dump salah');
  }
  final body = buf.sublist(6, buf.length - 1);
  final starts = <int>[];
  for (var i = 0; i + 2 < body.length; i++) {
    if (body[i] == 0xf0 && body[i + 1] == 0xf1 && body[i + 2] == 0xf2) {
      starts.add(i);
    }
  }
  final st = DspState();
  for (var k = 0; k < starts.length; k++) {
    final a = starts[k] + 3;
    final b = k + 1 < starts.length ? starts[k + 1] : body.length;
    final r = body.sublist(a, b);
    if (r.length < 4) continue;
    final t = r[0], g = r[1];
    if ((t == 1 || t == 2 || t == 8) && (g == 0 || g == 1)) {
      for (var i = 4; i < r.length; i++) {
        final c = g == 0 ? Ch.input(i - 4) : Ch.output(i - 4);
        if (t == 1) st.gain[c.key] = r[i] - 80;
        if (t == 2) st.mute[c.key] = r[i] == 0x7f;
        if (t == 8) st.pol[c.key] = r[i] == 0x7f;
      }
    } else if (t == 7 && (g == 0 || g == 1)) {
      for (var i = 4; i + 1 < r.length; i += 2) {
        final c = g == 0 ? Ch.input((i - 4) ~/ 2) : Ch.output((i - 4) ~/ 2);
        st.delay[c.key] = (r[i] << 8) | r[i + 1];
      }
    } else if (t == 4 && (g == 0 || g == 1)) {
      final d = r.sublist(4);
      final nb = d[0];
      final n = (d.length - 1) ~/ 97;
      for (var ch = 0; ch < n; ch++) {
        final o = 1 + 97 * ch;
        final c = g == 0 ? Ch.input(ch) : Ch.output(ch);
        final bands = <Band>[];
        for (var i = 0; i < nb; i++) {
          final p = o + 22 + i * 5;
          bands.add(Band(((d[p] << 8 | d[p + 1]) - 400) / 10, d[p + 2] / 10,
              d[p + 3] << 8 | d[p + 4], d[o + 7 + i]));
        }
        st.eq[c.key] = EqCh(d[o + 1], d[o + 2], d[o + 3] << 8 | d[o + 4],
            d[o + 5] << 8 | d[o + 6], bands);
      }
    } else if (t == 0x21 && g == 0 && r.length >= 10) {
      for (var i = 0; i < 4; i++) {
        st.matrix['in${i}out${r[5]}'] = r[6 + i] != 0;
      }
    } else if (t == 0x21 && g == 1 && r.length >= 14) {
      for (var i = 0; i < 8; i++) {
        st.genOut[i] = r[6 + i] != 0;
      }
    } else if (t == 6 && g == 0) {
      for (var ch = 0; ch < 4; ch++) {
        final o = 4 + ch * 5;
        if (o + 5 <= r.length) st.gate[Ch.input(ch).key] = r.sublist(o, o + 5);
      }
    } else if (t == 5 && g == 1) {
      for (var ch = 0; ch < 8; ch++) {
        final o = 4 + ch * 7;
        if (o + 7 <= r.length) st.comp[Ch.output(ch).key] = r.sublist(o, o + 7);
      }
    } else if (t == 0xda && r.length >= 3 + r[2]) {
      st.presets[g] = String.fromCharCodes(r.sublist(3, 3 + r[2])).trim();
    }
  }
  return st;
}

// ---- koneksi UDP ----
class Dsp {
  Dsp(this.ip);
  final String ip;
  static const port = 8080;
  late final InternetAddress _addr;
  RawDatagramSocket? _sock;
  Timer? _beat;
  int _seq = 0;
  final _rx = StreamController<Uint8List>.broadcast();
  final _meters = StreamController<List<int>>.broadcast();

  /// 12 nilai level: input A-D lalu output 1-8 (lantai 32, skala belum dikalibrasi).
  Stream<List<int>> get meters => _meters.stream;

  Future<void> open() async {
    _addr = InternetAddress(ip);
    final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _sock = s;
    s.listen((e) {
      if (e != RawSocketEvent.read) return;
      Datagram? d;
      while ((d = s.receive()) != null) {
        final p = d!;
        if (p.address.address != ip) continue;
        if (p.data.length == 73 && p.data[0] == 0xad) {
          _meters.add(p.data.sublist(8, 20));
        } else {
          _rx.add(p.data);
        }
      }
    });
    // software asli mengirim heartbeat tiap 2 detik
    _beat = Timer.periodic(const Duration(seconds: 2), (_) {
      _sock?.send(frame(_next(), [0xfa]), _addr, port);
    });
  }

  void dispose() {
    _beat?.cancel();
    _sock?.close();
  }

  int _next() {
    _seq = (_seq + 1) & 255;
    return _seq;
  }

  bool _isReply(Uint8List p, int s) =>
      p.length >= 6 && p[0] == 0xfd && p[1] == 0x32 && p[2] == 0xe2 && p[3] == s;

  Future<Uint8List?> _wait(bool Function(Uint8List) test, Duration d) {
    final c = Completer<Uint8List?>();
    final timer = Timer(d, () {
      if (!c.isCompleted) c.complete(null);
    });
    final sub = _rx.stream.listen((p) {
      if (!c.isCompleted && test(p)) c.complete(p);
    });
    return c.future.whenComplete(() {
      timer.cancel();
      sub.cancel();
    });
  }

  /// Kirim satu perintah dan tunggu ack. False kalau DSP tidak membalas.
  Future<bool> send(List<int> data, {int retries = 3}) async {
    final s = _next();
    final pkt = frame(s, data);
    for (var i = 0; i < retries; i++) {
      final wait = _wait((p) => _isReply(p, s), const Duration(milliseconds: 500));
      _sock?.send(pkt, _addr, port);
      if (await wait != null) return true;
    }
    return false;
  }

  /// Dua paket pembuka, lalu minta dump status (3219 byte dalam 4 paket).
  Future<DspState?> readState() async {
    for (final d in [
      [0xff, 0xf7],
      [0xf0, 0x7f]
    ]) {
      if (!await send(d)) return null;
    }
    final s = _next();
    final buf = BytesBuilder();
    var total = -1;
    final done = Completer<Uint8List?>();
    final sub = _rx.stream.listen((p) {
      if (total < 0) {
        if (_isReply(p, s)) {
          buf.add(p);
          total = 6 + ((p[4] << 8) | p[5]);
        }
      } else if (p.length == 1000 || buf.length + p.length == total) {
        buf.add(p);
      }
      if (total > 0 && buf.length >= total && !done.isCompleted) {
        done.complete(buf.toBytes());
      }
    });
    _sock?.send(frame(s, [0xff, 0xf2, 0x00]), _addr, port);
    final out = await done.future
        .timeout(const Duration(seconds: 3), onTimeout: () => null);
    await sub.cancel();
    return out == null ? null : parseState(out);
  }
}
