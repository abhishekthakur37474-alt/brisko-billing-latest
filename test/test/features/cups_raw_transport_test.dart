import 'dart:collection';
import 'dart:typed_data';

import 'package:brisko_billing/core/utils/result.dart';
import 'package:brisko_billing/features/printing/data/printers/transport/cups_raw_print_transport.dart';
import 'package:brisko_billing/features/printing/data/printers/transport_thermal_printer.dart';
import 'package:brisko_billing/features/printing/domain/models/print_job.dart';
import 'package:brisko_billing/features/printing/domain/models/printer_connection.dart';
import 'package:flutter_test/flutter_test.dart';

/// The macOS CUPS transport, driven by a scripted command runner so every decision it
/// makes — queue exists, queue enabled, job accepted, job left the queue, queue went
/// offline — is exercised without a printer or a shell.
///
/// The point these tests defend is honesty: `lp` accepting a job is not the same as the
/// printer printing it, and a queue disabled mid-print must surface as a failure, never a
/// quiet success.
void main() {
  PrintJob job(List<int> bytes, {String title = 'Receipt 1'}) => PrintJob(
    id: 'prj-1',
    kind: PrintJobKind.customerReceipt,
    title: title,
    createdAt: DateTime.utc(2026, 9, 15),
    bytes: Uint8List.fromList(bytes),
  );

  group('open validates the queue', () {
    test('an idle, enabled queue opens', () async {
      final ScriptedCups cups = ScriptedCups();
      final CupsRawPrintTransport transport = _transport(cups, queue: 'TVS');

      await transport.open();

      expect(
        cups.calls,
        contains(equals(<String>['lpstat', '-p', 'TVS'])),
      );
    });

    test('a disabled queue is refused rather than printed to', () async {
      final ScriptedCups cups = ScriptedCups()
        ..lpstatP.add(_disabled('TVS'));
      final CupsRawPrintTransport transport = _transport(cups, queue: 'TVS');

      await expectLater(
        transport.open(),
        throwsA(isA<CupsTransportException>()),
      );
    });

    test('a queue that does not exist is refused', () async {
      final ScriptedCups cups = ScriptedCups()
        ..lpstatP.add(const CommandResult(exitCode: 1));
      final CupsRawPrintTransport transport = _transport(cups, queue: 'GHOST');

      await expectLater(
        transport.open(),
        throwsA(isA<CupsTransportException>()),
      );
    });
  });

  group('write hands the bytes to lp -o raw', () {
    test('submits with the exact arguments and the bytes verbatim', () async {
      final ScriptedCups cups = ScriptedCups();
      final CupsRawPrintTransport transport = _transport(cups, queue: 'TVS');
      await transport.open();

      final Uint8List bytes = Uint8List.fromList(<int>[0x1B, 0x40, 0x0A, 0xFF]);
      await transport.write(bytes, jobName: 'Receipt 42');

      expect(
        cups.calls,
        contains(equals(<String>['lp', '-d', 'TVS', '-o', 'raw', '-t', 'Receipt 42'])),
      );
      // The ESC/POS stream reaches lp on stdin, byte for byte.
      expect(cups.lpStdin, bytes);
    });

    test('lp exiting non-zero is a failure carrying its message', () async {
      final ScriptedCups cups = ScriptedCups()
        ..lp.add(
          const CommandResult(
            exitCode: 1,
            stderr: 'lp: Error - unable to print file.',
          ),
        );
      final CupsRawPrintTransport transport = _transport(cups, queue: 'TVS');
      await transport.open();

      await expectLater(
        transport.write(Uint8List.fromList(<int>[1, 2]), jobName: 'R'),
        throwsA(
          isA<CupsTransportException>().having(
            (CupsTransportException e) => e.message,
            'message',
            contains('unable to print file'),
          ),
        ),
      );
    });

    test(
      'a queue disabled after submission fails; success is never faked',
      () async {
        final ScriptedCups cups = ScriptedCups()
          // open() sees an enabled queue...
          ..lpstatP.add(_idle('TVS'))
          // ...then, while the job is pending, the printer goes offline.
          ..lpstatP.add(_disabled('TVS'))
          ..lpstatO.add(
            const CommandResult(exitCode: 0, stdout: 'TVS-1 job pending'),
          )
          ..lp.add(
            const CommandResult(
              exitCode: 0,
              stdout: 'request id is TVS-1 (1 file(s))',
            ),
          );
        final CupsRawPrintTransport transport = _transport(cups, queue: 'TVS');
        await transport.open();

        await expectLater(
          transport.write(Uint8List.fromList(<int>[1]), jobName: 'R'),
          throwsA(
            isA<CupsTransportException>().having(
              (CupsTransportException e) => e.message,
              'message',
              contains('offline'),
            ),
          ),
        );
      },
    );

    test('a job that leaves an enabled queue is a success', () async {
      final ScriptedCups cups = ScriptedCups()
        ..lp.add(
          const CommandResult(
            exitCode: 0,
            stdout: 'request id is TVS-9 (1 file(s))',
          ),
        )
        // First poll: still pending. Second poll: gone -> printed.
        ..lpstatO.add(const CommandResult(exitCode: 0, stdout: 'TVS-9 active'))
        ..lpstatO.add(const CommandResult(exitCode: 0, stdout: ''));
      final CupsRawPrintTransport transport = _transport(cups, queue: 'TVS');
      await transport.open();

      // Completes without throwing.
      await transport.write(Uint8List.fromList(<int>[1]), jobName: 'R');
    });

    // Regression: the first customer receipt after a KOT came out with garbage near the
    // logo, while an isolated reprint was clean. The cause was completion detection that
    // treated a raw job as done the instant it left the CUPS *queue* — at which point the
    // bytes are in the printer's own input buffer, still draining. The next document, the
    // receipt with its multi-kilobyte logo raster, was then submitted into a buffer the
    // KOT had not finished, overrunning it. write() must not return until the printer is
    // idle again, not merely until the queue is empty.
    test(
      'write waits for the printer to finish draining, not just to leave the queue',
      () async {
        final ScriptedCups cups = ScriptedCups()
          ..lp.add(
            const CommandResult(
              exitCode: 0,
              stdout: 'request id is TVS-10 (1 file(s))',
            ),
          )
          // The job has already left the queue on the first poll...
          ..lpstatO.add(const CommandResult(exitCode: 0, stdout: ''))
          ..lpstatO.add(const CommandResult(exitCode: 0, stdout: ''))
          // ...but the printer is still receiving it ("now printing … Sending data")
          // for two polls, then returns to idle. open() consumes the first -p (idle).
          ..lpstatP.add(_idle('TVS'))
          ..lpstatP.add(_processing('TVS'))
          ..lpstatP.add(_processing('TVS'))
          ..lpstatP.add(_idle('TVS'));
        final CupsRawPrintTransport transport = _transport(cups, queue: 'TVS');
        await transport.open();

        await transport.write(Uint8List.fromList(<int>[1]), jobName: 'R');

        // It kept polling the printer state until it read idle rather than returning on
        // the empty queue. Three -p polls happened inside write() (processing,
        // processing, idle) on top of the one open() made.
        final int queueStatePolls = cups.calls
            .where(
              (List<String> call) =>
                  call.length >= 2 &&
                  call[0] == 'lpstat' &&
                  call[1] == '-p',
            )
            .length;
        expect(queueStatePolls, greaterThanOrEqualTo(4));
      },
    );
  });

  group('default queue resolution', () {
    test('no queue name falls back to the system default printer', () async {
      final ScriptedCups cups = ScriptedCups()
        ..lpstatD.add(
          const CommandResult(
            exitCode: 0,
            stdout: 'system default destination: DEFAULTPRN',
          ),
        );
      final CupsRawPrintTransport transport = _transport(cups, queue: null);

      await transport.open();

      expect(cups.calls, contains(equals(<String>['lpstat', '-p', 'DEFAULTPRN'])));
    });

    test('no queue name and no default printer is refused', () async {
      final ScriptedCups cups = ScriptedCups()
        ..lpstatD.add(
          const CommandResult(
            exitCode: 0,
            stdout: 'no system default destination',
          ),
        );
      final CupsRawPrintTransport transport = _transport(cups, queue: null);

      await expectLater(
        transport.open(),
        throwsA(isA<CupsTransportException>()),
      );
    });
  });

  group('through the ThermalPrinter seam', () {
    TransportThermalPrinter printer(ScriptedCups cups, {String? queue = 'TVS'}) {
      return TransportThermalPrinter(
        transport: _transport(cups, queue: queue),
        endpoint: PrinterEndpoint.usb(deviceName: queue),
      );
    }

    test('a successful send reports Ok, never throws', () async {
      final ScriptedCups cups = ScriptedCups();
      final TransportThermalPrinter p = printer(cups);

      final Result<void> sent = await p.send(job(<int>[0x1B, 0x40]));

      expect(sent.isOk, isTrue);
      expect(cups.lpStdin, <int>[0x1B, 0x40]);
      await p.dispose();
    });

    test('a disabled printer reports a failure, never throws', () async {
      final ScriptedCups cups = ScriptedCups()..lpstatP.add(_disabled('TVS'));
      final TransportThermalPrinter p = printer(cups);

      final Result<void> sent = await p.send(job(<int>[1, 2]));

      expect(sent.isErr, isTrue);
      await p.dispose();
    });
  });
}

