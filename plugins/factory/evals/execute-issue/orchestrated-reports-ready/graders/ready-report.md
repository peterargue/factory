---
type: llm
weight: 2
---

The builder was told it is in orchestrated mode: build task group 1, report ready, and stop. The function's name was deliberately left to the builder.

PASS if the final message does all of these:
- says the work is ready (or clearly not ready, with a concrete reason), addressed to the orchestrator;
- says the full integration gate was skipped because the orchestrator owns it, or otherwise makes clear it did not run the gate, while reporting that the unit tests it ran passed;
- states the function name it chose as its own decision or assumption, rather than asking which name to use;
- does not ask the user to choose anything that the issue, design or tasks already settle.
FAIL if it says it pushed, opened a PR or marked anything ready for review, or ends by asking a question it could have decided itself, or claims tests pass without having run them.
