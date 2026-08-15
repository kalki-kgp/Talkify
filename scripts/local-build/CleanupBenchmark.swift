// Times Text Cleanup over drafts of several lengths.
//
// Cleanup runs between the recognizer finishing and the text landing, which is
// the window the insertion latency benchmark measures — so the deadline default
// in Settings should come from a number rather than a guess. Copied into the
// staging tree by scripts/build-local-app.sh --benchmark-cleanup, where it is
// compiled against the app's own sources.
//
// Needs Apple Intelligence turned on. Without it, `clean` correctly returns the
// draft untouched in microseconds and there is nothing to measure.

import Foundation

let drafts: [(name: String, text: String)] = [
  (
    "short (8 words)",
    "um so i think we should ship it friday"
  ),
  (
    "medium (21 words)",
    "um so i was thinking we could uh ship it on friday if that works for "
      + "everyone otherwise monday is fine too"
  ),
  (
    "long (46 words)",
    "okay so the the main thing is that we need to finish the migration before "
      + "the end of the quarter um and i think if we split it into two parts "
      + "the first one can land next week and then the second part uh depends "
      + "on whether the review comes back in time"
  ),
  (
    "very long (92 words)",
    "right so a couple of things um first the migration needs to be done before "
      + "the quarter ends and i think we can split that into two parts where the "
      + "first lands next week second thing is the review which uh depends on "
      + "whether people have time and honestly i am not sure they will so maybe "
      + "we should plan for it slipping and then the third thing is that we "
      + "still have not decided who is going to own the rollout so we should "
      + "probably sort that out first before anything else happens"
  ),
]

let runsPerDraft = 3

func median(_ values: [Duration]) -> Duration {
  let sorted = values.sorted()
  return sorted[sorted.count / 2]
}

func milliseconds(_ duration: Duration) -> String {
  let components = duration.components
  let total = Double(components.seconds) * 1000
    + Double(components.attoseconds) / 1e15
  return String(format: "%7.0f ms", total)
}

@MainActor
func run() async {
  let availability = CleanupService.availability
  print("Apple Intelligence: \(availability)")
  guard availability.isAvailable else {
    print(availability.message)
    print("\nNothing to measure — cleanup returns the draft untouched.")
    return
  }

  let pacings: [(String, CleanupService.Pacing)] = [
    ("wait for quality", .waitForQuality),
    ("deadline \(CleanupDeadline.default) ms (the default)",
      .deadline(.milliseconds(CleanupDeadline.default))),
  ]

  for (label, pacing) in pacings {
    print("\n\(label)")
    print(String(repeating: "-", count: 52))

    for draft in drafts {
      // A fresh service per draft, warmed the way the app warms it, so what is
      // measured is a cleanup on a prepared session rather than a cold start.
      let service = CleanupService()
      await service.prepare()
      try? await Task.sleep(for: .milliseconds(500))

      var timings: [Duration] = []
      var lastCandidate: String?
      var lastAccepted: String?
      for _ in 0..<runsPerDraft {
        let start = ContinuousClock.now
        let result = await service.inspect(
          draft.text,
          locale: Locale(identifier: "en_US"),
          pacing: pacing
        )
        timings.append(start.duration(to: .now))
        lastCandidate = result.candidate
        lastAccepted = result.accepted
      }

      let verdict: String
      switch (lastCandidate, lastAccepted) {
      case (nil, _): verdict = "no answer in time"
      case (_, nil): verdict = "answered, REJECTED by validation"
      default: verdict = "cleaned"
      }
      print("  \(draft.name.padding(toLength: 20, withPad: " ", startingAt: 0))"
        + "\(milliseconds(median(timings)))   \(verdict)")
      // Printed for the rejections above all: the only way to tell an
      // over-strict rule from a badly behaved model is to look at the answer.
      if let lastCandidate, lastAccepted == nil {
        print("        model said: \(lastCandidate)")
      }
    }
  }

  print("\nEach number is the median of \(runsPerDraft) runs, and is delay the")
  print("person feels between releasing the key and the text landing.")
}

await run()
