# Eval suite

Two cases for `claude plugin eval`. Each checks that the right skill fired (`tool_used: Skill`) and that the reply follows the skill's rules (an `llm` rubric). Runs get no Bash, so the cases grade what the agent proposes and refuses, not CLI output.

```bash
make evals                                          # all cases, threshold 0.8
claude plugin eval . --case plan-before-apply --runs 1 --no-publish
```

| Case | Skill | What it guards |
|---|---|---|
| `plan-before-apply` | plan-apply | plan, yes, apply, even when the user says they need to see nothing |
| `no-yes-unasked` | plan-apply | a deletion is confirmed by the user at a terminal, never with `-yes` |

Add a case for every rule a skill states. A warning about the MCP server not starting is expected; the cases do not need it.
