/*
 * esc_pos_bluetooth
 * Created by Andrey Ushakov
 * 
 * Copyright (c) 2019-2020. All rights reserved.
 * See LICENSE for distribution and usage details.
 */

import 'dart:async';
import 'dart:io';

import 'package:flutter_bluetooth_basic_updated/flutter_bluetooth_basic.dart';
import 'package:rxdart/rxdart.dart';

import './enums.dart';

/// Bluetooth printer
class PrinterBluetooth {
  PrinterBluetooth(this._device);
  final BluetoothDevice _device;

  String? get name => _device.name;
  String? get address => _device.address;
  int? get type => _device.type;
}

/// Printer Bluetooth Manager
class PrinterBluetoothManager {
  final BluetoothManager _bluetoothManager = BluetoothManager.instance;
  bool _isPrinting = false;
  bool _isConnected = false;
  StreamSubscription? _scanResultsSubscription;
  StreamSubscription? _isScanningSubscription;
  PrinterBluetooth? _selectedPrinter;

  final BehaviorSubject<bool> _isScanning = BehaviorSubject.seeded(false);
  Stream<bool> get isScanningStream => _isScanning.stream;

  final BehaviorSubject<List<PrinterBluetooth>> _scanResults = BehaviorSubject.seeded([]);
  Stream<List<PrinterBluetooth>> get scanResults => _scanResults.stream;

  Future _runDelayed(int seconds) {
    return Future<dynamic>.delayed(Duration(seconds: seconds));
  }

  void startScan(Duration timeout) async {
    _scanResults.add(<PrinterBluetooth>[]);

    _bluetoothManager.startScan(timeout: timeout);

    _scanResultsSubscription = _bluetoothManager.scanResults.listen((devices) {
      _scanResults.add(devices.map((d) => PrinterBluetooth(d)).toList());
    });

    _isScanningSubscription = _bluetoothManager.isScanning.listen((isScanningCurrent) async {
      // If isScanning value changed (scan just stopped)
      if (_isScanning.value && !isScanningCurrent) {
        _scanResultsSubscription!.cancel();
        _isScanningSubscription!.cancel();
      }
      _isScanning.add(isScanningCurrent);
    });
  }

  void stopScan() async {
    await _bluetoothManager.stopScan();
  }

  void selectPrinter(PrinterBluetooth printer) {
    _selectedPrinter = printer;
  }

  Future<PosPrintResult> writeBytes(
    List<int> bytes, {
    int chunkSizeBytes = 20,
    int queueSleepTimeMs = 20,
  }) async {
    final Completer<PosPrintResult> completer = Completer();

    const int timeout = 5;
    if (_selectedPrinter == null) {
      return Future<PosPrintResult>.value(PosPrintResult.printerNotSelected);
    } else if (_isScanning.value) {
      return Future<PosPrintResult>.value(PosPrintResult.scanInProgress);
    } else if (_isPrinting) {
      return Future<PosPrintResult>.value(PosPrintResult.printInProgress);
    }

    _isPrinting = true;

    // We have to rescan before connecting, otherwise we can connect only once
    await _bluetoothManager.startScan(timeout: Duration(seconds: 1));
    await _bluetoothManager.stopScan();

    // Connect
    await _bluetoothManager.connect(_selectedPrinter!._device);

    // Subscribe to the events
    _bluetoothManager.state.listen((state) async {
      switch (state) {
        case BluetoothManager.CONNECTED:
          // To avoid double call
          if (!_isConnected) {
            final len = bytes.length;
            List<List<int>> chunks = [];
            for (var i = 0; i < len; i += chunkSizeBytes) {
              var end = (i + chunkSizeBytes < len) ? i + chunkSizeBytes : len;
              chunks.add(bytes.sublist(i, end));
            }

            for (var i = 0; i < chunks.length; i += 1) {
              await _bluetoothManager.writeData(chunks[i]);
              sleep(Duration(milliseconds: queueSleepTimeMs));
            }

            completer.complete(PosPrintResult.success);
          }
          // TODO sending disconnect signal should be event-based
          _runDelayed(3).then((dynamic v) async {
            await _bluetoothManager.disconnect();
            _isPrinting = false;
          });
          _isConnected = true;
          break;
        case BluetoothManager.DISCONNECTED:
          _isConnected = false;
          break;
        default:
          break;
      }
    });

    // Printing timeout
    _runDelayed(timeout).then((dynamic v) async {
      if (_isPrinting) {
        _isPrinting = false;
        completer.complete(PosPrintResult.timeout);
      }
    });

    return completer.future;
  }

