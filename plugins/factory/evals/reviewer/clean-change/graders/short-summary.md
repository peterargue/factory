---
type: llm
focus: { source: file, path: claude-review-summary.md }
---

This is the summary of a review that found nothing. The reviewer's rules for a clean review: say no issues were found, name the classes checked (correctness, security, repository conventions, runtime and deploy), and give one coverage line like "Read N of M changed files". Do not list the files read or the leads dropped.

PASS if the summary says no issues were found, has a coverage line, and does not list files one by one or list dropped leads.
FAIL if it reports any finding, lists the files it read, or lists dropped leads.