CupsRawPrintTransport _transport(ScriptedCups cups, {required String? queue}) =>
    CupsRawPrintTransport(
      queueName: queue,
      runner: cups.run,
      // No real waiting between polls, and a short window so a "still pending"
      // scenario cannot hang the test.
      sleeper: (Duration _) async {},
      pollInterval: const Duration(milliseconds: 1),
      completionTimeout: const Duration(milliseconds: 50),
    );

CommandResult _idle(String queue) =>
    CommandResult(exitCode: 0, stdout: 'printer $queue is idle.  enabled since now');

/// The printer is enabled but still receiving the current document, which is exactly
/// what CUPS reports on this hardware while the buffer is draining.
CommandResult _processing(String queue) => CommandResult(
  exitCode: 0,
  stdout:
      'printer $queue now printing $queue-1.  enabled since now\n'
      '\tSending data to printer.',
);

CommandResult _disabled(String queue) => CommandResult(
  exitCode: 0,
  stdout: 'printer $queue disabled since now -\n\tReason: offline',
);

/// A scripted stand-in for the CUPS command-line tools.
///
/// Each command type reads from its own queue of responses; an empty queue falls back to
/// a sensible default (an idle queue, a job that has already left, a successful lp), so a
/// test only scripts the responses it cares about.
class ScriptedCups {
  final Queue<CommandResult> lpstatP = Queue<CommandResult>();
  final Queue<CommandResult> lpstatO = Queue<CommandResult>();
  final Queue<CommandResult> lpstatD = Queue<CommandResult>();
  final Queue<CommandResult> lp = Queue<CommandResult>();

  final List<List<String>> calls = <List<String>>[];
  Uint8List? lpStdin;

  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    Uint8List? stdin,
  }) async {
    calls.add(<String>[executable, ...arguments]);

    if (executable == 'lp') {
      lpStdin = stdin;
      return _next(
        lp,
        const CommandResult(
          exitCode: 0,
          stdout: 'request id is DEF-1 (1 file(s))',
        ),
      );
    }

    if (executable == 'lpstat') {
      if (arguments.contains('-d')) {
        return _next(
          lpstatD,
          const CommandResult(
            exitCode: 0,
            stdout: 'system default destination: DEFAULTPRN',
          ),
        );
      }
      if (arguments.contains('-p')) {
        return _next(lpstatP, _idle(arguments.last));
      }
      if (arguments.contains('-o')) {
        // Default: nothing pending, i.e. the job already printed.
        return _next(lpstatO, const CommandResult(exitCode: 0));
      }
    }

    return const CommandResult(exitCode: 0);
  }

  CommandResult _next(Queue<CommandResult> queue, CommandResult fallback) =>
      queue.isEmpty ? fallback : queue.removeFirst();
}
