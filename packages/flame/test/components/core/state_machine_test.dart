import 'package:flame/components.dart';
import 'package:flutter_test/flutter_test.dart';

/// Checks that every `exit` in [log] closes the innermost open `enter`.
void _expectBalanced(List<String> log) {
  final open = <String>[];
  for (final entry in log) {
    final [kind, state] = entry.split(' ');
    if (kind == 'enter') {
      expect(open, isNot(contains(state)), reason: '$state entered twice');
      open.add(state);
    } else {
      expect(open, isNotEmpty, reason: '$state exited but nothing is active');
      expect(open.last, state, reason: 'hooks ran as: $log');
      open.removeLast();
    }
  }
}

StateNode<String> _node(
  String id,
  List<String> log, {
  String? parent,
  void Function()? onEntered,
  void Function()? onExited,
}) {
  return StateNode<String>(
    id: id,
    parent: parent,
    onEnter: (_) {
      log.add('enter $id');
      onEntered?.call();
    },
    onExit: (_) {
      log.add('exit $id');
      onExited?.call();
    },
  );
}

void main() {
  group('StateMachine transitions requested from hooks', () {
    test('a redirect from a leaf onEnter is reported after the transition '
        'that caused it', () {
      final changes = <String>[];
      final log = <String>[];
      late final StateMachine<String, String> fsm;
      fsm = StateMachine<String, String>(
        initialState: 'idle',
        states: [
          _node('idle', log),
          // A guard state that immediately redirects.
          _node(
            'checking',
            log,
            onEntered: () => fsm.transitionTo('moving'),
          ),
          _node('moving', log),
        ],
        onStateChanged: (prev, cur) => changes.add('$prev->$cur'),
      )..start();

      expect(fsm.transitionTo('checking'), isTrue);

      expect(fsm.currentState, 'moving');
      expect(changes, ['idle->checking', 'checking->moving']);
      expect(log, [
        'enter idle',
        'exit idle',
        'enter checking',
        'exit checking',
        'enter moving',
      ]);
    });

    test('a redirect from a parent onEnter lets the transition finish, then '
        'leaves the branch that was entered', () {
      final log = <String>[];
      final changes = <String>[];
      late final StateMachine<String, String> fsm;
      fsm = StateMachine<String, String>(
        initialState: 'idle',
        states: [
          _node('idle', log),
          // Combat cannot start: bail out to "fleeing".
          _node('combat', log, onEntered: () => fsm.transitionTo('fleeing')),
          _node('attack', log, parent: 'combat'),
          _node('fleeing', log),
        ],
        onStateChanged: (prev, cur) => changes.add('$prev->$cur'),
      )..start();

      fsm.transitionTo('attack');

      expect(fsm.currentState, 'fleeing');
      expect(log, [
        'enter idle',
        'exit idle',
        'enter combat',
        'enter attack',
        'exit attack',
        'exit combat',
        'enter fleeing',
      ]);
      _expectBalanced(log);
      expect(changes, ['idle->attack', 'attack->fleeing']);
    });

    test('a redirect from onExit runs after the transition in progress', () {
      final log = <String>[];
      late final StateMachine<String, String> fsm;
      fsm = StateMachine<String, String>(
        initialState: 'a',
        states: [
          _node('a', log, onExited: () => fsm.transitionTo('c')),
          _node('b', log),
          _node('c', log),
        ],
      )..start();

      fsm.transitionTo('b');

      expect(fsm.currentState, 'c');
      expect(log, ['enter a', 'exit a', 'enter b', 'exit b', 'enter c']);
      _expectBalanced(log);
    });

    test('a transition requested by onStateChanged is queued', () {
      final changes = <String>[];
      late final StateMachine<String, String> fsm;
      fsm = StateMachine<String, String>(
        initialState: 'a',
        states: [
          StateNode(id: 'a'),
          StateNode(id: 'b'),
          StateNode(id: 'c'),
        ],
        onStateChanged: (prev, cur) {
          changes.add('$prev->$cur');
          if (cur == 'b') {
            fsm.transitionTo('c');
          }
        },
      )..start();

      fsm.transitionTo('b');

      expect(fsm.currentState, 'c');
      expect(changes, ['a->b', 'b->c']);
    });

    test('a redirect from a boot hook runs once the initial chain is '
        'entered', () {
      final log = <String>[];
      late final StateMachine<String, String> fsm;
      fsm = StateMachine<String, String>(
        initialState: 'leaf',
        states: [
          _node('root', log, onEntered: () => fsm.transitionTo('other')),
          _node('leaf', log, parent: 'root'),
          _node('other', log),
        ],
      );

      fsm.start();

      expect(fsm.currentState, 'other');
      expect(log, [
        'enter root',
        'enter leaf',
        'exit leaf',
        'exit root',
        'enter other',
      ]);
      _expectBalanced(log);
    });

    test('pushState and popState from hooks keep the stack consistent', () {
      final log = <String>[];
      late final StateMachine<String, String> fsm;
      fsm = StateMachine<String, String>(
        initialState: 'moving',
        states: [
          _node('moving', log),
          _node('hit', log, onEntered: () => fsm.pushState('stunned')),
          _node('stunned', log),
        ],
      )..start();

      fsm.transitionTo('hit');
      expect(fsm.currentState, 'stunned');
      expect(fsm.stackDepth, 1);

      expect(fsm.popState(), isTrue);
      // Popping returns to "hit", whose onEnter pushes "stunned" again.
      expect(fsm.currentState, 'stunned');
      expect(fsm.stackDepth, 1);
      _expectBalanced(log);
    });

    test('hooks that keep redirecting to each other fail loudly', () {
      late final StateMachine<String, String> fsm;
      fsm = StateMachine<String, String>(
        initialState: 'idle',
        states: [
          StateNode(id: 'idle'),
          StateNode(id: 'ping', onEnter: (_) => fsm.transitionTo('pong')),
          StateNode(id: 'pong', onEnter: (_) => fsm.transitionTo('ping')),
        ],
      )..start();

      expect(() => fsm.transitionTo('ping'), throwsStateError);

      // The machine is usable again afterwards.
      expect(fsm.transitionTo('idle'), isTrue);
      expect(fsm.currentState, 'idle');
    });

    test('a transition from onUpdate takes effect at once', () {
      final log = <String>[];
      late final StateMachine<String, String> fsm;
      fsm = StateMachine<String, String>(
        initialState: 'a',
        states: [
          StateNode(
            id: 'a',
            onUpdate: (dt, elapsed) {
              log.add('update a');
              fsm.transitionTo('b');
              log.add('now ${fsm.currentState}');
            },
          ),
          StateNode(id: 'b', onUpdate: (dt, elapsed) => log.add('update b')),
        ],
      );

      fsm
        ..update(0.1)
        ..update(0.1);

      expect(log, ['update a', 'now b', 'update b']);
    });
  });

  group('StateMachine.isInState', () {
    test('terminates on a parent chain that forms a cycle', () {
      final fsm = StateMachine<String, String>(
        initialState: 'a',
        states: [
          StateNode(id: 'a', parent: 'b'),
          StateNode(id: 'b', parent: 'a'),
        ],
      );

      expect(fsm.isInState('b'), isTrue);
      expect(fsm.isInState('unknown'), isFalse);
    });
  });
}
