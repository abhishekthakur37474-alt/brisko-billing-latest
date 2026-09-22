import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'raw_print_transport.dart';

/// Sends raw ESC/POS bytes to a printer through the Windows print spooler.
///
/// ## Why the spooler, and why RAW
///
/// On the production Windows 10 terminal the TVS RP 3200 Lite is installed as an ordinary
/// Windows printer queue. The safe, driver-neutral way to reach it is the same one every
/// Windows POS application uses: the print spooler API — `OpenPrinter`,
/// `StartDocPrinter`, `StartPagePrinter`, `WritePrinter`, `EndPagePrinter`,
/// `EndDocPrinter`, `ClosePrinter` — with the document's **datatype set to `RAW`** so the
/// spooler passes the ESC/POS stream to the port untouched instead of running it through
/// a printer driver.
///
/// This deliberately avoids USB-level access (libusb / WinUSB / Zadig / libusbK) and any
/// vendor SDK. The customer keeps the printer's normal Windows driver and its normal
/// queue; nothing about their machine has to be replaced. It is the direct counterpart of
/// the macOS `lp -o raw` path: both hand identical bytes to the operating system's own
/// spooler.
///
/// ## Isolation
///
/// The `win32`/`dart:ffi` calls live behind [WindowsRawPrinterApi] and are reached only
/// when this transport is actually constructed, which the platform factory does only on
/// Windows. The file compiles on macOS — `win32` loads its DLLs lazily — but nothing here
/// runs off Windows.
///
/// ## No fake success
///
/// Every spooler call returns a BOOL; a zero is a failure and is thrown with the
/// `GetLastError` code. [WritePrinter] additionally reports how many bytes it accepted,
/// and a short write is treated as a failure rather than a print. Success means the
/// spooler took the whole document, which is the same guarantee the existing model's
/// "printed" state describes.
class WindowsSpoolerPrintTransport implements RawPrintTransport {
  WindowsSpoolerPrintTransport({
    required this.printerName,
    WindowsRawPrinterApi? api,
  }) : _api = api ?? const Win32RawPrinterApi();

  /// The exact name of the Windows printer queue, as it appears in Settings > Printers.
  final String printerName;
  final WindowsRawPrinterApi _api;

  @override
  String get description => 'Windows printer "$printerName"';

  @override
  Future<void> open() async {
    // Opening the handle for real happens per document inside the spooler sequence, so
    // that a queue removed between bills is caught rather than cached. Here we only
    // confirm the queue exists, which turns a mistyped name into a clear error at
    // connect time instead of a silent failure later.
    if (!_api.printerExists(printerName)) {
      throw WindowsSpoolerException(
        'Windows has no printer named "$printerName". Check the printer name '
        'in Settings against Control Panel > Devices and Printers.',
      );
    }
  }

  @override
  Future<void> write(Uint8List bytes, {required String jobName}) async {
    _api.sendRaw(printerName: printerName, jobName: jobName, bytes: bytes);
  }

  @override
  Future<void> close() async {
    // The spooler handle is opened and closed inside each sendRaw, so there is nothing
    // to release between documents.
  }
}

/// The Windows print-spooler operations this transport needs.
///
/// Behind an interface so the transport's behaviour — reject a missing queue, send a RAW
/// document, fail on a short write — can be tested on any platform with a fake, while the
/// real [Win32RawPrinterApi] is exercised only on Windows.
abstract interface class WindowsRawPrinterApi {
  /// True when a queue with exactly [printerName] can be opened.
  bool printerExists(String printerName);

  /// Runs the full RAW spooler sequence for [bytes]. Throws on any failure.
  void sendRaw({
    required String printerName,
    required String jobName,
    required Uint8List bytes,
  });
}

/// The real spooler, via `win32` FFI. Windows-only at run time.
class Win32RawPrinterApi implements WindowsRawPrinterApi {
  const Win32RawPrinterApi();

  @override
  bool printerExists(String printerName) {
    final Pointer<Utf16> name = printerName.toNativeUtf16();
    final Pointer<IntPtr> handle = calloc<IntPtr>();
    try {
      final int opened = OpenPrinter(name, handle, nullptr);
      if (opened == 0) {
        return false;
      }
      ClosePrinter(handle.value);
      return true;
    } finally {
      calloc.free(name);
      calloc.free(handle);
    }
  }

  @override
  void sendRaw({
    required String printerName,
    required String jobName,
    required Uint8List bytes,
  }) {
    final Pointer<Utf16> name = printerName.toNativeUtf16();
    final Pointer<IntPtr> handlePtr = calloc<IntPtr>();
    final Pointer<DOC_INFO_1> docInfo = calloc<DOC_INFO_1>();
    final Pointer<Utf16> docName = jobName.toNativeUtf16();
    // "RAW" is the datatype that tells the spooler not to run the bytes through a driver.
    final Pointer<Utf16> dataType = 'RAW'.toNativeUtf16();
    final Pointer<Uint8> buffer = calloc<Uint8>(bytes.length);
    final Pointer<Uint32> written = calloc<Uint32>();

    int handle = 0;
    bool docStarted = false;
    bool pageStarted = false;
    try {
      if (OpenPrinter(name, handlePtr, nullptr) == 0) {
        throw WindowsSpoolerException(
          'Could not open the Windows printer "$printerName" '
          '(error ${GetLastError()}).',
        );
      }
      handle = handlePtr.value;

      docInfo.ref
        ..pDocName = docName
        ..pOutputFile = nullptr
        ..pDatatype = dataType;

      final int job = StartDocPrinter(handle, 1, docInfo);
      if (job == 0) {
        throw WindowsSpoolerException(
          'The Windows spooler refused the document for "$printerName" '
          '(error ${GetLastError()}).',
        );
      }
      docStarted = true;

      if (StartPagePrinter(handle) == 0) {
        throw WindowsSpoolerException(
          'The Windows spooler could not start the page for "$printerName" '
          '(error ${GetLastError()}).',
        );
      }
      pageStarted = true;

      // Copy the ESC/POS stream into native memory unchanged, then write it in one call.
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      if (WritePrinter(handle, buffer.cast(), bytes.length, written) == 0) {
        throw WindowsSpoolerException(
          'Writing to the Windows printer "$printerName" failed '
          '(error ${GetLastError()}).',
        );
      }
      if (written.value != bytes.length) {
        // A short write means the spooler did not accept the whole document. Reported
        // as a failure rather than a print: a truncated ESC/POS stream is a torn receipt.
        throw WindowsSpoolerException(
          'The Windows printer "$printerName" accepted only ${written.value} '
          'of ${bytes.length} bytes; the document was not printed in full.',
        );
      }
    } finally {
      // Unwind in reverse, best effort, so a mid-sequence failure still releases the
      // handle and the native buffers rather than leaking them.
      if (pageStarted) {
        EndPagePrinter(handle);
      }
      if (docStarted) {
        EndDocPrinter(handle);
      }
      if (handle != 0) {
        ClosePrinter(handle);
      }
      calloc
        ..free(name)
        ..free(handlePtr)
        ..free(docInfo)
        ..free(docName)
        ..free(dataType)
        ..free(buffer)
        ..free(written);
    }
  }
}

/// A fault from the Windows print spooler: a missing queue, a refused document, or a
/// short write. An exception because that is what the transport layer deals in; the
/// printer base class turns it into the `PrinterFailure` the cashier reads.
class WindowsSpoolerException implements Exception {
  const WindowsSpoolerException(this.message);

  final String message;

  @override
  String toString() => 'WindowsSpoolerException($message)';
}
