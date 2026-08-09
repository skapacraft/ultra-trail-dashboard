# Security policy

## What this data field is, and why that shapes the threat model

Ultra-Trail Dashboard runs on a watch during a race, sometimes for twenty
hours, on a device with about 32KB for a data field. It reads sensors, keeps
physiological state and writes custom fields into the activity file. It asks
for one permission, `FitContributor`, and nothing else.

Two promises shape everything:

> The field opens no network connections, and nothing it computes leaves the
> watch.

Body mass is a setting rather than a read of the Garmin user profile
specifically so that no extra permission is needed. The personal bests the
calibration keeps live in the property store and stay there.

## What counts as a vulnerability here

- **Data leaving the watch.** Any network call, any permission beyond
  `FitContributor`, anything written where another application could read it.
- **Corrupting the activity file.** A data field shares the FIT file with the
  activity itself. Anything that makes the recording unreadable, or that writes
  into a message it does not own, destroys a run that cannot be repeated.
- **Bringing down the activity.** A data field runs inside the activity
  process. An unbounded loop, an allocation that exhausts the 32KB budget, or a
  crash mid-race stops the recording, so it is treated as a security problem
  rather than a bug: the run is the thing that cannot be recovered.
- **Reading a crafted setting into memory unsafety.** Every setting comes from
  Garmin Connect Mobile and is untrusted: a value that makes the engine read out
  of bounds or loop forever belongs here.

A wrong number is not a vulnerability. The physiological models are estimates,
and an estimate you disagree with is a modelling issue: open an issue with the
inputs and what you would have expected, and it gets discussed on the numbers.

## Out of scope

- Garmin Connect Mobile, Garmin's servers, and the Connect IQ platform.
- GPS accuracy, and anything downstream of it. The grade is smoothed precisely
  because the underlying signal is noisy.
- The physiological models being simplifications. They are, deliberately and in
  documented ways, and the README says which.

## How to report

**Please do not open a public issue for a security problem.**

Use GitHub's private reporting: the **Security** tab of this repository, then
**Report a vulnerability**. It opens a channel visible only to the maintainer.

Useful in a report, roughly in order of usefulness:

- what an attacker gains, or what the runner loses, in one sentence
- the steps to reproduce, and the exact settings that trigger it
- the version, from the Connect IQ Store listing, and the watch model
- whether it reproduces in the simulator, and on which device target
- the FIT file, if the problem is in what got written, with anything personal
  removed

## What happens then

This is maintained by one person, so no response time is promised that could
not be kept. What is promised instead:

- a report is acknowledged when it is read, even if the answer is that it needs
  time
- a confirmed finding is fixed before anything else, and submitted to the
  Connect IQ Store as soon as it builds
- the fix says what was wrong and since which version, in the changelog
- credit goes to whoever reported it, unless they prefer otherwise

## Supported versions

Only the latest version published on the Connect IQ Store is supported. There
is no back-porting to older ones: update before reporting.
