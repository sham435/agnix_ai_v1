/// Clock and duration formatting for a conversation turn.
///
/// Kept out of the widgets because these are the two numbers the user asked for
/// — when the turn was asked and when the answer finished — and a formatter that
/// lives in a build method is a formatter nobody can test.
library;

/// `14:30:05`, in the viewer's own timezone.
///
/// The API sends UTC (`2026-10-06T10:00:00.000Z`); a transcript that printed UTC
/// would make the reader do the arithmetic, which is exactly the wrong thing to
/// ask of a timestamp whose whole purpose is "when did this happen for me".
String clockTime(DateTime at) {
  final local = at.toLocal();
  return <int>[
    local.hour,
    local.minute,
    local.second,
  ].map((part) => part.toString().padLeft(2, '0')).join(':');
}

/// How long a turn took, the way a person would say it: seconds while that is
/// still the right unit, then minutes and seconds.
///
/// Sub-second turns say `<1s` rather than `0s`: a real 300 ms answer and a
/// measurement that never happened must not render the same way.
String formatElapsed(Duration wait) {
  if (wait < const Duration(seconds: 1)) return '<1s';

  final seconds = wait.inSeconds;
  if (seconds < 60) return '${seconds}s';

  return '${seconds ~/ 60}m ${(seconds % 60).toString().padLeft(2, '0')}s';
}

/// The wall time between asking and finishing, or null when either end is
/// unknown.
///
/// Negative gaps are answered with [Duration.zero] rather than a negative
/// duration: the two stamps come from different rows and a clock skew on the
/// server would otherwise print "-3s" in the middle of a transcript.
Duration? turnWait({DateTime? askedAt, DateTime? finishedAt}) {
  if (askedAt == null || finishedAt == null) return null;

  final wait = finishedAt.difference(askedAt);
  return wait.isNegative ? Duration.zero : wait;
}
