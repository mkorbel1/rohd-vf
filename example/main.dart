// Copyright (C) 2021-2023 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// main.dart
// Example of a complete ROHD-VF testbench
//
// 2021 May 11
// Author: Max Korbel <max.korbel@intel.com>

import 'dart:async';
import 'dart:collection';
import 'package:logging/logging.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_vf/rohd_vf.dart';
import 'counter.dart';

/// Main function entry point to execute this testbench.
Future<void> main({Level loggerLevel = Level.FINER}) async {
  // Set the logger level
  Logger.root.level = loggerLevel;

  // Create the testbench
  final tb = TopTB();

  // Build the DUT
  await tb.counter.build();

  // Attach a waveform dumper to the DUT
  WaveDumper(tb.counter);

  // Set a maximum simulation time so it doesn't run forever
  Simulator.setMaxSimTime(300);

  // Create and start the test!
  final test = CounterTest(tb.intf);
  await test.start();
}

// Top-level testbench to bundle the DUT with a clock generator
class TopTB {
  // Instance of the DUT
  late final Counter counter;

  // A constant value for the width to use in this testbench
  static const int width = 8;

  // Build an instance of the interface for the Counter
  final CounterInterface intf = CounterInterface();

  TopTB() {
    // Connect a generated clock to the interface
    intf.clk <= SimpleClockGenerator(10).clk;

    // Create the DUT, passing it our interface
    counter = Counter(intf);
  }
}

/// A simple test that brings the [Counter] out of reset and wiggles the enable.
class CounterTest extends Test {
  /// The [CounterInterface] to the [Counter] device under test (DUT).
  final CounterInterface intf;

  /// The test environment for the DUT.
  late final CounterEnv env;

  /// A private, local pointer to the test environment's [Sequencer].
  late final CounterSequencer _counterSequencer;

  CounterTest(this.intf, {String name = 'counterTest'}) : super(name) {
    env = CounterEnv(intf, this);
    _counterSequencer = env.agent.sequencer;
  }

  // A "time consuming" method, similar to `task` in SystemVerilog, which
  // waits for a given number of cycles before completing.
  Future<void> waitNegedges(int numCycles) async {
    for (var i = 0; i < numCycles; i++) {
      await intf.clk.nextNegedge;
    }
  }

  @override
  Future<void> run(Phase phase) async {
    unawaited(super.run(phase));

    // Raise an objection at the start of the test so that the
    // simulation doesn't end before stimulus is injected
    final obj = phase.raiseObjection('counter_test');

    logger.info('Running the test...');

    // Add some simple reset behavior at specified timestamps
    Simulator.registerAction(1, () {
      intf.reset.put(0);
    });
    Simulator.registerAction(3, () {
      intf.reset.put(1);
    });
    Simulator.registerAction(35, () {
      intf.reset.put(0);
    });

    // Add an individual SequenceItem to set enable to 0 at the start
    _counterSequencer.add(CounterSeqItem(false));

    // Wait for the next negative edge of reset
    await intf.reset.nextNegedge;

    // Wait 3 more cycles
    await waitNegedges(3);

    // Kick off a sequence on the sequencer
    await _counterSequencer.start(CounterSequence(5));

    logger.info('Done adding stimulus to the sequencer');

    // Done adding stimulus, we can drop our objection now
    obj.drop();
  }
}

/// Environment to bundle the testbench for the [Counter].
class CounterEnv extends Env {
  /// An instance of the interface to the [Counter].
  final CounterInterface intf;

  /// The agent that communicates with the [Counter].
  late final CounterAgent agent;

  /// A scoreboard for checking functionality of the [Counter].
  late final CounterScoreboard scoreboard;

  CounterEnv(this.intf, Component parent, {String name = 'counterEnv'})
      : super(name, parent) {
    agent = CounterAgent(intf, this);
    scoreboard = CounterScoreboard(
        agent.enableMonitor.stream.map((event) => event.en == 1),
        agent.valueMonitor.stream,
        intf,
        this);
  }

  @override
  Future<void> run(Phase phase) async {
    unawaited(super.run(phase));

    // Listen to the output of the monitor for some logging
    agent.enableMonitor.stream.listen((event) {
      logger.finer('Detected enable on counter: $event');
    });
  }
}

/// An agent to bundle the sequencer, driver, and monitors for one [Counter].
class CounterAgent extends Agent {
  final CounterInterface intf;
  late final CounterSequencer sequencer;
  late final CounterDriver driver;
  late final CounterEnableMonitor enableMonitor;
  late final CounterValueMonitor valueMonitor;

  CounterAgent(this.intf, Component parent, {String name = 'counterAgent'})
      : super(name, parent) {
    sequencer = CounterSequencer(this);
    driver = CounterDriver(intf, sequencer, this);
    enableMonitor = CounterEnableMonitor(intf, this);
    valueMonitor = CounterValueMonitor(intf, this);
  }
}

/// A basic [Sequencer] for the [Counter].
class CounterSequencer extends Sequencer<CounterSeqItem> {
  CounterSequencer(Component parent, {String name = 'counterSequencer'})
      : super(name, parent);
}

// A simple sequence that sends a variable number of 0->1->0 transitions
class CounterSequence extends Sequence {
  /// Number of times to repeat the 0->1->0 flow.
  final int numRepeat;

  CounterSequence(this.numRepeat, {String name = 'counterSequence'})
      : super(name);

