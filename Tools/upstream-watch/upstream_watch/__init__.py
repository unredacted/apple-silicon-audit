"""Upstream change watcher for Silicon Audit (SPEC §15).

Detectors observe Apple's firmware, documentation, headers and source; reconcile compares what they
saw with the app's bundled data; publish turns the differences into GitHub issues. Nothing here
changes the app's data: a human reads the issue and opens a PR.
"""
