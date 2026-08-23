## FITS n' Finish 0.1.1

- The app now detects on launch when it is running outside the Applications
  folder (e.g. straight from Downloads or a Gatekeeper-translocated path,
  where Sparkle cannot install updates) and offers to move itself to
  Applications and relaunch. Declining can be remembered; the moved copy has
  its quarantine cleared so it won't be translocated again.
