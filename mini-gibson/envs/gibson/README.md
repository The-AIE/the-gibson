# GibsonEnv

GibsonEnv is the common environment contract for Mini Gibson evaluation, the hackathon demo, and later outcome-based training.

It deliberately separates the **model/agent runtime** from the **engineering environment**.

## Contract

```
reset(task) -> observation
step(action) -> observation, done
verify() -> verification result + reward components
```

The environment owns:
- isolated repository/task state;
- allowed tools and argument validation;
- tool execution results;
- repair budget;
- deterministic verification;
- evidence collection;
- terminal state.

The model does **not** award itself success.

## Terminal states

- `VERIFIED`
- `PARTIALLY_VERIFIED`
- `FAILED`
- `ABORTED`

## Training boundary

Historical SFT/LoRA teaches behavior by imitation. A future RL layer may optimize against GibsonEnv outcomes. RL is not required for the hackathon MVP.

Never expose hidden reference patches or holdout answers through observations.