  @override
  Future<void> body(Sequencer sequencer) async {
    final counterSequencer = sequencer as CounterSequencer;
    for (var i = 0; i < numRepeat; i++) {
      counterSequencer
        ..add(CounterSeqItem(true))
        ..add(CounterSeqItem(false));
    }
  }
}

/// A simple [SequenceItem] that maps a boolean to an int.
class CounterSeqItem extends SequenceItem {
  final bool _enable;

  // ignore: avoid_positional_boolean_parameters
  CounterSeqItem(this._enable);

  int get en => _enable ? 1 : 0;

  @override
  String toString() => 'enable=$_enable';
}

/// A driver for the enable signal on the [Counter].
class CounterDriver extends Driver<CounterSeqItem> {
  final CounterInterface intf;

  // Keep a queue of items from the sequencer to be driven when desired
  final Queue<CounterSeqItem> _pendingItems = Queue<CounterSeqItem>();

  Objection? _driverObjection;

  CounterDriver(this.intf, CounterSequencer sequencer, Component parent,
      {String name = 'counterDriver'})
      : super(name, parent, sequencer: sequencer);

  @override
  Future<void> run(Phase phase) async {
    unawaited(super.run(phase));

    // Listen to new items coming from the sequencer, and add them to a queue
    sequencer.stream.listen((newItem) {
      _driverObjection ??= phase.raiseObjection('counter_driver')
        ..dropped.then((value) => logger.fine('Driver objection dropped'));
      _pendingItems.add(newItem);
    });

    // Every clock negative edge, drive the next pending item if it exists
    intf.clk.negedge.listen((args) {
      if (_pendingItems.isNotEmpty) {
        final nextItem = _pendingItems.removeFirst();
        drive(nextItem);
        if (_pendingItems.isEmpty) {
          _driverObjection?.drop();
          _driverObjection = null;
        }
      }
    });
  }

  // Translate a SequenceItem into pin wiggles
  void drive(CounterSeqItem? item) {
    if (item == null) {
      intf.en.inject(0);
    } else {
      intf.en.inject(item.en);
    }
  }
}

/// A monitor for the value output of the [Counter]].
class CounterValueMonitor extends Monitor<LogicValue> {
  /// Instance of the [Interface] to the DUT.
  final CounterInterface intf;

  CounterValueMonitor(this.intf, Component parent,
      {String name = 'counterValueMonitor'})
      : super(name, parent);

  @override
  Future<void> run(Phase phase) async {
    unawaited(super.run(phase));

    // wait for reset before monitoring
    await intf.reset.nextNegedge;

    // Every positive edge of the clock
    intf.clk.posedge.listen((event) {
      // Send out an event with the value of the counter
      // Use `value` to look at the value after the positive edge
      add(intf.val.value);
    });
  }
}

/// A monitor for the enable signal of the [Counter].
class CounterEnableMonitor extends Monitor<CounterSeqItem> {
  /// Instance of the [Interface] to the DUT.
  final CounterInterface intf;

  CounterEnableMonitor(this.intf, Component parent,
      {String name = 'counterEnableMonitor'})
      : super(name, parent);

  @override
  Future<void> run(Phase phase) async {
    unawaited(super.run(phase));

    // wait for reset before monitoring
    await intf.reset.nextNegedge;

    // Every positive edge of the clock
    intf.clk.posedge.listen((event) {
      // If the enable bit on the interface is 1
      // Use `previousValue` to look at the enable sampled as a flop would
      add(CounterSeqItem(intf.en.previousValue == LogicValue.one));
    });
  }
}

/// A scoreboard to check that the value output from the [Counter] matches
/// expectations based on the clk, enable, and reset signals.
class CounterScoreboard extends Component {
  /// A stream which pops out a `true` every time enable is high.
  final Stream<bool> enableStream;

  /// A stream which sends out the current value out of the counter once
  /// per cycle.
  final Stream<LogicValue> valueStream;

  /// An instance of the interface to the [Counter].
  final CounterInterface intf;

  CounterScoreboard(
      this.enableStream, this.valueStream, this.intf, Component parent,
      {String name = 'counterScoreboard'})
      : super(name, parent);

  /// Whether an enable was seen this cycle.
  bool _sawEnable = false;

  /// The most recent value recieved on [valueStream].
  int? _seenValue;

  int? _previousValue;

  @override
  Future<void> run(Phase phase) async {
    unawaited(super.run(phase));

    // record if we've seen an enable this cycle
    enableStream.listen((event) {
      _sawEnable = event;
    });

    // record the value we saw this cycle
    valueStream.listen((event) {
      _previousValue = _seenValue;
      _seenValue = event.toInt();
    });

    // check values on negative edge, since both monitors are on posedge
    intf.clk.negedge.listen((event) {
      // by default, we expect the same value
      var expected = _previousValue;

      // if there was an enable, we expect it to increment
      if (_sawEnable && _previousValue != null) {
        // handle counter overflow
        if (_seenValue == (1 << intf.width) - 1) {
          expected = 0;
        } else {
          expected = _previousValue! + 1;
        }
      }

      if (expected != null) {
        final matchesExpectations = _seenValue == expected;

        if (!matchesExpectations) {
          logger.severe('Expected $expected but saw $_seenValue');
        } else {
          logger.finest('Counter value matches expectations with $_seenValue');
        }
      }
    });
  }
}