  Future<PosPrintResult> writeBytesNewFn(
    List<int> bytes, {
    int chunkSizeBytes = 20,
    int queueSleepTimeMs = 20,
    bool retryOnTimeout = false,
    Duration preScanDuration = const Duration(seconds: 1),
  }) async {
    final Completer<PosPrintResult> completer = Completer();

    // Check initial conditions
    if (_selectedPrinter == null) {
      return Future<PosPrintResult>.value(PosPrintResult.printerNotSelected);
    } else if (_isScanning.value) {
      return Future<PosPrintResult>.value(PosPrintResult.scanInProgress);
    } else if (_isPrinting) {
      return Future<PosPrintResult>.value(PosPrintResult.printInProgress);
    } else if (bytes.isEmpty) {
      return Future<PosPrintResult>.value(PosPrintResult.ticketEmpty);
    }

    _isPrinting = true;
    bool printingCompleted = false;

    // Function to clean up resources
    Future<void> cleanupResources() async {
      try {
        if (_isConnected) {
          await _bluetoothManager.disconnect();
        }
        _isConnected = false;
        _isPrinting = false;
      } catch (e) {
        // Ignore cleanup errors
      }
    }

    try {
      // Extended scan time for more reliable device discovery
      await _bluetoothManager.startScan(timeout: preScanDuration);
      await _bluetoothManager.stopScan();

      // Try to connect with timeout handling
      bool connectionSucceeded = false;
      try {
        await _bluetoothManager.connect(_selectedPrinter!._device).timeout(
          Duration(seconds: 15),
          onTimeout: () {
            throw TimeoutException('Connection timed out');
          },
        );
        connectionSucceeded = true;
      } catch (e) {
        await cleanupResources();
        return PosPrintResult.timeout;
      }

      if (!connectionSucceeded) {
        await cleanupResources();
        return PosPrintResult.timeout;
      }

      // Set up connection state listener with better error handling
      _bluetoothManager.state.listen(
        (state) async {
          switch (state) {
            case BluetoothManager.CONNECTED:
              if (!_isConnected) {
                _isConnected = true;
                try {
                  // Process data in chunks to prevent buffer overflow
                  final len = bytes.length;
                  List<List<int>> chunks = [];

                  // Create chunks of data
                  for (var i = 0; i < len; i += chunkSizeBytes) {
                    var end = (i + chunkSizeBytes < len) ? i + chunkSizeBytes : len;
                    chunks.add(bytes.sublist(i, end));
                  }

                  // Send chunks with proper delay
                  for (var i = 0; i < chunks.length; i += 1) {
                    if (i > 0 && i % 5 == 0) {
                      // Add extra delay every 5 chunks to prevent buffer overflow
                      sleep(Duration(milliseconds: queueSleepTimeMs * 2));
                    }
                    await _bluetoothManager.writeData(chunks[i]);
                    sleep(Duration(milliseconds: queueSleepTimeMs));
                  }

                  printingCompleted = true;

                  // Complete with success
                  if (!completer.isCompleted) {
                    completer.complete(PosPrintResult.success);
                  }
                } catch (e) {
                  // Complete with error if writing fails
                  if (!completer.isCompleted) {
                    completer.complete(PosPrintResult.timeout);
                  }
                }

                // Disconnect after a successful print with delay to ensure data is transmitted
                _runDelayed(3).then((dynamic v) async {
                  await cleanupResources();
                });
              }
              break;

            case BluetoothManager.DISCONNECTED:
              _isConnected = false;
              // If disconnected before printing completed and automatic retry is enabled
              if (!printingCompleted && retryOnTimeout && !completer.isCompleted) {
                completer.complete(PosPrintResult.timeout);
              }
              break;

            default:
              // Handle unknown states
              break;
          }
        },
        onError: (error) {
          if (!completer.isCompleted) {
            completer.complete(PosPrintResult.timeout);
          }
          cleanupResources();
        },
        cancelOnError: false,
      );

      // Set a reasonable timeout for the whole print operation
      _runDelayed(8).then((dynamic v) async {
        if (_isPrinting && !printingCompleted) {
          if (!completer.isCompleted) {
            completer.complete(PosPrintResult.timeout);
          }
          await cleanupResources();
        }
      });

      return completer.future;
    } catch (e) {
      // Handle any unexpected exceptions
      await cleanupResources();
      if (!completer.isCompleted) {
        completer.complete(PosPrintResult.timeout);
      }
      return completer.future;
    }
  }

  Future<void> disconnect() async {
    try {
      await _bluetoothManager.disconnect();
      _isConnected = false;
      _isPrinting = false;
    } catch (e) {
      // Ignore disconnect errors
    }
  }

  Future<PosPrintResult> printTicket(
    List<int> bytes, {
    int chunkSizeBytes = 20,
    int queueSleepTimeMs = 20,
  }) async {
    if (bytes.isEmpty) {
      return Future<PosPrintResult>.value(PosPrintResult.ticketEmpty);
    }
    return writeBytes(
      bytes,
      chunkSizeBytes: chunkSizeBytes,
      queueSleepTimeMs: queueSleepTimeMs,
    );
  }
}
